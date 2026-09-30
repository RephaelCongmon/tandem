import XCTest
@testable import TandemCore

final class AudioWireTests: XCTestCase {
    func testAudioControlMessagesRoundTrip() throws {
        let messages: [ControlMessage] = [
            .audioRequest(AudioRequest(enabled: true)),
            .audioRequest(AudioRequest(enabled: false, codecs: [.pcm16])),
            .audioStatus(AudioStatus(state: .live, codec: .opus, sampleRate: 16_000)),
            .audioStatus(AudioStatus(state: .needsPermission, message: "Turn on Screen & System Audio Recording."))
        ]
        for message in messages {
            let encoded = try PeerMessageCodec.encode(.control(message))
            XCTAssertEqual(try PeerMessageCodec.decode(encoded), .control(message))
        }
    }

    func testAudioPacketRoundTrip() throws {
        let packet = AudioPacket(
            codec: .opus, sequence: 7, sampleRate: 16_000, sampleCount: 1_600, capturedAtNanos: 1_700_000_000_123_456_789,
            frames: [Data([1, 2, 3]), Data(), Data(repeating: 9, count: 300)]
        )
        let encoded = try PeerMessageCodec.encode(.audioPacket(packet))
        XCTAssertEqual(try PeerMessageCodec.decode(encoded), .audioPacket(packet))
    }

    func testMalformedAudioPacketsAreRejected() throws {
        let packet = AudioPacket(codec: .pcm16, sequence: 1, sampleRate: 16_000, sampleCount: 320, capturedAtNanos: 1, frames: [Data(count: 640)])
        var encoded = try PeerMessageCodec.encode(.audioPacket(packet))
        encoded[1] = 99 // unknown codec
        XCTAssertThrowsError(try PeerMessageCodec.decode(encoded))

        let silly = AudioPacket(codec: .pcm16, sequence: 1, sampleRate: 1_000_000, sampleCount: 320, capturedAtNanos: 1, frames: [])
        XCTAssertThrowsError(try PeerMessageCodec.decode(try PeerMessageCodec.encode(.audioPacket(silly))))

        let truncated = try PeerMessageCodec.encode(.audioPacket(packet)).prefix(12)
        XCTAssertThrowsError(try PeerMessageCodec.decode(Data(truncated)))
    }

