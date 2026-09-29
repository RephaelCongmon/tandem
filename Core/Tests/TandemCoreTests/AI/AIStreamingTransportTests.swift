import XCTest
@testable import TandemCore

/// Provider-neutral transport behavior: cancellation, transport errors, URLs, the factory, logging.
final class AIStreamingTransportTests: XCTestCase {
    /// A stream that sends a first text delta and then stalls with the connection open.
    private func stallingStream(for kind: AIProviderKind) -> AITestStubResponse {
        let body: String
        switch kind {
        case .anthropic:
            body = aiTestSSE([
                ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
                ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"First"}}"#)
            ])
        case .openAI:
            body = aiTestSSE([
                ("response.created", #"{"type":"response.created","response":{"model":"gpt-6-astra"}}"#),
                ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"First"}"#)
            ])
        case .openAICompatible:
            body = aiTestSSE([(nil, #"{"model":"m","choices":[{"index":0,"delta":{"content":"First"}}]}"#)])
        }
        var stub = AITestStubResponse.sse(body)
        stub.hangs = true
        return stub
    }

    private func model(for kind: AIProviderKind) -> String {
        switch kind {
        case .anthropic: return "claude-opus-5-5"
        case .openAI: return "gpt-6-astra"
        case .openAICompatible: return "local-model"
        }
    }

    // MARK: Cancellation

    func testCancellingTheConsumerCancelsTheRequestPromptly() async {
        for kind in AIProviderKind.allCases {
            let server = AITestStubServer()
            server.enqueue(stallingStream(for: kind))
            let client = server.client(kind)
            let request = aiTestRequest(model: model(for: kind))
            let gotText = AITestFlag()

            let consumer = Task { () -> (events: [AIStreamEvent], error: Error?) in
                var events: [AIStreamEvent] = []
                do {
                    for try await event in client.stream(request) {
                        events.append(event)
                        if case .textDelta = event { gotText.set() }
                    }
                    return (events, nil)
                } catch {
                    return (events, error)
                }
            }
            await aiTestWait("\(kind) first text delta") { gotText.isSet }

            let cancelledAt = Date()
            consumer.cancel()
            let result = await consumer.value
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1, "\(kind): the consumer must not hang")
            XCTAssertTrue(result.error == nil || (result.error as? AIError) == .cancelled, "\(kind): \(String(describing: result.error))")
            XCTAssertEqual(result.events.aiTestText, "First", "\(kind)")
            XCTAssertNil(result.events.aiTestCompletion, "\(kind): a cancelled stream doesn't complete")
            await aiTestWait("\(kind) HTTP request cancelled") { server.stopCount >= 1 }
        }
    }

