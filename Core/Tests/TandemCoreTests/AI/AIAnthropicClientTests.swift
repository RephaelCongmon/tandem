import XCTest
@testable import TandemCore

/// Anthropic client behavior around the stream: degrade-retries, HTTP errors, configuration, models.
final class AIAnthropicClientTests: XCTestCase {
    private func anthropicError(_ status: Int, type: String = "invalid_request_error", _ message: String, headers: [String: String] = [:]) -> AITestStubResponse {
        .json(status, #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#, headers: headers)
    }

    // MARK: Degrade-retry

    func testFallbacksRejectionRetriesWithoutFallbacksOrBetaHeader() async throws {
        let server = AITestStubServer()
        server.enqueue(anthropicError(400, "fallbacks: unsupported"), aiTestAnthropicOK(text: "Recovered"))
        let result = await aiTestCollect(server.anthropic.stream(aiTestRequest(model: "claude-opus-5-5")))

        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.aiTestText, "Recovered")
        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        guard requests.count == 2 else { return }

        XCTAssertEqual(requests[0].json["fallbacks"] as? String, "default")
        XCTAssertEqual(requests[0].header("anthropic-beta"), "server-side-fallback-2026-07-01")

        XCTAssertNil(requests[1].json["fallbacks"])
        XCTAssertNil(requests[1].header("anthropic-beta"))
        // Everything else is unchanged.
        XCTAssertEqual(requests[1].json["thinking"] as? [String: String], ["type": "adaptive", "display": "summarized"])
        XCTAssertEqual(requests[1].json["output_config"] as? [String: String], ["effort": "high"])
        XCTAssertEqual(requests[1].header("x-api-key"), "test-key")
    }

    func testEachOptionalFeatureIsDroppedInTurnThenTheErrorSurfaces() async {
        let server = AITestStubServer()
        server.enqueue(
            anthropicError(400, "anthropic-beta: unknown beta"),
            anthropicError(400, "output_config.effort: Extra inputs are not permitted"),
            anthropicError(400, "thinking.display: unsupported value"),
            anthropicError(400, "thinking: still unhappy")
        )
        let result = await aiTestCollect(server.anthropic.stream(aiTestRequest(model: "claude-opus-5-5")))

        XCTAssertEqual(result.error, .http(status: 400, message: "thinking: still unhappy"))
        let bodies = server.requests.map(\.json)
        XCTAssertEqual(bodies.count, 4, "three degrade-retries, then give up")
        guard bodies.count == 4 else { return }
        XCTAssertNotNil(bodies[0]["fallbacks"])
        XCTAssertNil(bodies[1]["fallbacks"])
        XCTAssertNotNil(bodies[1]["output_config"])
        XCTAssertNil(bodies[2]["output_config"])
        XCTAssertNotNil(bodies[2]["thinking"])
        XCTAssertNil(bodies[3]["thinking"])
        XCTAssertNil(bodies[3]["fallbacks"])
        XCTAssertEqual(bodies[3]["cache_control"] as? [String: String], ["type": "ephemeral"])
    }

    func testUnrelatedOrNon400ErrorsAreNotRetried() async {
        let server = AITestStubServer()
        server.enqueue(anthropicError(400, "messages.0.content.1.image.source: invalid image"))
        let first = await aiTestCollect(server.anthropic.stream(aiTestRequest(model: "claude-opus-5-5")))
        XCTAssertEqual(first.error, .http(status: 400, message: "messages.0.content.1.image.source: invalid image"))
        XCTAssertEqual(server.requests.count, 1)

        let other = AITestStubServer()
        other.enqueue(anthropicError(422, "fallbacks: unsupported"))
        let second = await aiTestCollect(other.anthropic.stream(aiTestRequest(model: "claude-opus-5-5")))
        XCTAssertEqual(second.error, .http(status: 422, message: "fallbacks: unsupported"))
        XCTAssertEqual(other.requests.count, 1)
    }