    func testOlderPeersIgnoreAudio() throws {
        // A peer that predates audio can't decode these, and PeerLink skips undecodable messages.
        let json = #"{"audioRequest":{"_0":{"enabled":true,"codecs":["opus"]}}}"#
        var data = Data([1])
        data.append(Data(json.utf8))
        XCTAssertEqual(try PeerMessageCodec.decode(data), .control(.audioRequest(AudioRequest(enabled: true, codecs: [.opus]))))
        XCTAssertThrowsError(try PeerMessageCodec.decode(Data([1]) + Data(#"{"somethingNew":{}}"#.utf8)))
        XCTAssertThrowsError(try PeerMessageCodec.decode(Data([42, 0, 0])))
    }
}

final class AudioCodingTests: XCTestCase {
    /// `seconds` of a 440 Hz tone at half scale.
    private func tone(seconds: Double, frequency: Double = 440, amplitude: Double = 0.5) -> [Int16] {
        let count = Int(Double(LiveAudio.sampleRate) * seconds)
        return (0..<count).map { Int16(amplitude * 32767 * sin(Double($0) * 2 * .pi * frequency / Double(LiveAudio.sampleRate))) }
    }

    func testPCMRoundTripIsExact() throws {
        let encoder = try XCTUnwrap(AudioFrameEncoder(codec: .pcm16))
        let decoder = try XCTUnwrap(AudioFrameDecoder(codec: .pcm16))
        let samples = tone(seconds: 0.25) + [Int16.min, Int16.max, -1, 0, 1]
        let frames = encoder.encode(samples)
        XCTAssertEqual(frames.count, samples.count / LiveAudio.frameSamples, "only complete 20 ms frames")
        XCTAssertTrue(frames.allSatisfy { $0.count == LiveAudio.frameSamples * 2 })
        let decoded = frames.flatMap { decoder.decode($0) }
        XCTAssertEqual(decoded, Array(samples.prefix(decoded.count)))
        XCTAssertEqual(decoder.decode(Data([0x01, 0x80])), [Int16(bitPattern: 0x8001)], "little-endian on the wire")
    }

    func testOpusRoundTripKeepsTheSignal() throws {
        guard let encoder = AudioFrameEncoder(codec: .opus), let decoder = AudioFrameDecoder(codec: .opus) else {
            throw XCTSkip("This Mac can't encode Opus")
        }
        let input = tone(seconds: 1)
        var frames: [Data] = []
        // Feed in uneven pieces, like capture callbacks do.
        var offset = 0
        for size in [100, 333, 320, 1000, 7, 4000] + Array(repeating: 1024, count: 20) where offset < input.count {
            let end = min(input.count, offset + size)
            frames += encoder.encode(Array(input[offset..<end]))
            offset = end
        }
        XCTAssertGreaterThanOrEqual(frames.count, 45)
        let bytes = frames.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(bytes, 6_000, "about 32 kbps, not raw PCM (32 000 bytes)")
        let decoded = frames.flatMap { decoder.decode($0) }
        XCTAssertGreaterThan(decoded.count, 14_000)
        // Same loudness after the codec's start-up delay.
        let original = AudioLevel.rmsDecibels(Array(input[4_000..<12_000]))
        let roundTripped = AudioLevel.rmsDecibels(Array(decoded[4_000..<12_000]))
        XCTAssertEqual(roundTripped, original, accuracy: 1.5)
        XCTAssertEqual(decoder.decode(Data()), [])
    }

    func testPacketizerGroupsFramesAndNumbersPackets() {
        var packetizer = AudioPacketizer(codec: .opus, framesPerPacket: 5)
        var packets: [AudioPacket] = []
        for index in 0..<12 {
            if let packet = packetizer.append(Data([UInt8(index)]), capturedAtNanos: UInt64(index) * 20_000_000) { packets.append(packet) }
        }
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets.map(\.sequence), [0, 1])
        XCTAssertEqual(packets[0].sampleCount, 1_600)
        XCTAssertEqual(packets[1].capturedAtNanos, 100_000_000, "time of the packet's first frame")
        XCTAssertEqual(packets[1].frames, (5..<10).map { Data([UInt8($0)]) })
        let rest = packetizer.flush()
        XCTAssertEqual(rest?.frames.count, 2)
        XCTAssertEqual(rest?.sampleCount, 640)
        XCTAssertEqual(rest?.sequence, 2)
        XCTAssertNil(packetizer.flush())
    }

    func testLevels() {
        XCTAssertEqual(AudioLevel.rmsDecibels([]), -120)
        XCTAssertEqual(AudioLevel.rmsDecibels([0, 0, 0]), -120)
        XCTAssertEqual(AudioLevel.rmsDecibels(tone(seconds: 0.1, amplitude: 1)), -3, accuracy: 0.2)
        XCTAssertEqual(AudioLevel.meterValue(decibels: -120), 0)
        XCTAssertEqual(AudioLevel.meterValue(decibels: -30), 0.5)
        XCTAssertEqual(AudioLevel.meterValue(decibels: 3), 1)
    }

    func testGainLiftsQuietSpeechButNotSilence() {
        var normalizer = AudioGainNormalizer()
        let silence = [Int16](repeating: 3, count: 320)
        for _ in 0..<50 { XCTAssertEqual(normalizer.process(silence), silence) }
        XCTAssertEqual(normalizer.gain, 1)

        let quiet = tone(seconds: 0.02, amplitude: 0.03)
        var output: [Int16] = []
        for _ in 0..<200 { output = normalizer.process(quiet) }
        XCTAssertGreaterThan(normalizer.gain, 4)
        XCTAssertGreaterThan(AudioLevel.rmsDecibels(output), AudioLevel.rmsDecibels(quiet) + 12)

        // A loud burst right after never clips.
        let loud = tone(seconds: 0.02, amplitude: 0.9)
        let processed = normalizer.process(loud)
        XCTAssertLessThanOrEqual(processed.map { abs(Int($0)) }.max() ?? 0, 32767)
        XCTAssertLessThan(normalizer.gain, 4, "loud audio pulls the gain down at once")
    }

    func testFloatConversionClamps() {
        let floats: [Float] = [0, 0.5, -0.5, 1, -1, 2, -2]
        let converted = floats.withUnsafeBufferPointer { LiveAudio.int16(from: $0) }
        XCTAssertEqual(converted, [0, 16384, -16384, 32767, -32767, 32767, -32768])
    }
}
