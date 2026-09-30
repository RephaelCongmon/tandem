import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit
import TandemCore

/// Captures everything this Mac plays (except Tandem itself) as 16 kHz mono for the Studio's
/// live transcript. It's its own ScreenCaptureKit stream, separate from the picture, so it runs
/// whenever a Studio listens, whether or not anyone is watching the screen.
final class AudioCaptureService: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "tandem.audio.capture", qos: .userInitiated)

    /// Samples as they arrive (about 20 ms at a time) and the wall-clock capture time of the
    /// first one, in nanoseconds since 1970. Called on `queue`.
    var onSamples: (([Int16], UInt64) -> Void)?
    /// The stream stopped on its own (permission revoked, stopped from the menu bar).
    var onInterrupted: ((Error?) -> Void)?

    private let lock = NSLock()
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let target = LiveAudio.pcmFormat()
    #if DEBUG
    private var testAudio: TestAudioPlayer?
    #endif
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Audio")

    var isRunning: Bool {
        lock.withLock {
            #if DEBUG
            if testAudio != nil { return true }
            #endif
            return stream != nil
        }
    }

    /// Development builds can play a file in a loop instead of capturing (see `-TandemTestAudio`).
    static var usesTestAudio: Bool {
        #if DEBUG
        return AppEnvironment.testAudioFile != nil
        #else
        return false
        #endif
    }

    func start() async throws {
        await stop()
        #if DEBUG
        if let file = AppEnvironment.testAudioFile {
            let player = try TestAudioPlayer(file: file, queue: queue) { [weak self] samples, captured in
                self?.onSamples?(samples, captured)
            }
            player.start()
            lock.withLock { testAudio = player }
            log.info("Test audio playing from \(file.lastPathComponent, privacy: .public)")
            return
        }
        #endif
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !CaptureService.hasScreenRecordingPermission { throw CaptureError.permissionDenied }
            throw error
        }
        // System audio isn't tied to a display, but a stream needs one.
        guard let display = content.displays.first(where: { CGDisplayIsMain($0.displayID) != 0 }) ?? content.displays.first else {
            throw CaptureError.sourceUnavailable
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = LiveAudio.sampleRate
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        // The picture isn't used: keep it as small and slow as ScreenCaptureKit allows.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
        } catch {
            if !CaptureService.hasScreenRecordingPermission { throw CaptureError.permissionDenied }
            throw error
        }
        lock.withLock { self.stream = stream }
        log.info("Audio capture started")
    }

    func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil }
            #if DEBUG
            testAudio?.stop()
            testAudio = nil
            #endif
            return self.stream
        }
        if let stream {
            try? await stream.stopCapture()
            log.info("Audio capture stopped")
        }
    }

    /// Converts a captured buffer (normally already 16 kHz mono float) to 16-bit samples.
    /// Call on `queue` (internal for tests).
    func samples(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        var result: [Int16]?
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
            input.frameLength = AVAudioFrameCount(frames)
            if format.commonFormat == .pcmFormatFloat32, format.channelCount == 1, Int(format.sampleRate) == LiveAudio.sampleRate,
               let channel = input.floatChannelData?[0] {
                result = LiveAudio.int16(from: UnsafeBufferPointer(start: channel, count: frames))
                return
            }
            if converterInput != format {
                converter = AVAudioConverter(from: format, to: target)
                converterInput = format
            }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / format.sampleRate) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, let channel = output.int16ChannelData?[0] else { return }
            result = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        return result
    }
}

extension AudioCaptureService: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let samples = samples(from: sampleBuffer), !samples.isEmpty else { return }
        let duration = UInt64(Double(samples.count) / Double(LiveAudio.sampleRate) * 1_000_000_000)
        onSamples?(samples, wallClockNanos() &- duration)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Audio capture stopped: \(error.localizedDescription, privacy: .public)")
        let isCurrent = lock.withLock { () -> Bool in
            guard self.stream === stream else { return false }
            self.stream = nil
            return true
        }
        if isCurrent { onInterrupted?(error) }
    }
}

#if DEBUG
/// Debug-only stand-in for system audio: plays a sound file in a loop, in real time, so the
/// whole listening pipeline can be exercised without Screen Recording permission.
final class TestAudioPlayer: @unchecked Sendable {
    private let samples: [Int16]
    private let queue: DispatchQueue
    private let handler: ([Int16], UInt64) -> Void
    private var timer: DispatchSourceTimer?
    private var position = 0

    init(file: URL, queue: DispatchQueue, handler: @escaping ([Int16], UInt64) -> Void) throws {
        let audio = try AVAudioFile(forReading: file)
        let target = LiveAudio.pcmFormat()
        guard let source = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              let converter = AVAudioConverter(from: audio.processingFormat, to: target) else { throw CaptureError.sourceUnavailable }
        try audio.read(into: source)
        let capacity = AVAudioFrameCount(Double(audio.length) * target.sampleRate / audio.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw CaptureError.sourceUnavailable }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        // Two seconds of silence between repeats, like a pause in conversation.
        samples = Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
            + [Int16](repeating: 0, count: LiveAudio.sampleRate * 2)
        self.queue = queue
        self.handler = handler
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func emit() {
        guard !samples.isEmpty else { return }
        let count = LiveAudio.frameSamples
        var chunk: [Int16] = []
        chunk.reserveCapacity(count)
        while chunk.count < count {
            let take = min(count - chunk.count, samples.count - position)
            chunk.append(contentsOf: samples[position..<(position + take)])
            position = (position + take) % samples.count
        }
        handler(chunk, wallClockNanos() &- 20_000_000)
    }
}
#endif
