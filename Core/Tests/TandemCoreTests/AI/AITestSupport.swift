import Foundation
import XCTest
@testable import TandemCore

/// A canned HTTP response served by ``AITestURLProtocol``.
struct AITestStubResponse {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "text/event-stream"]
    var chunks: [Data] = []
    /// Keep the connection open after sending `chunks` until the client cancels.
    var hangs = false
    /// Never send response headers; the request stays pending until the client cancels.
    var hangsBeforeHeaders = false
    /// End the response with this transport error after sending `chunks` (before any response
    /// when there are no chunks).
    var failure: URLError?

    static func sse(_ body: String, chunkSize: Int? = nil) -> AITestStubResponse {
        let data = Data(body.utf8)
        guard let chunkSize else { return AITestStubResponse(chunks: [data]) }
        var chunks: [Data] = []
        var start = 0
        while start < data.count {
            let end = min(start + chunkSize, data.count)
            chunks.append(data.subdata(in: start..<end))
            start = end
        }
        return AITestStubResponse(chunks: chunks)
    }

    static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> AITestStubResponse {
        var allHeaders = ["Content-Type": "application/json"]
        allHeaders.merge(headers) { _, new in new }
        return AITestStubResponse(status: status, headers: allHeaders, chunks: [Data(body.utf8)])
    }

    /// A connection that never answers (until cancelled).
    static var neverResponds: AITestStubResponse { AITestStubResponse(hangsBeforeHeaders: true) }

    /// A connection that fails with `code` before any response.
    static func transportFailure(_ code: URLError.Code) -> AITestStubResponse {
        AITestStubResponse(failure: URLError(code))
    }
}

/// A request captured by the stub.
struct AITestRecordedRequest {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data?

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: [String: Any] {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }
}

/// An in-process fake server: responses are queued per test and matched by the unique host of
/// ``baseURL``, so parallel tests never share state.
final class AITestStubServer: @unchecked Sendable {
    let host: String
    let session: URLSession
    private let lock = NSLock()
    private var pending: [AITestStubResponse] = []
    private var recorded: [AITestRecordedRequest] = []
    private var stops = 0

    init() {
        host = "stub-\(UUID().uuidString.lowercased()).aitest.invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AITestURLProtocol.self]
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
        AITestURLProtocol.register(self)
    }

    deinit {
        AITestURLProtocol.unregister(host)
    }

    /// `https://<unique host>/v1/` (with or without the trailing slash).
    func baseURL(trailingSlash: Bool = true) -> URL {
        URL(string: "https://\(host)/v1\(trailingSlash ? "/" : "")")!
    }

    func endpoint(_ kind: AIProviderKind, apiKey: String = "test-key", trailingSlash: Bool = true) -> AIEndpoint {
        AIEndpoint(kind: kind, baseURL: baseURL(trailingSlash: trailingSlash), apiKey: apiKey)
    }

    func enqueue(_ responses: AITestStubResponse...) {
        lock.withLock { pending.append(contentsOf: responses) }
    }

    var requests: [AITestRecordedRequest] { lock.withLock { recorded } }
    var stopCount: Int { lock.withLock { stops } }