    func testCancellingBeforeResponseHeadersArrive() async {
        for kind in AIProviderKind.allCases {
            let server = AITestStubServer()
            server.enqueue(.neverResponds)
            let client = server.client(kind)
            let request = aiTestRequest(model: model(for: kind))
            let consumer = Task { await aiTestCollect(client.stream(request)) }
            await aiTestWait("\(kind) request sent") { server.requests.count == 1 }

            let cancelledAt = Date()
            consumer.cancel()
            let result = await consumer.value
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1, "\(kind): the consumer must not hang")
            XCTAssertTrue(result.error == nil || result.error == .cancelled, "\(kind): \(String(describing: result.error))")
            XCTAssertEqual(result.events, [], "\(kind)")
            await aiTestWait("\(kind) HTTP request cancelled") { server.stopCount >= 1 }
        }
    }

    func testDroppingTheStreamEarlyCancelsTheRequest() async {
        let server = AITestStubServer()
        server.enqueue(stallingStream(for: .anthropic))
        let client = server.anthropic
        var seen: [AIStreamEvent] = []
        do {
            for try await event in client.stream(aiTestRequest(model: "claude-opus-5-5")) {
                seen.append(event)
                if case .textDelta = event { break }
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(seen, [.started(model: "claude-opus-5-5"), .textDelta("First")])
        await aiTestWait("HTTP request cancelled") { server.stopCount >= 1 }
    }

    func testCancelledListModelsDoesNotHang() async {
        let server = AITestStubServer()
        server.enqueue(.neverResponds)
        let client = server.anthropic
        let lister = Task { () -> Error? in
            do {
                _ = try await client.listModels()
                return nil
            } catch {
                return error
            }
        }
        await aiTestWait("request sent") { server.requests.count == 1 }
        lister.cancel()
        let error = await lister.value
        XCTAssertEqual(error as? AIError, .cancelled)
    }

    // MARK: Transport errors

    func testTransportErrorsMap() async {
        let timedOut = AITestStubServer()
        timedOut.enqueue(.transportFailure(.timedOut))
        let timeout = await aiTestCollect(timedOut.anthropic.stream(aiTestRequest(model: "claude-opus-5-5")))
        XCTAssertEqual(timeout.error, .timeout)

        for code: URLError.Code in [.notConnectedToInternet, .cannotConnectToHost, .secureConnectionFailed] {
            let server = AITestStubServer()
            server.enqueue(.transportFailure(code))
            let result = await aiTestCollect(server.openAI.stream(aiTestRequest(model: "gpt-6-astra")))
            guard case .network = result.error else { return XCTFail("\(code): got \(String(describing: result.error))") }
            XCTAssertEqual(server.requests.count, 1, "transport errors aren't retried")
        }
    }

    func testConnectionLostMidStreamIsANetworkError() async {
        let server = AITestStubServer()
        var stub = stallingStream(for: .anthropic)
        stub.hangs = false
        stub.failure = URLError(.networkConnectionLost)
        server.enqueue(stub)
        let result = await aiTestCollect(server.anthropic.stream(aiTestRequest(model: "claude-opus-5-5")))
        guard case .network = result.error else { return XCTFail("got \(String(describing: result.error))") }
        XCTAssertEqual(result.events.aiTestText, "First")
    }

    func testErrorWrapping() {
        XCTAssertEqual(AIError.wrapping(CancellationError()), .cancelled)
        XCTAssertEqual(AIError.wrapping(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(AIError.wrapping(URLError(.timedOut)), .timeout)
        XCTAssertEqual(AIError.wrapping(AIError.overloaded("x")), .overloaded("x"))
        XCTAssertEqual(AIError.wrapping(AIHTTPFailure(status: 401, message: "no")), .authentication("no"))
        XCTAssertTrue(AIError.overloaded("x").isTransient)
        XCTAssertFalse(AIError.missingAPIKey.isTransient)
    }

    // MARK: URLs and factory

    func testEveryClientHandlesBaseURLsWithAndWithoutATrailingSlash() async {
        let paths: [AIProviderKind: String] = [.anthropic: "messages", .openAI: "responses", .openAICompatible: "chat/completions"]
        let successes: [AIProviderKind: AITestStubResponse] = [.anthropic: aiTestAnthropicOK(), .openAI: aiTestOpenAIOK(), .openAICompatible: aiTestChatOK()]
        for kind in AIProviderKind.allCases {
            for trailingSlash in [true, false] {
                let server = AITestStubServer()
                server.enqueue(successes[kind]!)
                let result = await aiTestCollect(server.client(kind, trailingSlash: trailingSlash).stream(aiTestRequest(model: model(for: kind))))
                XCTAssertNil(result.error, "\(kind) trailingSlash=\(trailingSlash)")
                XCTAssertEqual(server.requests.map(\.url.absoluteString), ["https://\(server.host)/v1/\(paths[kind]!)"], "\(kind) trailingSlash=\(trailingSlash)")
            }
        }
    }

    func testEndpointURLJoining() throws {
        for base in ["https://example.com/v1", "https://example.com/v1/"] {
            let endpoint = AIEndpoint(kind: .anthropic, baseURL: URL(string: base)!, apiKey: "k")
            XCTAssertEqual(try endpoint.url("messages").absoluteString, "https://example.com/v1/messages")
            XCTAssertEqual(try endpoint.url("models", query: [URLQueryItem(name: "limit", value: "1000")]).absoluteString, "https://example.com/v1/models?limit=1000")
        }
        XCTAssertEqual(AIEndpoint(kind: .openAI, apiKey: "k").baseURL, AIProviderKind.openAI.defaultBaseURL)
    }

    func testFactoryPicksTheClientForTheProvider() {
        XCTAssertTrue(AIClientFactory.make(endpoint: AIEndpoint(kind: .anthropic, apiKey: "k")) is AnthropicClient)
        XCTAssertTrue(AIClientFactory.make(endpoint: AIEndpoint(kind: .openAI, apiKey: "k")) is OpenAIResponsesClient)
        XCTAssertTrue(AIClientFactory.make(endpoint: AIEndpoint(kind: .openAICompatible, apiKey: "")) is ChatCompletionsClient)
        let session = AIClientFactory.makeDefaultSession()
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 90)
        XCTAssertNil(session.configuration.urlCache)
    }

    func testMissingKeyPerProvider() async {
        for kind in AIProviderKind.allCases {
            let server = AITestStubServer()
            server.enqueue(aiTestChatOK())
            let result = await aiTestCollect(server.client(kind, apiKey: "").stream(aiTestRequest(model: model(for: kind))))
            if kind.requiresAPIKey {
                XCTAssertEqual(result.error, .missingAPIKey, "\(kind)")
                XCTAssertTrue(server.requests.isEmpty, "\(kind)")
            } else {
                XCTAssertNil(result.error, "\(kind)")
                XCTAssertEqual(server.requests.count, 1, "\(kind)")
            }
        }
    }

    // MARK: Logging

    func testRedactionMasksKeysAndImageData() {
        let key = "sk-ant-api03-SECRETSECRETSECRET"
        let base64 = aiTestImage.data.base64EncodedString()
        let message = "Invalid key \(key); Authorization: Bearer abc.def-123; url data:image/png;base64,\(base64) and raw \(base64.prefix(100))"
        let redacted = AILogRedaction.redact(message, secrets: [key])
        XCTAssertFalse(redacted.contains("SECRET"), redacted)
        XCTAssertFalse(redacted.contains("abc.def-123"), redacted)
        XCTAssertFalse(redacted.contains(String(base64.prefix(40))), redacted)
        XCTAssertTrue(redacted.hasPrefix("Invalid key [redacted]"), redacted)
        XCTAssertTrue(redacted.contains("base64,[redacted]"), redacted)

        // Masked keys echoed by providers and unknown keys are caught by pattern.
        XCTAssertEqual(AILogRedaction.redact("Incorrect API key provided: sk-proj-****abcd."), "Incorrect API key provided: sk-[redacted].")
        // Ordinary messages are untouched.
        XCTAssertEqual(AILogRedaction.redact("max_tokens: 64000 > 32000 for claude-haiku-4-5"), "max_tokens: 64000 > 32000 for claude-haiku-4-5")
    }

    func testRedactionSecretsComeFromCredentialHeaders() {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.setValue("anthropic-key", forHTTPHeaderField: "x-api-key")
        XCTAssertEqual(AILogRedaction.secrets(in: request), ["anthropic-key"])

        var bearer = URLRequest(url: URL(string: "https://example.com")!)
        bearer.setValue("Bearer openai-key", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(AILogRedaction.secrets(in: bearer), ["Bearer openai-key", "openai-key"])
    }
}

/// A thread-safe one-way flag.
final class AITestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
