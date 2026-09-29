import XCTest
@testable import TandemCore

/// Captured Messages API requests: URL, headers and the JSON body per model capability class.
final class AIAnthropicRequestTests: XCTestCase {
    /// Streams `request` against a stub that answers successfully and returns the captured request.
    private func capture(_ request: AIRequest, file: StaticString = #filePath, line: UInt = #line) async -> AITestRecordedRequest? {
        let server = AITestStubServer()
        server.enqueue(aiTestAnthropicOK(model: request.model.trimmingCharacters(in: .whitespacesAndNewlines)))
        let result = await aiTestCollect(server.anthropic.stream(request))
        XCTAssertNil(result.error, "stream failed", file: file, line: line)
        XCTAssertEqual(result.events.aiTestText, "OK", file: file, line: line)
        return server.singleRequest(file: file, line: line)
    }

    private struct Expectation {
        var model: String
        var summary: Bool = true
        var effort: ReasoningEffort? = .high
        var thinking: [String: String]?
        var sentEffort: String?
        var fallbacks: Bool
    }

    private let expectations: [Expectation] = [
        // Fable / Mythos: thinking only to ask for a summary.
        Expectation(model: "claude-fable-5-1", thinking: ["type": "adaptive", "display": "summarized"], sentEffort: "high", fallbacks: true),
        Expectation(model: "claude-fable-5-1", summary: false, effort: .max, thinking: nil, sentEffort: "max", fallbacks: true),
        Expectation(model: "claude-fable-5", thinking: ["type": "adaptive", "display": "summarized"], sentEffort: "high", fallbacks: true),
        Expectation(model: "claude-mythos-5-1", summary: false, effort: .low, thinking: nil, sentEffort: "low", fallbacks: true),
        // Frontier: adaptive thinking with display, fallbacks.
        Expectation(model: "claude-opus-5-5", thinking: ["type": "adaptive", "display": "summarized"], sentEffort: "high", fallbacks: true),
        Expectation(model: "claude-opus-5-5", summary: false, effort: .xhigh, thinking: ["type": "adaptive", "display": "omitted"], sentEffort: "xhigh", fallbacks: true),
        Expectation(model: "claude-opus-5", effort: .max, thinking: ["type": "adaptive", "display": "summarized"], sentEffort: "max", fallbacks: true),
        Expectation(model: "claude-sonnet-5-5", summary: false, effort: .low, thinking: ["type": "adaptive", "display": "omitted"], sentEffort: "low", fallbacks: true),
        // Adaptive, no fallbacks.
        Expectation(model: "claude-opus-4-8", effort: .xhigh, thinking: ["type": "adaptive", "display": "summarized"], sentEffort: "xhigh", fallbacks: false),
        Expectation(model: "claude-opus-4-7", summary: false, thinking: ["type": "adaptive", "display": "omitted"], sentEffort: "high", fallbacks: false),
        Expectation(model: "claude-sonnet-5", effort: .medium, thinking: ["type": "adaptive", "display": "summarized"], sentEffort: "medium", fallbacks: false),
        // 4.6: adaptive without display; xhigh → high.
        Expectation(model: "claude-opus-4-6", effort: .xhigh, thinking: ["type": "adaptive"], sentEffort: "high", fallbacks: false),
        Expectation(model: "claude-sonnet-4-6", effort: .max, thinking: ["type": "adaptive"], sentEffort: "max", fallbacks: false),
        // Haiku 4.5 and older: nothing.
        Expectation(model: "claude-haiku-4-5", thinking: nil, sentEffort: nil, fallbacks: false),
        Expectation(model: "claude-sonnet-4-5-20250929", effort: .max, thinking: nil, sentEffort: nil, fallbacks: false),
        // Unknown claude-*: like Opus 4.8.
        Expectation(model: "claude-nova-1", thinking: ["type": "adaptive", "display": "summarized"], sentEffort: "high", fallbacks: false),
        // No effort requested: no output_config.
        Expectation(model: "claude-opus-5-5", effort: nil, thinking: ["type": "adaptive", "display": "summarized"], sentEffort: nil, fallbacks: true)
    ]