    func testFeaturesThatWerentSentAreNotDegraded() async {
        // Opus 4.8 sends no fallbacks, so a fallback-worded 400 has nothing to drop.
        let server = AITestStubServer()
        server.enqueue(anthropicError(400, "fallbacks: unsupported"))
        let result = await aiTestCollect(server.anthropic.stream(aiTestRequest(model: "claude-opus-4-8")))
        XCTAssertEqual(result.error, .http(status: 400, message: "fallbacks: unsupported"))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testDegradeRules() {
        let all = AnthropicWireOptions(fallbacks: true, effort: true, thinking: true)
        XCTAssertEqual(AnthropicClient.degrade(all, status: 400, message: "Unknown FALLBACKS parameter"),
                       AnthropicWireOptions(fallbacks: false, effort: true, thinking: true))
        XCTAssertEqual(AnthropicClient.degrade(all, status: 400, message: "effort: not supported"),
                       AnthropicWireOptions(fallbacks: true, effort: false, thinking: true))
        XCTAssertEqual(AnthropicClient.degrade(all, status: 400, message: "display must be one of…"),
                       AnthropicWireOptions(fallbacks: true, effort: true, thinking: false))
        XCTAssertNil(AnthropicClient.degrade(all, status: 400, message: "max_tokens too large"))
        XCTAssertNil(AnthropicClient.degrade(all, status: 500, message: "fallbacks"))
        XCTAssertNil(AnthropicClient.degrade(AnthropicWireOptions(fallbacks: false, effort: false, thinking: false), status: 400, message: "thinking"))
    }

    // MARK: HTTP errors

    func testHTTPErrorMapping() async {
        let cases: [(AITestStubResponse, AIError)] = [
            (anthropicError(401, type: "authentication_error", "invalid x-api-key"), .authentication("invalid x-api-key")),
            (anthropicError(403, type: "permission_error", "not allowed"), .authentication("not allowed")),
            (anthropicError(429, type: "rate_limit_error", "Number of requests exceeded", headers: ["Retry-After": "12"]),
             .rateLimited(retryAfter: 12, message: "Number of requests exceeded")),
            (anthropicError(429, type: "rate_limit_error", "slow down", headers: ["retry-after-ms": "1500", "Retry-After": "2"]),
             .rateLimited(retryAfter: 1.5, message: "slow down")),
            (anthropicError(429, type: "rate_limit_error", "no header"), .rateLimited(retryAfter: nil, message: "no header")),
            (anthropicError(529, type: "overloaded_error", "Overloaded"), .overloaded("Overloaded")),
            (anthropicError(503, type: "overloaded_error", "Overloaded"), .overloaded("Overloaded")),
            (anthropicError(500, type: "api_error", "Internal server error"), .http(status: 500, message: "Internal server error")),
            (.json(502, "<html>Bad gateway</html>"), .http(status: 502, message: "<html>Bad gateway</html>")),
            (.json(404, ""), .http(status: 404, message: "Not Found"))
        ]
        for (stub, expected) in cases {
            let server = AITestStubServer()
            server.enqueue(stub)
            let result = await aiTestCollect(server.anthropic.stream(aiTestRequest(model: "claude-opus-5-5")))
            XCTAssertEqual(result.error, expected)
            XCTAssertEqual(result.events, [], "no events before an HTTP error")
            XCTAssertEqual(server.requests.count, 1, "\(expected) is not retried")
        }
    }

    func testRetryAfterHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let later = now.addingTimeInterval(30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(AIHTTPFailure.parseRetryAfter(formatter.string(from: later), now: now), 30)
        XCTAssertNil(AIHTTPFailure.parseRetryAfter("soon", now: now))
        XCTAssertNil(AIHTTPFailure.parseRetryAfter("-5", now: now))
        XCTAssertEqual(AIHTTPFailure.parseRetryAfter(" 7 ", now: now), 7)
    }

    // MARK: Configuration

    func testMissingKeyFailsImmediatelyWithoutARequest() async {
        for key in ["", "   \n"] {
            let server = AITestStubServer()
            let client = AnthropicClient(endpoint: server.endpoint(.anthropic, apiKey: key), session: server.session)
            let result = await aiTestCollect(client.stream(aiTestRequest(model: "claude-opus-5-5")))
            XCTAssertEqual(result.error, .missingAPIKey)
            XCTAssertEqual(result.events, [])
            do {
                _ = try await client.listModels()
                XCTFail("listModels should throw")
            } catch {
                XCTAssertEqual(error as? AIError, .missingAPIKey)
            }
            XCTAssertTrue(server.requests.isEmpty)
        }
    }

    func testKeyIsTrimmed() async {
        let server = AITestStubServer()
        server.enqueue(aiTestAnthropicOK())
        let client = AnthropicClient(endpoint: server.endpoint(.anthropic, apiKey: "  sk-ant-abc\n"), session: server.session)
        _ = await aiTestCollect(client.stream(aiTestRequest(model: "claude-opus-5-5")))
        XCTAssertEqual(server.singleRequest()?.header("x-api-key"), "sk-ant-abc")
    }

    func testEmptyModelIsInvalidConfiguration() async {
        let server = AITestStubServer()
        let result = await aiTestCollect(server.anthropic.stream(aiTestRequest(model: "  ")))
        guard case .invalidConfiguration = result.error else { return XCTFail("got \(String(describing: result.error))") }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testBaseURLWithAndWithoutTrailingSlash() async {
        for trailingSlash in [true, false] {
            let server = AITestStubServer()
            server.enqueue(aiTestAnthropicOK(), .json(200, #"{"data":[],"has_more":false}"#))
            let client = AnthropicClient(endpoint: server.endpoint(.anthropic, trailingSlash: trailingSlash), session: server.session)
            let result = await aiTestCollect(client.stream(aiTestRequest(model: "claude-opus-5-5")))
            XCTAssertNil(result.error)
            _ = try? await client.listModels()
            XCTAssertEqual(server.requests.map(\.url.absoluteString), [
                "https://\(server.host)/v1/messages",
                "https://\(server.host)/v1/models?limit=1000"
            ], "trailingSlash=\(trailingSlash)")
        }
    }

    // MARK: Models

    func testListModelsPaginatesAndSortsNewestFirst() async throws {
        let server = AITestStubServer()
        server.enqueue(
            .json(200, #"""
            {"data":[
              {"type":"model","id":"claude-opus-4-8","display_name":"Claude Opus 4.8","created_at":"2026-02-10T00:00:00Z"},
              {"type":"model","id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","created_at":"2025-10-01T00:00:00Z"}
            ],"has_more":true,"first_id":"claude-opus-4-8","last_id":"claude-haiku-4-5"}
            """#),
            .json(200, #"""
            {"data":[
              {"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-08-20T12:30:00.123Z"},
              {"type":"model","id":"claude-legacy-undated"}
            ],"has_more":false,"first_id":"claude-opus-5-5","last_id":"claude-legacy-undated"}
            """#)
        )
        let models = try await server.anthropic.listModels()

        XCTAssertEqual(models.map(\.id), ["claude-opus-5-5", "claude-opus-4-8", "claude-haiku-4-5", "claude-legacy-undated"])
        XCTAssertEqual(models.first?.displayName, "Claude Opus 5.5")
        XCTAssertEqual(models.last?.displayName, "claude-legacy-undated", "the id stands in for a missing display name")
        XCTAssertNotNil(models.first?.createdAt, "fractional-second dates parse")
        XCTAssertNil(models.last?.createdAt)

        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        guard requests.count == 2 else { return }
        for request in requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.path, "/v1/models")
            XCTAssertEqual(request.header("x-api-key"), "test-key")
            XCTAssertEqual(request.header("anthropic-version"), "2023-06-01")
        }
        let firstQuery = URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(firstQuery, [URLQueryItem(name: "limit", value: "1000")])
        let secondQuery = URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(secondQuery, [URLQueryItem(name: "limit", value: "1000"), URLQueryItem(name: "after_id", value: "claude-haiku-4-5")])
    }

    func testListModelsErrorsMap() async {
        let server = AITestStubServer()
        server.enqueue(anthropicError(401, type: "authentication_error", "invalid x-api-key"))
        do {
            _ = try await server.anthropic.listModels()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AIError, .authentication("invalid x-api-key"))
        }

        let garbage = AITestStubServer()
        garbage.enqueue(.json(200, "not json"))
        do {
            _ = try await garbage.anthropic.listModels()
            XCTFail("expected an error")
        } catch {
            guard case .malformedStream = error as? AIError else { return XCTFail("got \(error)") }
        }
    }
}