    fileprivate func next(for request: AITestRecordedRequest) -> AITestStubResponse {
        lock.withLock {
            recorded.append(request)
            if pending.isEmpty { return .json(599, #"{"error":{"message":"no stub queued"}}"#) }
            return pending.removeFirst()
        }
    }

    fileprivate func didStop() {
        lock.withLock { stops += 1 }
    }
}

/// `URLProtocol` that serves ``AITestStubServer`` responses.
final class AITestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var servers: [String: AITestStubServer] = [:]

    static func register(_ server: AITestStubServer) {
        registryLock.withLock { servers[server.host] = server }
    }

    static func unregister(_ host: String) {
        registryLock.withLock { _ = servers.removeValue(forKey: host) }
    }

    private static func server(for host: String?) -> AITestStubServer? {
        guard let host else { return nil }
        return registryLock.withLock { servers[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let recorded = AITestRecordedRequest(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request)
        )
        let stub = server.next(for: recorded)
        if stub.hangsBeforeHeaders { return }
        if let failure = stub.failure, stub.chunks.isEmpty {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if let failure = stub.failure {
            // Fail a moment later on this protocol's run loop; URLSession drops body bytes that
            // are followed immediately by a failure.
            let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.client?.urlProtocol(self, didFailWithError: failure)
            }
            RunLoop.current.add(timer, forMode: .common)
        } else if !stub.hangs {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.server(for: request.url?.host)?.didStop()
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Builds an SSE body from `(event name, JSON data)` pairs.
func aiTestSSE(_ events: [(String?, String)]) -> String {
    events.map { name, data in
        (name.map { "event: \($0)\n" } ?? "") + "data: \(data)\n\n"
    }.joined()
}

/// Collects every event of `stream`, plus the error that ended it (if any).
func aiTestCollect(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async -> (events: [AIStreamEvent], error: AIError?) {
    var events: [AIStreamEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error as? AIError ?? .network("unexpected \(type(of: error))"))
    }
}

extension Array where Element == AIStreamEvent {
    var aiTestText: String {
        compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }.joined()
    }

    var aiTestReasoning: String {
        compactMap { if case .reasoningDelta(let text) = $0 { return text } else { return nil } }.joined()
    }

    var aiTestNotices: [String] {
        compactMap { if case .notice(let text) = $0 { return text } else { return nil } }
    }

    var aiTestCompletion: AICompletion? {
        for event in self { if case .completed(let completion) = event { return completion } }
        return nil
    }
}

/// A small valid PNG-ish payload (bytes don't matter to the clients).
let aiTestImage = AIImage(data: Data((0..<3000).map { UInt8($0 % 251) }), mimeType: "image/png", width: 40, height: 30)

extension AITestStubServer {
    var anthropic: AnthropicClient { AnthropicClient(endpoint: endpoint(.anthropic), session: session) }
    var openAI: OpenAIResponsesClient { OpenAIResponsesClient(endpoint: endpoint(.openAI), session: session) }
    /// A keyless OpenAI-compatible client (local servers usually need no key).
    var chat: ChatCompletionsClient { ChatCompletionsClient(endpoint: endpoint(.openAICompatible, apiKey: ""), session: session) }

    /// The client for `kind`, built through ``AIClientFactory``.
    func client(_ kind: AIProviderKind, apiKey: String = "test-key", trailingSlash: Bool = true) -> any AIClient {
        AIClientFactory.make(endpoint: endpoint(kind, apiKey: apiKey, trailingSlash: trailingSlash), session: session)
    }

    /// The only request received; fails the test if there were none or several.
    func singleRequest(file: StaticString = #filePath, line: UInt = #line) -> AITestRecordedRequest? {
        let all = requests
        XCTAssertEqual(all.count, 1, "request count", file: file, line: line)
        return all.first
    }
}

/// Polls `condition` until it holds, failing the test after `timeout` seconds.
func aiTestWait(
    _ description: String,
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    until condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// A one-turn request with a screenshot, as Tandem sends it.
func aiTestRequest(
    model: String,
    effort: ReasoningEffort? = .high,
    summary: Bool = true,
    system: String = "You help with what's on screen."
) -> AIRequest {
    AIRequest(
        model: model,
        systemPrompt: system,
        turns: [.user(.text("What does this dialog want?"), .image(aiTestImage))],
        maxOutputTokens: 4096,
        effort: effort,
        includeReasoningSummary: summary
    )
}

/// A minimal successful Anthropic stream.
func aiTestAnthropicOK(model: String = "claude-opus-5-5", text: String = "OK") -> AITestStubResponse {
    .sse(aiTestSSE([
        ("message_start", #"{"type":"message_start","message":{"model":"\#(model)","usage":{"input_tokens":10,"output_tokens":1}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#),
        ("message_stop", #"{"type":"message_stop"}"#)
    ]))
}

/// A minimal successful OpenAI Responses stream.
func aiTestOpenAIOK(model: String = "gpt-6-astra", text: String = "OK") -> AITestStubResponse {
    .sse(aiTestSSE([
        ("response.created", #"{"type":"response.created","response":{"model":"\#(model)","status":"in_progress"}}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"\#(text)"}"#),
        ("response.completed", #"{"type":"response.completed","response":{"model":"\#(model)","status":"completed","usage":{"input_tokens":5,"output_tokens":1}}}"#)
    ]))
}

/// A minimal successful Chat Completions stream.
func aiTestChatOK(model: String = "local-model", text: String = "OK") -> AITestStubResponse {
    .sse(aiTestSSE([
        (nil, #"{"model":"\#(model)","choices":[{"index":0,"delta":{"role":"assistant","content":"\#(text)"}}]}"#),
        (nil, #"{"model":"\#(model)","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
        (nil, "[DONE]")
    ]))
}

/// Whether a decoded JSON tree contains `key` at any depth.
func aiTestJSONContainsKey(_ value: Any, _ key: String) -> Bool {
    if let object = value as? [String: Any] {
        return object.keys.contains(key) || object.values.contains { aiTestJSONContainsKey($0, key) }
    }
    if let array = value as? [Any] {
        return array.contains { aiTestJSONContainsKey($0, key) }
    }
    return false
}