    func testBodiesPerCapabilityClass() async throws {
        for expected in expectations {
            let label = "\(expected.model) summary=\(expected.summary) effort=\(expected.effort?.rawValue ?? "nil")"
            let request = aiTestRequest(model: expected.model, effort: expected.effort, summary: expected.summary)
            guard let captured = await capture(request) else { continue }
            let body = captured.json

            XCTAssertEqual(body["thinking"] as? [String: String], expected.thinking, label)
            XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], expected.sentEffort, label)
            if expected.sentEffort == nil { XCTAssertNil(body["output_config"], label) }
            if expected.fallbacks {
                XCTAssertEqual(body["fallbacks"] as? String, "default", label)
                XCTAssertEqual(captured.header("anthropic-beta"), "server-side-fallback-2026-07-01", label)
            } else {
                XCTAssertNil(body["fallbacks"], label)
                XCTAssertNil(captured.header("anthropic-beta"), label)
            }

            // Invariants for every model.
            XCTAssertEqual(body["model"] as? String, expected.model, label)
            XCTAssertEqual(body["max_tokens"] as? Int, 4096, label)
            XCTAssertEqual(body["stream"] as? Bool, true, label)
            XCTAssertEqual(body["cache_control"] as? [String: String], ["type": "ephemeral"], label)
            XCTAssertEqual(body["system"] as? String, "You help with what's on screen.", label)
            for forbidden in ["budget_tokens", "temperature", "top_p", "top_k"] {
                XCTAssertFalse(aiTestJSONContainsKey(body, forbidden), "\(label) sent \(forbidden)")
            }
            let messages = body["messages"] as? [[String: Any]]
            XCTAssertEqual(messages?.last?["role"] as? String, "user", "\(label): no assistant prefill")
            XCTAssertEqual(Set(body.keys).subtracting(["model", "max_tokens", "stream", "system", "messages", "cache_control", "thinking", "output_config", "fallbacks"]), [], label)
        }
    }

    func testURLMethodAndHeaders() async throws {
        let captured = await capture(aiTestRequest(model: "claude-opus-4-8"))
        XCTAssertEqual(captured?.method, "POST")
        XCTAssertEqual(captured?.url.path, "/v1/messages")
        XCTAssertEqual(captured?.header("x-api-key"), "test-key")
        XCTAssertEqual(captured?.header("anthropic-version"), "2023-06-01")
        XCTAssertEqual(captured?.header("Content-Type"), "application/json")
        XCTAssertNil(captured?.header("Authorization"))
    }

    func testMessagesFollowPartOrderAndMergeSameRoleTurns() async throws {
        let request = AIRequest(
            model: "claude-opus-5-5",
            systemPrompt: "",
            turns: [
                .assistant("A leading assistant turn is dropped."),
                .user(.text("What is this?"), .image(aiTestImage), .text("   ")),
                AITurn(role: .assistant, parts: [.text("It's a save dialog."), .image(aiTestImage)]),
                .user(.image(aiTestImage)),
                .user(.text("And now?"))
            ]
        )
        guard let body = await capture(request)?.json else { return XCTFail("no request") }
        XCTAssertNil(body["system"], "an empty system prompt is omitted")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])

        let first = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(first.map { $0["type"] as? String }, ["text", "image"], "blank text is skipped; order kept")
        XCTAssertEqual(first[0]["text"] as? String, "What is this?")
        let source = try XCTUnwrap(first[1]["source"] as? [String: String])
        XCTAssertEqual(source, ["type": "base64", "media_type": "image/png", "data": aiTestImage.data.base64EncodedString()])

        let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.count, 1, "assistant turns carry text blocks only")
        XCTAssertEqual(assistant[0]["type"] as? String, "text")
        XCTAssertEqual(assistant[0]["text"] as? String, "It's a save dialog.")

        let merged = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(merged.map { $0["type"] as? String }, ["image", "text"], "consecutive user turns are merged in order")
        XCTAssertEqual(merged[1]["text"] as? String, "And now?")
    }

    func testTrailingAssistantTurnIsRejectedWithoutARequest() async {
        let server = AITestStubServer()
        let request = AIRequest(model: "claude-opus-5-5", turns: [.user(.text("Hi")), .assistant("Prefill")])
        let result = await aiTestCollect(server.anthropic.stream(request))
        guard case .invalidConfiguration = result.error else { return XCTFail("got \(String(describing: result.error))") }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testEmptyConversationIsRejected() async {
        let server = AITestStubServer()
        let request = AIRequest(model: "claude-opus-5-5", turns: [.user(.text("  ")), .assistant("only me")])
        let result = await aiTestCollect(server.anthropic.stream(request))
        guard case .invalidConfiguration = result.error else { return XCTFail("got \(String(describing: result.error))") }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testModelIDIsTrimmed() async {
        let captured = await capture(aiTestRequest(model: " claude-opus-5-5\n"))
        XCTAssertEqual(captured?.json["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(captured?.json["fallbacks"] as? String, "default", "capabilities use the trimmed id")
    }
}
