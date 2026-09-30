import XCTest
@testable import TandemCore

final class WireTests: XCTestCase {
    func testFrameDecoderHandlesArbitrarySplits() throws {
        let payloads = (0..<50).map { i in Data((0..<(i * 37 % 5000)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ i) }) }
        var stream = Data()
        for payload in payloads { stream.append(FrameCodec.encode(payload)) }

        for chunkSize in [1, 3, 7, 64, 1000, stream.count] {
            var decoder = FrameDecoder()
            var decoded: [Data] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decoded += try decoder.append(stream.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(decoded, payloads, "chunk size \(chunkSize)")
            XCTAssertEqual(decoder.pendingByteCount, 0)
        }
    }

    func testFrameDecoderRejectsOversizedFrames() {
        var decoder = FrameDecoder(maxFrameLength: 1024)
        var header = Data()
        withUnsafeBytes(of: UInt32(4096).bigEndian) { header.append(contentsOf: $0) }
        XCTAssertThrowsError(try decoder.append(header))
    }

    func testControlMessagesRoundTrip() throws {
        let messages: [ControlMessage] = [
            .hello(PeerHello(role: .studio, appVersion: "1.0", capabilities: ["mirror"])),
            .sourceStatus(SourceStatus(
                state: .live,
                capture: CaptureSourceDescriptor(source: CaptureSourceID(kind: .display, id: "1"), title: "Built-in Retina Display", pixelWidth: 3456, pixelHeight: 2234),
                allowsRemoteSourceSelection: true
            )),
            .streamRequest(StreamRequest(enabled: true, quality: .balanced)),
            .keyframeRequest,
            .videoAck(VideoAck(sequence: 99)),
            .snapshotRequest(SnapshotRequest(trigger: .hotkey, maxDimension: 2576, quality: 0.9, skipIfUnchangedBelow: 0.02)),
            .snapshotHeader(SnapshotHeader(id: UUID(), trigger: .sourcePush, note: "why is this failing?", pixelWidth: 100, pixelHeight: 50, byteCount: 1234, chunkCount: 1, mimeType: "image/jpeg", capturedAt: Date(timeIntervalSince1970: 1_700_000_000), captureTitle: "Xcode")),
            .snapshotUnchanged(id: UUID()),
            .snapshotFailed(id: UUID(), reason: "paused"),
            .sourceCatalogRequest,
            .sourceCatalog([]),
            .selectSource(CaptureSourceID(kind: .window, id: "42")),
            .automationStatus(AutomationStatus(autoCaptureEnabled: true, intervalSeconds: 30, asksAutomatically: false)),
            .replyMirror(ReplyMirror(threadID: UUID(), messageID: UUID(), prompt: "hi", text: "**bold**", isFinal: true, model: "claude-opus-5-5")),
            .ping(PingPayload(id: 1, sentAt: 123)),
            .pong(PongPayload(id: 1, pingSentAt: 123, receivedAt: 456, sentAt: 789)),
            .goodbye(reason: "quit")
        ]
        for message in messages {
            let encoded = try PeerMessageCodec.encode(.control(message))
            XCTAssertEqual(try PeerMessageCodec.decode(encoded), .control(message))
        }
    }

    func testBinaryMessagesRoundTrip() throws {
        let format = VideoFormat(codec: .h264, width: 1920, height: 1080, parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])])
        XCTAssertEqual(try PeerMessageCodec.decode(PeerMessageCodec.encode(.videoFormat(format))), .videoFormat(format))

        let frame = VideoFrame(sequence: 7, isKeyframe: true, presentationMicros: 1_000_000, capturedAtNanos: 42, data: Data(repeating: 9, count: 5000))
        XCTAssertEqual(try PeerMessageCodec.decode(PeerMessageCodec.encode(.videoFrame(frame))), .videoFrame(frame))

        let chunk = SnapshotChunk(snapshotID: UUID(), index: 2, count: 3, data: Data(repeating: 1, count: 100))
        XCTAssertEqual(try PeerMessageCodec.decode(PeerMessageCodec.encode(.snapshotChunk(chunk))), .snapshotChunk(chunk))
    }

    func testDecodingGarbageThrows() {
        XCTAssertThrowsError(try PeerMessageCodec.decode(Data([0xEE])))
        XCTAssertThrowsError(try PeerMessageCodec.decode(Data([3, 1, 0])))
        XCTAssertThrowsError(try PeerMessageCodec.decode(Data([1]) + Data("{nope".utf8)))
    }
}
