import XCTest
@testable import TandemCore

final class AISSEDecoderTests: XCTestCase {
    private func decodeAll(_ chunks: [Data], maxEventSize: Int = SSEDecoder.defaultMaxEventSize) throws -> [SSEEvent] {
        var decoder = SSEDecoder(maxEventSize: maxEventSize)
        var events: [SSEEvent] = []
        for chunk in chunks { events += try decoder.feed(chunk) }
        events += try decoder.finish()
        return events
    }

    private func decodeAll(_ text: String) throws -> [SSEEvent] {
        try decodeAll([Data(text.utf8)])
    }

    func testBasicEventsWithNames() throws {
        let events = try decodeAll("event: ping\ndata: {\"type\":\"ping\"}\n\ndata: second\n\n")
        XCTAssertEqual(events, [
            SSEEvent(event: "ping", data: "{\"type\":\"ping\"}"),
            SSEEvent(event: nil, data: "second")
        ])
    }

    func testCRLFAndBareCRLineEndings() throws {
        let crlf = try decodeAll("event: a\r\ndata: one\r\n\r\n")
        XCTAssertEqual(crlf, [SSEEvent(event: "a", data: "one")])
        let cr = try decodeAll("event: b\rdata: two\r\r")
        XCTAssertEqual(cr, [SSEEvent(event: "b", data: "two")])
    }

    func testCRLFSplitAcrossChunksIsOneLineEnding() throws {
        // If the LF after a chunk-final CR were treated as a second (blank) line, "data: x" would
        // be dispatched early and the event name lost.
        let events = try decodeAll([Data("event: e\r".utf8), Data("\ndata: x\r".utf8), Data("\n\r\n".utf8)])
        XCTAssertEqual(events, [SSEEvent(event: "e", data: "x")])
    }

    func testSplitMidLineAndMidUTF8() throws {
        let text = "event: content_block_delta\ndata: {\"text\":\"héllo 👋\"}\n\n"
        let bytes = Array(text.utf8)
        // Split every possible way into two chunks, including inside the multi-byte characters.
        for split in 1..<bytes.count {
            let events = try decodeAll([Data(bytes[..<split]), Data(bytes[split...])])
            XCTAssertEqual(events, [SSEEvent(event: "content_block_delta", data: "{\"text\":\"héllo 👋\"}")], "split at \(split)")
        }
        // And byte by byte.
        let events = try decodeAll(bytes.map { Data([$0]) })
        XCTAssertEqual(events.map(\.data), ["{\"text\":\"héllo 👋\"}"])
    }

    func testMultiLineDataIsJoinedWithNewlines() throws {
        let events = try decodeAll("data: line one\ndata: line two\ndata:\ndata:no-space\n\n")
        XCTAssertEqual(events, [SSEEvent(data: "line one\nline two\n\nno-space")])
    }

    func testCommentsAndUnknownFieldsAreIgnored() throws {
        let events = try decodeAll(": keep-alive\n\n:another\nfoo: bar\ndata: payload\n: mid-event comment\n\n")
        XCTAssertEqual(events, [SSEEvent(data: "payload")])
    }

    func testEventWithoutDataIsNotDispatched() throws {
        let events = try decodeAll("event: lonely\n\ndata: real\n\n")
        XCTAssertEqual(events, [SSEEvent(data: "real")], "the event name must not leak into the next event")
    }

    func testEmptyDataLineDispatchesEmptyString() throws {
        XCTAssertEqual(try decodeAll("data:\n\n"), [SSEEvent(data: "")])
    }

    func testIDAndRetryFields() throws {
        let events = try decodeAll("id: 7\nretry: 1500\ndata: a\n\ndata: b\n\nretry: nope\ndata: c\n\n")
        XCTAssertEqual(events, [
            SSEEvent(data: "a", id: "7", retry: 1500),
            SSEEvent(data: "b", id: "7"),
            SSEEvent(data: "c", id: "7")
        ])
    }

    func testFinishFlushesUnterminatedEvent() throws {
        var decoder = SSEDecoder()
        XCTAssertEqual(try decoder.feed(Data("event: last\ndata: tail".utf8)), [])
        XCTAssertEqual(try decoder.finish(), [SSEEvent(event: "last", data: "tail")])
        // The decoder is reusable after finish.
        XCTAssertEqual(try decoder.feed(Data("data: again\n\n".utf8)), [SSEEvent(data: "again")])
    }

    func testFinishFlushesEventMissingOnlyTheBlankLine() throws {
        var decoder = SSEDecoder()
        XCTAssertEqual(try decoder.feed(Data("data: [DONE]\n".utf8)), [])
        XCTAssertEqual(try decoder.finish(), [SSEEvent(data: "[DONE]")])
    }

    func testLeadingByteOrderMarkIsStripped() throws {
        let events = try decodeAll([Data([0xEF, 0xBB]), Data([0xBF] + Array("data: bom\n\n".utf8))])
        XCTAssertEqual(events, [SSEEvent(data: "bom")])
    }

    func testMaxEventSizeIsEnforced() {
        var decoder = SSEDecoder(maxEventSize: 64)
        XCTAssertNoThrow(try decoder.feed(Data("data: small\n\n".utf8)))
        let big = Data(("data: " + String(repeating: "x", count: 100)).utf8)
        XCTAssertThrowsError(try decoder.feed(big)) { error in
            guard case .malformedStream = error as? AIError else { return XCTFail("unexpected \(error)") }
        }

        // Many data lines that are individually small but add up also trip the limit.
        var accumulating = SSEDecoder(maxEventSize: 64)
        XCTAssertThrowsError(try accumulating.feed(Data(String(repeating: "data: 0123456789\n", count: 10).utf8)))
    }

    func testManyEventsInOneChunk() throws {
        let body = (0..<500).map { "data: \($0)\n\n" }.joined()
        let events = try decodeAll(body)
        XCTAssertEqual(events.count, 500)
        XCTAssertEqual(events.last?.data, "499")
    }
}
