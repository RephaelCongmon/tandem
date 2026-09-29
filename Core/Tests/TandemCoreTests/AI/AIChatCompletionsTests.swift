import XCTest
@testable import TandemCore

/// OpenAI-compatible Chat Completions: request bodies, stream parsing and the single 400 retry.
final class AIChatCompletionsTests: XCTestCase {
    private func run(_ stub: AITestStubResponse, summary: Bool = true) async -> (events: [AIStreamEvent], error: AIError?) {
        let server = AITestStubServer()
        server.enqueue(stub)
        return await aiTestCollect(server.chat.stream(aiTestRequest(model: "local-model", summary: summary)))
    }

    // MARK: Request

    func testRequestBody() async throws {
        let server = AITestStubServer()
        server.enqueue(aiTestChatOK())
        let request = AIRequest(
            model: "qwen3-vl",
            systemPrompt: "Be brief.",
            turns: [
                .user(.text("What is this?"), .image(aiTestImage)),
                .assistant("A dialog."),
                .user(.text("Which button?"))
            ],
            maxOutputTokens: 1024,
            effort: .medium
        )
        let result = await aiTestCollect(server.chat.stream(request))
        XCTAssertNil(result.error)
        let captured = try XCTUnwrap(server.singleRequest())

        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.url.absoluteString, "https://\(server.host)/v1/chat/completions")
        XCTAssertNil(captured.header("Authorization"), "no key, no Authorization header")

