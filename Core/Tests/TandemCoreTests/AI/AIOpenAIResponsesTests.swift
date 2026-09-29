import XCTest
@testable import TandemCore

/// OpenAI Responses API: request bodies, stream parsing, degrade-retries and the model list.
final class AIOpenAIResponsesTests: XCTestCase {
    private func run(_ body: String, summary: Bool = true, chunkSize: Int? = nil) async -> (events: [AIStreamEvent], error: AIError?) {
        let server = AITestStubServer()
        server.enqueue(.sse(body, chunkSize: chunkSize))
        return await aiTestCollect(server.openAI.stream(aiTestRequest(model: "gpt-6-astra", summary: summary)))
    }

    // MARK: Request

    func testRequestBody() async throws {
        let server = AITestStubServer()
        server.enqueue(aiTestOpenAIOK())
        let request = AIRequest(
            model: "gpt-6-astra",
            systemPrompt: "Be brief.",
            turns: [
                .user(.text("What is this?"), .image(aiTestImage)),
                AITurn(role: .assistant, parts: [.text("A dialog."), .image(aiTestImage), .text("It asks to save.")]),
                .user(.text("Which button?"))
            ],
            maxOutputTokens: 2048,
            effort: .xhigh,
            includeReasoningSummary: true
        )
        let result = await aiTestCollect(server.openAI.stream(request))
        XCTAssertNil(result.error)
        let captured = try XCTUnwrap(server.singleRequest())

        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.url.absoluteString, "https://\(server.host)/v1/responses")
        XCTAssertEqual(captured.header("Authorization"), "Bearer test-key")
        XCTAssertNil(captured.header("x-api-key"))

