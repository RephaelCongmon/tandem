import AVFAudio
import Foundation

/// Live audio constants shared by both Macs: mono speech at 16 kHz in 20 ms frames, which is
/// what on-device speech recognition wants and one Opus frame.
public enum LiveAudio {
    public static let sampleRate = 16_000
    public static let frameSamples = 320
    /// Frames per packet on the wire (100 ms), so per-message overhead stays small.
    public static let framesPerPacket = 5
    public static let opusBitRate = 32_000

    /// Mono 16-bit interleaved PCM at `sampleRate`.
    public static func pcmFormat(sampleRate: Int = sampleRate) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
    }

    static func opusFormat(sampleRate: Int) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(sampleRate / 50), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        return AVAudioFormat(streamDescription: &description)
    }

    /// Float samples (−1…1) to 16-bit, clamped.
    public static func int16(from samples: UnsafeBufferPointer<Float>) -> [Int16] {
        samples.map { Int16(clamping: Int(($0 * 32767).rounded())) }
    }
}

/// Turns mono 16-bit samples into 20 ms codec frames. Not thread-safe; use from one queue.
public final class AudioFrameEncoder {
    public let codec: LiveAudioCodec
    public let sampleRate: Int
    private let pcmFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var pending: [Int16] = []

    /// Returns `nil` when this Mac can't encode `codec`.
    public init?(codec: LiveAudioCodec, sampleRate: Int = LiveAudio.sampleRate, bitRate: Int = LiveAudio.opusBitRate) {
        self.codec = codec
        self.sampleRate = sampleRate
        pcmFormat = LiveAudio.pcmFormat(sampleRate: sampleRate)
        switch codec {
        case .pcm16:
            converter = nil
        case .opus:
            guard let opus = LiveAudio.opusFormat(sampleRate: sampleRate),
                  let converter = AVAudioConverter(from: pcmFormat, to: opus) else { return nil }
            converter.bitRate = bitRate
            self.converter = converter
        }
    }

    public var samplesPerFrame: Int { sampleRate / 50 }

    /// Appends `samples` and returns every frame that's now complete.
    public func encode(_ samples: [Int16]) -> [Data] {
        pending.append(contentsOf: samples)
        var frames: [Data] = []
        let size = samplesPerFrame
        while pending.count >= size {
            let chunk = Array(pending.prefix(size))
            pending.removeFirst(size)
            frames.append(contentsOf: encodeFrame(chunk))
        }
        return frames
    }

    /// Drops buffered samples (e.g. after a pause) so old audio isn't glued to new.
    public func reset() {
        pending.removeAll()
        converter?.reset()
    }

    private func encodeFrame(_ samples: [Int16]) -> [Data] {
        guard let converter else {
            var data = Data(capacity: samples.count * 2)
            for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
            return [data]
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        var frames: [Data] = []
        var supplied = false
        while true {
            let output = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 4, maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            frames.append(contentsOf: output.packets())
            if status != .haveData || output.packetCount == 0 { break }
        }
        return frames
    }
}

/// Turns codec frames back into mono 16-bit samples. Not thread-safe; use from one queue.
public final class AudioFrameDecoder {
    public let codec: LiveAudioCodec
    public let sampleRate: Int
    private let pcmFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat?

    /// Returns `nil` when this Mac can't decode `codec`.
    public init?(codec: LiveAudioCodec, sampleRate: Int = LiveAudio.sampleRate) {
        self.codec = codec
        self.sampleRate = sampleRate
        pcmFormat = LiveAudio.pcmFormat(sampleRate: sampleRate)
        switch codec {
        case .pcm16:
            converter = nil
            inputFormat = nil
        case .opus:
            guard let opus = LiveAudio.opusFormat(sampleRate: sampleRate),
                  let converter = AVAudioConverter(from: opus, to: pcmFormat) else { return nil }
            self.converter = converter
            inputFormat = opus
        }
    }

    /// Decodes one frame; a frame that can't be decoded yields nothing.
    public func decode(_ frame: Data) -> [Int16] {
        guard let converter, let inputFormat else { return frame.int16SamplesFromLittleEndian() }
        guard !frame.isEmpty else { return [] }
        let packet = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: frame.count)
        frame.withUnsafeBytes { raw in
            packet.data.copyMemory(from: raw.baseAddress!, byteCount: frame.count)
        }
        packet.byteLength = UInt32(frame.count)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(sampleRate / 50 * 3)) else { return [] }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return packet
        }
        guard error == nil, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
    }

    public func decode(_ packet: AudioPacket) -> [Int16] {
        packet.frames.flatMap { decode($0) }
    }
}

