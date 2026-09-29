import XCTest
@testable import TandemCore

/// Messages API SSE parsing, end to end through the client.
final class AIAnthropicStreamTests: XCTestCase {
    /// A realistic stream: thinking (with signature), redacted thinking, text, pings and an unknown event.
    static let fixture = aiTestSSE([
        ("message_start", #"{"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":5000,"output_tokens":1}}}"#),
        ("ping", #"{"type":"ping"}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user is looking at "}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a save dialog."}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIM1gbcDa9GJwZA2b3h"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"EmwKAhgBEgy3va3pzix"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Click **Save** — "}}"#),
        ("some_future_event", #"{"type":"some_future_event","payload":{"x":1}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"it's the blue button."}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":87}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ])

    private func run(_ body: String, model: String = "claude-opus-5-5", summary: Bool = true, chunkSize: Int? = nil) async -> (events: [AIStreamEvent], error: AIError?, server: AITestStubServer) {
        let server = AITestStubServer()
        server.enqueue(.sse(body, chunkSize: chunkSize))
        let result = await aiTestCollect(server.anthropic.stream(aiTestRequest(model: model, summary: summary)))
        return (result.events, result.error, server)
    }

    func testFixtureProducesTheExpectedEvents() async {
        let result = await run(Self.fixture)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, [
            .started(model: "claude-opus-5-5"),
            .reasoningDelta("The user is looking at "),
            .reasoningDelta("a save dialog."),
            .textDelta("Click **Save** — "),
            .textDelta("it's the blue button."),
            .completed(AICompletion(
                stopReason: .endTurn,
                usage: AIUsage(inputTokens: 1200, outputTokens: 87, cacheReadTokens: 5000, cacheWriteTokens: 300),
                servedModel: "claude-opus-5-5"
            ))
        ])
    }

    func testFixtureSurvivesArbitraryChunking() async {
        let whole = await run(Self.fixture)
        for size in [1, 7, 64] {
            let chunked = await run(Self.fixture, chunkSize: size)
            XCTAssertNil(chunked.error, "chunk size \(size)")
            XCTAssertEqual(chunked.events, whole.events, "chunk size \(size)")
        }
    }

    func testReasoningIsSuppressedWithoutASummaryRequest() async {
        let result = await run(Self.fixture, summary: false)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestReasoning, "")
        XCTAssertEqual(result.events.aiTestText, "Click **Save** — it's the blue button.")
    }

    func testSeparateThinkingBlocksAreSeparated() async {
        let body = aiTestSSE([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"First."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"Second."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        let result = await run(body)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestReasoning, "First.\n\nSecond.")
    }

    func testFallbackBlockBecomesANoticeAndSetsTheServedModel() async {
        let body = aiTestSSE([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-fable-5-1","usage":{"input_tokens":40,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partial "}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-fable-5-1"},"to":{"model":"claude-opus-4-8"}}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"answer."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":20}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        let result = await run(body, model: "claude-fable-5-1")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.first, .started(model: "claude-fable-5-1"))
        XCTAssertEqual(result.events.aiTestNotices.count, 1)
        XCTAssertTrue(result.events.aiTestNotices.first?.contains("claude-opus-4-8") ?? false, "\(result.events.aiTestNotices)")
        XCTAssertEqual(result.events.aiTestText, "Partial answer.")
        XCTAssertEqual(result.events.aiTestCompletion?.servedModel, "claude-opus-4-8")
        XCTAssertEqual(result.events.aiTestCompletion?.stopReason, .endTurn)
    }

    func testRefusalCarriesStopDetails() async {
        let body = aiTestSSE([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":12,"cache_read_input_tokens":0,"output_tokens":0}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":"cyber","explanation":"This looks like exploit development."}},"usage":{"output_tokens":0}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        let result = await run(body)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestCompletion?.stopReason, .refusal(category: "cyber", explanation: "This looks like exploit development."))
        XCTAssertEqual(result.events.aiTestCompletion?.usage, AIUsage(inputTokens: 12, outputTokens: 0))
    }

    func testRefusalWithNullDetails() async {
        let body = aiTestSSE([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":null}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        let result = await run(body)
        XCTAssertEqual(result.events.aiTestCompletion?.stopReason, .refusal(category: nil, explanation: nil))
        XCTAssertNil(result.events.aiTestCompletion?.usage, "no usage was reported")
    }

    func testStopReasonMapping() async {
        let cases: [(String, AIStopReason)] = [
            ("end_turn", .endTurn), ("stop_sequence", .endTurn), ("max_tokens", .maxTokens),
            ("pause_turn", .other("pause_turn")), ("tool_use", .other("tool_use"))
        ]
        for (wire, expected) in cases {
            let body = aiTestSSE([
                ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
                ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(wire)"},"usage":{"output_tokens":3}}"#),
                ("message_stop", #"{"type":"message_stop"}"#)
            ])
            let result = await run(body)
            XCTAssertEqual(result.events.aiTestCompletion?.stopReason, expected, wire)
        }
    }

    func testUsageMergesLaterCumulativeValues() async {
        let body = aiTestSSE([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":1}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"input_tokens":101,"output_tokens":4096}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        let result = await run(body)
        XCTAssertEqual(result.events.aiTestCompletion, AICompletion(
            stopReason: .maxTokens,
            usage: AIUsage(inputTokens: 101, outputTokens: 4096, cacheReadTokens: 30, cacheWriteTokens: 20),
            servedModel: "claude-opus-5-5"
        ))
    }

    func testErrorEventThrowsAfterEarlierEvents() async {
        let body = aiTestSSE([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#),
            ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        let result = await run(body)
        XCTAssertEqual(result.error, .overloaded("Overloaded"))
        XCTAssertEqual(result.events, [.started(model: "claude-opus-5-5"), .textDelta("Hel")])
    }

    func testErrorEventTypesMap() {
        XCTAssertEqual(AnthropicStreamParser.streamError(type: "overloaded_error", message: "busy"), .overloaded("busy"))
        XCTAssertEqual(AnthropicStreamParser.streamError(type: "rate_limit_error", message: "slow"), .rateLimited(retryAfter: nil, message: "slow"))
        XCTAssertEqual(AnthropicStreamParser.streamError(type: "authentication_error", message: "bad"), .authentication("bad"))
        XCTAssertEqual(AnthropicStreamParser.streamError(type: "api_error", message: "oops"), .http(status: 500, message: "oops"))
        XCTAssertEqual(AnthropicStreamParser.streamError(type: nil, message: nil), .http(status: 500, message: "The provider reported an error."))
    }

    func testEarlyEOFIsMalformed() async {
        let body = aiTestSSE([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Cut"}}"#)
        ])
        let result = await run(body)
        guard case .malformedStream = result.error else { return XCTFail("got \(String(describing: result.error))") }
        XCTAssertEqual(result.events, [.started(model: "claude-opus-5-5"), .textDelta("Cut")])
    }

    func testEmptyBodyIsMalformed() async {
        let result = await run("")
        guard case .malformedStream = result.error else { return XCTFail("got \(String(describing: result.error))") }
        XCTAssertEqual(result.events, [])
    }

    func testEventsAfterMessageStopAreIgnored() async {
        let body = Self.fixture + aiTestSSE([
            ("content_block_delta", #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"late"}}"#)
        ])
        let result = await run(body)
        XCTAssertNil(result.error)
        XCTAssertFalse(result.events.aiTestText.contains("late"))
        if case .completed = result.events.last {} else { XCTFail("completion must be last") }
    }

    func testUnnamedEventsResolveTheirTypeFromJSON() async {
        // Some proxies drop the `event:` lines; the JSON `type` field is used instead.
        let body = aiTestSSE([
            (nil, #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
            (nil, #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            (nil, #"{"type":"message_stop"}"#)
        ])
        let result = await run(body)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestText, "Hi")
    }
}
