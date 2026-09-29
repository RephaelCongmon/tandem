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
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if !stub.hangs {
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