/// Groups 20 ms frames into packets for the wire.
public struct AudioPacketizer: Sendable {
    public let codec: LiveAudioCodec
    public let sampleRate: Int
    public let framesPerPacket: Int
    private var frames: [Data] = []
    private var firstCapturedAt: UInt64?
    private var sequence: UInt32 = 0

    public init(codec: LiveAudioCodec, sampleRate: Int = LiveAudio.sampleRate, framesPerPacket: Int = LiveAudio.framesPerPacket) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.framesPerPacket = max(1, framesPerPacket)
    }

    /// Adds a frame whose first sample was captured at `capturedAtNanos`; returns a packet once full.
    public mutating func append(_ frame: Data, capturedAtNanos: UInt64) -> AudioPacket? {
        if frames.isEmpty { firstCapturedAt = capturedAtNanos }
        frames.append(frame)
        return frames.count >= framesPerPacket ? flush() : nil
    }

    /// Whatever is buffered, as a (possibly short) packet.
    public mutating func flush() -> AudioPacket? {
        guard !frames.isEmpty else { return nil }
        let samples = sampleRate / 50 * frames.count
        let packet = AudioPacket(
            codec: codec, sequence: sequence, sampleRate: sampleRate, sampleCount: samples,
            capturedAtNanos: firstCapturedAt ?? 0, frames: frames
        )
        sequence &+= 1
        frames.removeAll(keepingCapacity: true)
        firstCapturedAt = nil
        return packet
    }
}

/// Loudness helpers for the level meter and for evening out quiet voices before recognition.
public enum AudioLevel {
    /// Root-mean-square level in dBFS (−120 for silence).
    public static func rmsDecibels(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }

    /// 0…1 for a meter spanning −60…0 dBFS.
    public static func meterValue(decibels: Double) -> Double {
        min(1, max(0, (decibels + 60) / 60))
    }
}

/// Slow automatic gain: lifts quiet speech (a soft-spoken caller, a low app volume) toward a
/// comfortable level for the recognizer without pumping up silence or clipping loud audio.
public struct AudioGainNormalizer: Sendable {
    /// Peak level speech is lifted toward.
    public var targetPeak: Double = 0.5
    public var maxGain: Double = 8
    /// Blocks quieter than this are treated as silence and leave the gain alone.
    public var noiseFloor: Double = 0.004
    public private(set) var gain: Double = 1
    private var trackedPeak: Double = 0

    public init() {}

    public mutating func process(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return samples }
        var peak = 0.0
        for sample in samples { peak = max(peak, abs(Double(sample)) / 32768) }
        if peak > noiseFloor {
            // Fast attack on louder audio, slow release so gain doesn't swing between words.
            trackedPeak = peak > trackedPeak ? peak : trackedPeak * 0.995 + peak * 0.005
            let wanted = min(maxGain, max(1, targetPeak / max(trackedPeak, 1e-6)))
            gain = wanted < gain ? wanted : gain + (wanted - gain) * 0.05
        }
        guard gain > 1.001 else { return samples }
        let applied = min(gain, 32767 / max(peak * 32768, 1))
        return samples.map { Int16(clamping: Int((Double($0) * applied).rounded())) }
    }
}

// MARK: - Helpers

private extension AVAudioCompressedBuffer {
    /// Each packet's bytes.
    func packets() -> [Data] {
        guard packetCount > 0 else { return [] }
        let base = data.assumingMemoryBound(to: UInt8.self)
        guard let descriptions = packetDescriptions else {
            return [Data(bytes: base, count: Int(byteLength))]
        }
        return (0..<Int(packetCount)).map { index in
            let description = descriptions[index]
            return Data(bytes: base + Int(description.mStartOffset), count: Int(description.mDataByteSize))
        }
    }
}

private extension Data {
    func int16SamplesFromLittleEndian() -> [Int16] {
        let count = self.count / 2
        return withUnsafeBytes { raw in
            (0..<count).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
    }
}