        let body = captured.json
        XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(body["instructions"] as? String, "Be brief.")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2048)
        XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "xhigh", "summary": "auto"])
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "stream", "store", "max_output_tokens", "reasoning"])

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let first = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0]["type"] as? String, "input_text")
        XCTAssertEqual(first[0]["text"] as? String, "What is this?")
        XCTAssertEqual(first[1]["type"] as? String, "input_image")
        XCTAssertEqual(first[1]["image_url"] as? String, "data:image/png;base64," + aiTestImage.data.base64EncodedString())
        XCTAssertEqual(first[1]["detail"] as? String, "high")
        XCTAssertEqual(input[1]["content"] as? String, "A dialog.\n\nIt asks to save.", "assistant content is a plain string")
        let last = try XCTUnwrap(input[2]["content"] as? [[String: Any]])
        XCTAssertEqual(last.first?["text"] as? String, "Which button?")
    }

    func testReasoningShapes() async throws {
        let cases: [(model: String, effort: ReasoningEffort?, summary: Bool, expected: [String: String]?)] = [
            ("gpt-6-astra", .low, false, ["effort": "low"]),
            ("gpt-6-astra", nil, true, ["summary": "auto"]),
            ("gpt-6-astra", nil, false, nil),
            ("gpt-5", .max, true, ["effort": "high", "summary": "auto"]),
            ("gpt-4o", .high, true, nil)
        ]
        for testCase in cases {
            let label = "\(testCase.model) \(String(describing: testCase.effort)) summary=\(testCase.summary)"
            let server = AITestStubServer()
            server.enqueue(aiTestOpenAIOK())
            _ = await aiTestCollect(server.openAI.stream(aiTestRequest(model: testCase.model, effort: testCase.effort, summary: testCase.summary, system: "")))
            let body = try XCTUnwrap(server.singleRequest()?.json, label)
            XCTAssertEqual(body["reasoning"] as? [String: String], testCase.expected, label)
            if testCase.expected == nil { XCTAssertNil(body["reasoning"], label) }
            XCTAssertNil(body["instructions"], "\(label): empty instructions are omitted")
        }
    }

    // MARK: Stream

    static let fixture = aiTestSSE([
        ("response.created", #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","object":"response","model":"gpt-6-astra-2026-07-01","status":"in_progress","usage":null}}"#),
        ("response.in_progress", #"{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_1","status":"in_progress"}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}}"#),
        ("response.reasoning_summary_part.added", #"{"type":"response.reasoning_summary_part.added","item_id":"rs_1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}"#),
        ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":0,"delta":"**Reading the dialog** "}"#),
        ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":0,"delta":"It asks to save."}"#),
        ("response.reasoning_summary_text.done", #"{"type":"response.reasoning_summary_text.done","item_id":"rs_1","output_index":0,"summary_index":0,"text":"…"}"#),
        ("response.reasoning_summary_part.added", #"{"type":"response.reasoning_summary_part.added","item_id":"rs_1","output_index":0,"summary_index":1,"part":{"type":"summary_text","text":""}}"#),
        ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":1,"delta":"**Answering**"}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#),
        ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg_1","output_index":1,"content_index":0,"part":{"type":"output_text","text":""}}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":1,"content_index":0,"delta":"Press "}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":1,"content_index":0,"delta":"Save."}"#),
        ("response.output_text.done", #"{"type":"response.output_text.done","item_id":"msg_1","output_index":1,"content_index":0,"text":"Press Save."}"#),
        ("response.completed", #"{"type":"response.completed","sequence_number":20,"response":{"id":"resp_1","model":"gpt-6-astra-2026-07-01","status":"completed","usage":{"input_tokens":1800,"input_tokens_details":{"cached_tokens":1024},"output_tokens":210,"output_tokens_details":{"reasoning_tokens":150},"total_tokens":2010}}}"#)
    ])

    func testFixtureProducesTheExpectedEvents() async {
        let result = await run(Self.fixture)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, [
            .started(model: "gpt-6-astra-2026-07-01"),
            .reasoningDelta("**Reading the dialog** "),
            .reasoningDelta("It asks to save."),
            .reasoningDelta("\n\n"),
            .reasoningDelta("**Answering**"),
            .textDelta("Press "),
            .textDelta("Save."),
            .completed(AICompletion(
                stopReason: .endTurn,
                usage: AIUsage(inputTokens: 1800, outputTokens: 210, cacheReadTokens: 1024),
                servedModel: "gpt-6-astra-2026-07-01"
            ))
        ])
    }

    func testFixtureSurvivesChunking() async {
        let whole = await run(Self.fixture)
        let chunked = await run(Self.fixture, chunkSize: 5)
        XCTAssertEqual(chunked.events, whole.events)
    }

    func testSummaryPartsAreSeparatedEvenWithoutPartEvents() async {
        let body = aiTestSSE([
            ("response.created", #"{"type":"response.created","response":{"model":"gpt-6-astra"}}"#),
            ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"One."}"#),
            ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":" More."}"#),
            ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":1,"delta":"Two."}"#),
            ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":0,"delta":"Three."}"#),
            ("response.completed", #"{"type":"response.completed","response":{"model":"gpt-6-astra"}}"#)
        ])
        let result = await run(body)
        XCTAssertEqual(result.events.aiTestReasoning, "One. More.\n\nTwo.\n\nThree.")
    }

    func testReasoningIsSuppressedWithoutASummaryRequest() async {
        let result = await run(Self.fixture, summary: false)
        XCTAssertEqual(result.events.aiTestReasoning, "")
        XCTAssertEqual(result.events.aiTestText, "Press Save.")
    }

    func testRefusalDeltaIsTextAndMarksARefusal() async {
        let body = aiTestSSE([
            ("response.created", #"{"type":"response.created","response":{"model":"gpt-6-astra"}}"#),
            ("response.refusal.delta", #"{"type":"response.refusal.delta","item_id":"msg_1","delta":"I can't help with that."}"#),
            ("response.completed", #"{"type":"response.completed","response":{"model":"gpt-6-astra","usage":{"input_tokens":10,"output_tokens":6}}}"#)
        ])
        let result = await run(body)
        XCTAssertEqual(result.events.aiTestText, "I can't help with that.")
        XCTAssertEqual(result.events.aiTestCompletion?.stopReason, .refusal(category: nil, explanation: nil))
        XCTAssertEqual(result.events.aiTestCompletion?.usage, AIUsage(inputTokens: 10, outputTokens: 6))
    }

    func testIncompleteMaxOutputTokens() async {
        let body = aiTestSSE([
            ("response.created", #"{"type":"response.created","response":{"model":"gpt-6-astra"}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"Long answ"}"#),
            ("response.incomplete", #"{"type":"response.incomplete","response":{"model":"gpt-6-astra","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":50,"output_tokens":4096}}}"#)
        ])
        let result = await run(body)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestCompletion, AICompletion(
            stopReason: .maxTokens, usage: AIUsage(inputTokens: 50, outputTokens: 4096), servedModel: "gpt-6-astra"
        ))
    }

    func testIncompleteContentFilterIsARefusal() async {
        let body = aiTestSSE([
            ("response.incomplete", #"{"type":"response.incomplete","response":{"model":"gpt-6-astra","incomplete_details":{"reason":"content_filter"}}}"#)
        ])
        let result = await run(body)
        XCTAssertEqual(result.events.aiTestCompletion?.stopReason, .refusal(category: "content_filter", explanation: nil))
    }

    func testFailedResponseThrows() async {
        let rateLimited = aiTestSSE([
            ("response.created", #"{"type":"response.created","response":{"model":"gpt-6-astra"}}"#),
            ("response.failed", #"{"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"Rate limit reached for gpt-6-astra."}}}"#)
        ])
        let first = await run(rateLimited)
        XCTAssertEqual(first.error, .rateLimited(retryAfter: nil, message: "Rate limit reached for gpt-6-astra."))
        XCTAssertEqual(first.events, [.started(model: "gpt-6-astra")])

        let serverError = aiTestSSE([
            ("response.failed", #"{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"Something went wrong."}}}"#)
        ])
        let second = await run(serverError)
        XCTAssertEqual(second.error, .http(status: 500, message: "Something went wrong."))
    }

    func testErrorEventThrows() async {
        let flat = await run(aiTestSSE([("error", #"{"type":"error","code":"rate_limit_exceeded","message":"Slow down.","param":null}"#)]))
        XCTAssertEqual(flat.error, .rateLimited(retryAfter: nil, message: "Slow down."))

        let nested = await run(aiTestSSE([("error", #"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_image","message":"Bad image."}}"#)]))
        XCTAssertEqual(nested.error, .http(status: 400, message: "Bad image."))
    }

    func testEarlyEOFIsMalformed() async {
        let body = aiTestSSE([
            ("response.created", #"{"type":"response.created","response":{"model":"gpt-6-astra"}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"Cut"}"#)
        ])
        let result = await run(body)
        guard case .malformedStream = result.error else { return XCTFail("got \(String(describing: result.error))") }
        XCTAssertEqual(result.events.aiTestText, "Cut")
    }

    // MARK: Degrade-retry

    func testSummaryRejectionKeepsEffort() async throws {
        let server = AITestStubServer()
        server.enqueue(
            .json(400, #"{"error":{"message":"Your organization must be verified to generate reasoning summaries.","type":"invalid_request_error","param":"reasoning.summary","code":"unsupported_value"}}"#),
            aiTestOpenAIOK()
        )
        let result = await aiTestCollect(server.openAI.stream(aiTestRequest(model: "gpt-6-astra")))
        XCTAssertNil(result.error)
        let bodies = server.requests.map(\.json)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first?["reasoning"] as? [String: String], ["effort": "high", "summary": "auto"])
        XCTAssertEqual(bodies.last?["reasoning"] as? [String: String], ["effort": "high"])
    }

    func testReasoningRejectionDropsTheReasoningObject() async throws {
        let server = AITestStubServer()
        server.enqueue(
            .json(400, #"{"error":{"message":"Unsupported parameter: 'reasoning.effort' is not supported with this model.","type":"invalid_request_error","param":"reasoning.effort","code":"unsupported_parameter"}}"#),
            aiTestOpenAIOK()
        )
        let result = await aiTestCollect(server.openAI.stream(aiTestRequest(model: "gpt-6-astra")))
        XCTAssertNil(result.error)
        let bodies = server.requests.map(\.json)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNil(bodies.last?["reasoning"])
    }

    func testUnrelated400IsNotRetried() async {
        let server = AITestStubServer()
        server.enqueue(.json(400, #"{"error":{"message":"Invalid image.","type":"invalid_request_error","code":"invalid_image"}}"#))
        let result = await aiTestCollect(server.openAI.stream(aiTestRequest(model: "gpt-6-astra")))
        XCTAssertEqual(result.error, .http(status: 400, message: "Invalid image."))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testHTTPErrors() async {
        let cases: [(AITestStubResponse, AIError)] = [
            (.json(401, #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","code":"invalid_api_key"}}"#), .authentication("Incorrect API key provided.")),
            (.json(429, #"{"error":{"message":"Rate limit reached.","type":"requests","code":"rate_limit_exceeded"}}"#, headers: ["Retry-After": "3"]), .rateLimited(retryAfter: 3, message: "Rate limit reached.")),
            (.json(429, #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#), .http(status: 429, message: "You exceeded your current quota.")),
            (.json(503, #"{"error":{"message":"The engine is currently overloaded.","type":"server_error"}}"#), .http(status: 503, message: "The engine is currently overloaded."))
        ]
        for (stub, expected) in cases {
            let server = AITestStubServer()
            server.enqueue(stub)
            let result = await aiTestCollect(server.openAI.stream(aiTestRequest(model: "gpt-6-astra")))
            XCTAssertEqual(result.error, expected)
        }
    }

    func testMissingKey() async {
        let server = AITestStubServer()
        let client = OpenAIResponsesClient(endpoint: server.endpoint(.openAI, apiKey: " "), session: server.session)
        let result = await aiTestCollect(client.stream(aiTestRequest(model: "gpt-6-astra")))
        XCTAssertEqual(result.error, .missingAPIKey)
        do {
            _ = try await client.listModels()
            XCTFail("expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? AIError, .missingAPIKey)
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: Models

    func testListModelsFiltersNonChatModels() async throws {
        let server = AITestStubServer()
        let ids = [
            "gpt-6-astra", "text-embedding-3-large", "tts-1-hd", "whisper-1", "gpt-4o-transcribe", "gpt-image-1",
            "dall-e-3", "gpt-realtime", "gpt-audio", "omni-moderation-latest", "davinci-002", "babbage-002",
            "gpt-6-live", "gpt-4o-search-preview", "computer-use-preview", "codex-mini-latest", "gpt-6-sol", "o3"
        ]
        let entries = ids.enumerated().map { index, id in #"{"id":"\#(id)","object":"model","created":\#(1_700_000_000 + index),"owned_by":"openai"}"# }
        server.enqueue(.json(200, #"{"object":"list","data":[\#(entries.joined(separator: ","))]}"#))

        let models = try await server.openAI.listModels()
        XCTAssertEqual(models.map(\.id), ["o3", "gpt-6-sol", "gpt-6-astra"], "chat models only, newest first")
        let request = try XCTUnwrap(server.singleRequest())
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://\(server.host)/v1/models")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-key")
    }

    func testChatModelFilter() {
        XCTAssertTrue(OpenAIResponsesClient.isChatModel("gpt-6-astra"))
        XCTAssertTrue(OpenAIResponsesClient.isChatModel("chatgpt-4o-latest"))
        for id in ["text-embedding-3-small", "gpt-4o-mini-tts", "GPT-IMAGE-1", "gpt-4o-mini-realtime-preview", "gpt-5-codex"] {
            XCTAssertFalse(OpenAIResponsesClient.isChatModel(id), id)
        }
    }
}