        let body = captured.json
        XCTAssertEqual(body["model"] as? String, "qwen3-vl")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        XCTAssertEqual(body["stream_options"] as? [String: Bool], ["include_usage": true])
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, "Be brief.")
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertEqual(parts[0]["text"] as? String, "What is this?")
        XCTAssertEqual((parts[1]["image_url"] as? [String: String])?["url"], "data:image/png;base64," + aiTestImage.data.base64EncodedString())
        XCTAssertEqual(messages[2]["content"] as? String, "A dialog.")
        XCTAssertEqual(messages[3]["content"] as? String, "Which button?", "text-only turns are plain strings for compatibility")
    }

    func testBearerKeyWhenSetAndNoEffortWhenNil() async throws {
        let server = AITestStubServer()
        server.enqueue(aiTestChatOK())
        let client = ChatCompletionsClient(endpoint: server.endpoint(.openAICompatible, apiKey: "local-secret"), session: server.session)
        _ = await aiTestCollect(client.stream(aiTestRequest(model: "local-model", effort: nil, system: "")))
        let captured = try XCTUnwrap(server.singleRequest())
        XCTAssertEqual(captured.header("Authorization"), "Bearer local-secret")
        XCTAssertNil(captured.json["reasoning_effort"])
        let messages = captured.json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "user", "no system message for an empty prompt")
    }

    // MARK: Stream

    static let fixture = aiTestSSE([
        (nil, #"{"id":"c1","object":"chat.completion.chunk","model":"qwen3-vl-8b","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","object":"chat.completion.chunk","model":"qwen3-vl-8b","choices":[{"index":0,"delta":{"reasoning_content":"Looking at the image."},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","object":"chat.completion.chunk","model":"qwen3-vl-8b","choices":[{"index":0,"delta":{"reasoning":" Save dialog."},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","object":"chat.completion.chunk","model":"qwen3-vl-8b","choices":[{"index":0,"delta":{"content":"Press "},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","object":"chat.completion.chunk","model":"qwen3-vl-8b","choices":[{"index":0,"delta":{"content":"Save."},"finish_reason":null}]}"#),
        (nil, #"{"id":"c1","object":"chat.completion.chunk","model":"qwen3-vl-8b","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
        (nil, #"{"id":"c1","object":"chat.completion.chunk","model":"qwen3-vl-8b","choices":[],"usage":{"prompt_tokens":812,"completion_tokens":37,"total_tokens":849,"prompt_tokens_details":{"cached_tokens":512}}}"#),
        (nil, "[DONE]"),
        (nil, #"{"id":"c1","model":"qwen3-vl-8b","choices":[{"index":0,"delta":{"content":"after done"}}]}"#)
    ])

    func testFixtureProducesTheExpectedEvents() async {
        let result = await run(.sse(Self.fixture))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, [
            .started(model: "qwen3-vl-8b"),
            .reasoningDelta("Looking at the image."),
            .reasoningDelta(" Save dialog."),
            .textDelta("Press "),
            .textDelta("Save."),
            .completed(AICompletion(
                stopReason: .endTurn,
                usage: AIUsage(inputTokens: 812, outputTokens: 37, cacheReadTokens: 512),
                servedModel: "qwen3-vl-8b"
            ))
        ])
    }

    func testFixtureSurvivesChunking() async {
        let whole = await run(.sse(Self.fixture))
        let chunked = await run(.sse(Self.fixture, chunkSize: 3))
        XCTAssertEqual(chunked.events, whole.events)
    }

    func testReasoningIsSuppressedWithoutASummaryRequest() async {
        let result = await run(.sse(Self.fixture), summary: false)
        XCTAssertEqual(result.events.aiTestReasoning, "")
        XCTAssertEqual(result.events.aiTestText, "Press Save.")
    }

    func testFinishReasons() async {
        let cases: [(String, AIStopReason)] = [
            ("stop", .endTurn), ("length", .maxTokens), ("content_filter", .refusal(category: "content_filter", explanation: nil)),
            ("tool_calls", .other("tool_calls"))
        ]
        for (wire, expected) in cases {
            let body = aiTestSSE([
                (nil, #"{"model":"m","choices":[{"index":0,"delta":{"content":"x"}}]}"#),
                (nil, #"{"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"\#(wire)"}]}"#),
                (nil, "[DONE]")
            ])
            let result = await run(.sse(body))
            XCTAssertEqual(result.events.aiTestCompletion?.stopReason, expected, wire)
        }
    }

    func testEOFAfterContentCompletesWithEndTurn() async {
        let body = aiTestSSE([
            (nil, #"{"model":"m","choices":[{"index":0,"delta":{"content":"Hi"}}]}"#)
        ])
        let result = await run(.sse(body))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, [.started(model: "m"), .textDelta("Hi"), .completed(AICompletion(stopReason: .endTurn, servedModel: "m"))])
    }

    func testEOFWithoutAnyChunkIsMalformed() async {
        let result = await run(.sse(": keep-alive\n\n"))
        guard case .malformedStream = result.error else { return XCTFail("got \(String(describing: result.error))") }
    }

    func testErrorChunkThrows() async {
        let body = aiTestSSE([
            (nil, #"{"model":"m","choices":[{"index":0,"delta":{"content":"Hi"}}]}"#),
            (nil, #"{"error":{"message":"Context length exceeded","type":"invalid_request_error","code":400}}"#)
        ])
        let result = await run(.sse(body))
        XCTAssertEqual(result.error, .http(status: 400, message: "Context length exceeded"))
        XCTAssertEqual(result.events.aiTestText, "Hi")
    }

    func testNonStreamedJSONResponse() async {
        let json = #"{"id":"c1","object":"chat.completion","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"Whole answer."},"finish_reason":"length"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#
        let result = await run(.json(200, json))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, [
            .started(model: "m"),
            .textDelta("Whole answer."),
            .completed(AICompletion(stopReason: .maxTokens, usage: AIUsage(inputTokens: 5, outputTokens: 2), servedModel: "m"))
        ])
    }

    // MARK: Retry

    func test400RetriesOnceWithoutOptionalFields() async throws {
        let server = AITestStubServer()
        server.enqueue(.json(400, #"{"error":"Unrecognized request argument supplied: stream_options"}"#), aiTestChatOK(text: "Fine"))
        let result = await aiTestCollect(server.chat.stream(aiTestRequest(model: "local-model", effort: .high)))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestText, "Fine")
        let bodies = server.requests.map(\.json)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotNil(bodies.first?["stream_options"])
        XCTAssertNotNil(bodies.first?["reasoning_effort"])
        XCTAssertNil(bodies.last?["stream_options"])
        XCTAssertNil(bodies.last?["reasoning_effort"])
        XCTAssertEqual(bodies.last?["stream"] as? Bool, true)
        XCTAssertEqual(bodies.last?["max_tokens"] as? Int, 4096)
    }

    func testSecond400Surfaces() async {
        let server = AITestStubServer()
        server.enqueue(.json(400, #"{"message":"bad request"}"#), .json(400, #"{"detail":"still bad"}"#))
        let result = await aiTestCollect(server.chat.stream(aiTestRequest(model: "local-model")))
        XCTAssertEqual(result.error, .http(status: 400, message: "still bad"))
        XCTAssertEqual(server.requests.count, 2, "exactly one retry")
    }

    func testNon400IsNotRetried() async {
        let server = AITestStubServer()
        server.enqueue(.json(500, #"{"error":{"message":"model crashed"}}"#))
        let result = await aiTestCollect(server.chat.stream(aiTestRequest(model: "local-model")))
        XCTAssertEqual(result.error, .http(status: 500, message: "model crashed"))
        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: Configuration and models

    func testNoKeyIsFineButAnEmptyModelIsNot() async {
        let server = AITestStubServer()
        let result = await aiTestCollect(server.chat.stream(aiTestRequest(model: "")))
        guard case .invalidConfiguration = result.error else { return XCTFail("got \(String(describing: result.error))") }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testListModels() async throws {
        let server = AITestStubServer()
        server.enqueue(.json(200, #"{"object":"list","data":[{"id":"old","created":100},{"id":"new","created":200},{"id":"undated"}]}"#))
        let models = try await server.chat.listModels()
        XCTAssertEqual(models.map(\.id), ["new", "old", "undated"])
        let request = try XCTUnwrap(server.singleRequest())
        XCTAssertEqual(request.url.absoluteString, "https://\(server.host)/v1/models")
        XCTAssertNil(request.header("Authorization"))
    }
}
