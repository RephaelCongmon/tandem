import Foundation
import os

/// Shared logger for the AI provider layer. Never log API keys, request bodies, or image data.
let aiLogger = Logger(subsystem: "com.rofel.tandem", category: "AI")

// MARK: - Streaming response

/// An HTTP response whose body is delivered incrementally as raw `Data` chunks.
struct HTTPStreamingResponse: Sendable {
    let response: HTTPURLResponse
    /// Body chunks in arrival order. Finishes when the server closes the response; throws on
    /// transport errors (`URLError`).
    let body: AsyncThrowingStream<Data, Error>
    fileprivate let task: URLSessionDataTask

    /// Lower-cased `Content-Type` header value (empty when absent).
    var contentType: String {
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    }

    /// Cancels the underlying HTTP request. A no-op once the response has completed.
    func cancel() {
        task.cancel()
    }
}

/// A non-2xx HTTP response, with the provider's error details extracted from the body.
struct AIHTTPFailure: Error, Sendable, Hashable {
    var status: Int
    /// Human-readable message from the error body (or the raw body / status text as a fallback).
    var message: String
    /// Provider error type, e.g. Anthropic `overloaded_error` or OpenAI `invalid_request_error`.
    var errorType: String?
    /// Provider error code, e.g. OpenAI `rate_limit_exceeded` / `insufficient_quota`.
    var errorCode: String?
    /// Seconds from `retry-after-ms` / `Retry-After`, when present.
    var retryAfter: TimeInterval?

    init(status: Int, message: String, errorType: String? = nil, errorCode: String? = nil, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.message = message
        self.errorType = errorType
        self.errorCode = errorCode
        self.retryAfter = retryAfter
    }

    init(response: HTTPURLResponse, body: Data, now: Date = Date()) {
        let details = Self.extractDetails(from: body)
        var message = details.message ?? ""
        if message.isEmpty {
            message = HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized
        }
        let retryAfterMs = Self.parseRetryAfter(response.value(forHTTPHeaderField: "retry-after-ms"), now: now).map { $0 / 1000 }
        self.init(
            status: response.statusCode,
            message: message,
            errorType: details.type,
            errorCode: details.code,
            retryAfter: retryAfterMs ?? Self.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now)
        )
    }

    /// The user-facing error for this failure.
    var aiError: AIError {
        switch status {
        case 401, 403:
            return .authentication(message)
        case 429:
            // Out of credit isn't something waiting fixes; surface it as a plain HTTP error.
            if errorCode == "insufficient_quota" || errorType == "insufficient_quota" {
                return .http(status: status, message: message)
            }
            return .rateLimited(retryAfter: retryAfter, message: message)
        case 529:
            return .overloaded(message)
        default:
            if errorType == "overloaded_error" { return .overloaded(message) }
            return .http(status: status, message: message)
        }
    }

    /// Parses a `Retry-After` value: delta-seconds (possibly fractional) or an HTTP-date.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Extracts message/type/code from the common error body shapes:
    /// Anthropic `{"type":"error","error":{"type","message"}}`, OpenAI `{"error":{"message","type","code"}}`,
    /// and the looser `{"error":"…"}`, `{"message":"…"}`, `{"detail":…}` used by compatible servers.
    private static func extractDetails(from body: Data) -> (message: String?, type: String?, code: String?) {
        guard !body.isEmpty else { return (nil, nil, nil) }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            var message: String?
            var type: String?
            var code: String?
            if let error = object["error"] as? [String: Any] {
                message = error["message"] as? String
                type = error["type"] as? String
                code = stringValue(error["code"])
            } else if let error = object["error"] as? String {
                message = error
            }
            if message?.isEmpty ?? true {
                if let text = object["message"] as? String {
                    message = text
                } else if let detail = object["detail"] as? String {
                    message = detail
                } else if let details = object["detail"] as? [[String: Any]] {
                    message = details.compactMap { $0["msg"] as? String }.joined(separator: "; ")
                }
            }
            if type == nil, let topType = object["type"] as? String, topType != "error" { type = topType }
            if code == nil { code = stringValue(object["code"]) }
            return (message.map(truncated), type, code)
        }
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? nil : truncated(text), nil, nil)
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func truncated(_ text: String) -> String {
        text.count > 500 ? String(text.prefix(500)) + "…" : text
    }
}

// MARK: - Transport

/// Streaming POSTs and plain GETs on a `URLSession`, with provider-neutral error handling.
enum HTTPStreaming {
    /// Largest error body read from a failed response.
    static let maxErrorBodyBytes = 1 << 20

    /// Starts `request` and returns once response headers arrive.
    ///
    /// Body bytes are delivered by a per-task `URLSessionDataDelegate` exactly as they come off the
    /// wire (no per-byte async iteration). Cancelling the calling task — or terminating the body
    /// stream — cancels the HTTP request.
    ///
    /// - Throws: ``AIHTTPFailure`` for non-2xx responses (after reading up to 1 MB of the error
    ///   body), `URLError` for transport failures, `CancellationError` if already cancelled.
    static func open(_ request: URLRequest, session: URLSession) async throws -> HTTPStreamingResponse {
        try Task.checkCancellation()
        let (body, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = session.dataTask(with: request)
        let delegate = HTTPStreamingTaskDelegate(body: continuation)
        task.delegate = delegate
        continuation.onTermination = { _ in task.cancel() }

        let response = try await withTaskCancellationHandler {
            try await delegate.start(task)
        } onCancel: {
            task.cancel()
            // Don't depend on URLSession reporting the cancellation (it may never have started).
            delegate.cancelPendingResponse()
        }

        guard (200..<300).contains(response.statusCode) else {
            let errorBody = await readPrefix(of: body, limit: maxErrorBodyBytes)
            task.cancel()
            let failure = AIHTTPFailure(response: response, body: errorBody)
            logFailure(failure, for: request)
            throw failure
        }
        return HTTPStreamingResponse(response: response, body: body, task: task)
    }

    private static func logFailure(_ failure: AIHTTPFailure, for request: URLRequest) {
        let message = AILogRedaction.redact(failure.message, secrets: AILogRedaction.secrets(in: request))
        aiLogger.error("HTTP \(failure.status, privacy: .public) from \(request.url?.host ?? "?", privacy: .public) \(request.url?.path ?? "", privacy: .public): \(message, privacy: .private)")
    }

    /// Performs a small non-streaming request (e.g. listing models) and returns the body.
    /// - Throws: ``AIHTTPFailure`` for non-2xx responses, `URLError` for transport failures.
    static func data(for request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.malformedStream("The server did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = AIHTTPFailure(response: http, body: data.prefix(maxErrorBodyBytes))
            logFailure(failure, for: request)
            throw failure
        }
        return data
    }

    /// Reads a whole (non-streamed) body, failing if it grows beyond `limit` bytes.
    static func readBody(of body: AsyncThrowingStream<Data, Error>, limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count > limit {
                throw AIError.malformedStream("The response was larger than \(limit / (1024 * 1024)) MB.")
            }
        }
        try Task.checkCancellation()
        return data
    }

    /// Reads at most `limit` bytes of `body`, tolerating transport errors (used for error bodies).
    private static func readPrefix(of body: AsyncThrowingStream<Data, Error>, limit: Int) async -> Data {
        var data = Data()
        do {
            for try await chunk in body {
                data.append(chunk)
                if data.count >= limit { break }
            }
        } catch {
            aiLogger.debug("Stopped reading an error body: \(error.localizedDescription, privacy: .public)")
        }
        return data.count > limit ? data.prefix(limit) : data
    }

    /// Decodes the SSE body of `response` through `parser`, yielding its events to `continuation`
    /// until the parser reports completion or the body ends. Always cancels the HTTP request on exit.
    static func pump<Parser: AIStreamParser>(
        _ response: HTTPStreamingResponse,
        parser: inout Parser,
        into continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        defer { response.cancel() }
        var decoder = SSEDecoder()
        for try await chunk in response.body {
            for event in try decoder.feed(chunk) {
                for output in try parser.consume(event) { continuation.yield(output) }
                if parser.isFinished { return }
            }
        }
        // A cancelled consumer ends the body early; that must not look like a truncated stream.
        try Task.checkCancellation()
        for event in try decoder.finish() {
            for output in try parser.consume(event) { continuation.yield(output) }
            if parser.isFinished { return }
        }
        for output in try parser.finish() { continuation.yield(output) }
    }
}

/// Receives one data task's callbacks and forwards body chunks into an `AsyncThrowingStream`.
private final class HTTPStreamingTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let body: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var pendingResponse: CheckedContinuation<HTTPURLResponse, Error>?
    /// The first response outcome. Kept so an outcome that arrives before ``start(_:)`` registers
    /// its continuation (e.g. a cancellation racing the start) resumes it instead of being lost.
    private var outcome: Result<HTTPURLResponse, Error>?

    init(body: AsyncThrowingStream<Data, Error>.Continuation) {
        self.body = body
    }

    /// Resumes `task` and waits for its response headers (or failure).
    func start(_ task: URLSessionDataTask) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            let early = lock.withLock { () -> Result<HTTPURLResponse, Error>? in
                if let outcome { return outcome }
                pendingResponse = continuation
                return nil
            }
            if let early {
                continuation.resume(with: early)
            } else {
                task.resume()
            }
        }
    }

    /// Fails a pending (or future) ``start(_:)`` with `URLError(.cancelled)`.
    func cancelPendingResponse() {
        resolveResponse(.failure(URLError(.cancelled)))
    }

    /// Records the response outcome and resumes the waiter; only the first outcome counts.
    private func resolveResponse(_ result: Result<HTTPURLResponse, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { pendingResponse = nil }
            return pendingResponse
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            resolveResponse(.failure(AIError.malformedStream("The server did not return an HTTP response.")))
            completionHandler(.cancel)
            return
        }
        resolveResponse(.success(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resolveResponse(.failure(error))
            body.finish(throwing: error)
        } else {
            resolveResponse(.failure(AIError.malformedStream("The connection closed before a response arrived.")))
            body.finish()
        }
    }
}

// MARK: - Event streams

/// Incremental parser turning provider SSE events into ``AIStreamEvent``s.
protocol AIStreamParser {
    /// True once the terminal event (e.g. `message_stop`) was consumed; no more input is needed.
    var isFinished: Bool { get }
    /// Consumes one SSE event and returns the events it produced.
    mutating func consume(_ event: SSEEvent) throws -> [AIStreamEvent]
    /// Called when the body ends before ``isFinished``: completes or throws `.malformedStream`.
    mutating func finish() throws -> [AIStreamEvent]
}

enum AIEventStream {
    typealias Continuation = AsyncThrowingStream<AIStreamEvent, Error>.Continuation

    /// Runs `operation` in a task that is cancelled when the returned stream terminates (consumer
    /// cancelled or dropped it). Every thrown error is mapped to ``AIError``; cancellation surfaces
    /// as ``AIError/cancelled``. `secrets` (the API key) are masked if an error message echoes them.
    static func make(
        redacting secrets: [String] = [],
        _ operation: @escaping @Sendable (Continuation) async throws -> Void
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await operation(continuation)
                    continuation.finish()
                } catch {
                    let mapped = Task.isCancelled ? AIError.cancelled : AIError.wrapping(error)
                    if mapped != .cancelled {
                        let description = AILogRedaction.redact(mapped.localizedDescription, secrets: secrets)
                        aiLogger.error("AI stream failed: \(description, privacy: .private)")
                    }
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Log redaction

/// Masks credentials and encoded image data in text headed for the log. Provider error messages
/// can echo request fields (a mistyped key, an invalid image URL), so they're scrubbed first.
enum AILogRedaction {
    /// Runs of base64-alphabet characters at least this long are treated as binary payloads.
    static let longDataRunLength = 64

    static func redact(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        let patterns: [(pattern: String, template: String)] = [
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer [redacted]"),
            (#"\bsk-[A-Za-z0-9_*\-]{4,}"#, "sk-[redacted]"),
            (#"(?i)base64,[A-Za-z0-9+/=_\-]+"#, "base64,[redacted]"),
            ("[A-Za-z0-9+/=_\\-]{\(longDataRunLength),}", "[redacted data]")
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// Credential header values of `request` (the bare key for `Authorization: Bearer …`).
    static func secrets(in request: URLRequest) -> [String] {
        var secrets: [String] = []
        if let key = request.value(forHTTPHeaderField: "x-api-key") { secrets.append(key) }
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            secrets.append(authorization)
            if authorization.lowercased().hasPrefix("bearer ") {
                secrets.append(String(authorization.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return secrets.sorted { $0.count > $1.count }
    }
}

// MARK: - Shared helpers

extension AIError {
    /// Maps any error from the transport or parsing layers to an ``AIError``.
    static func wrapping(_ error: Error) -> AIError {
        if let error = error as? AIError { return error }
        if let failure = error as? AIHTTPFailure { return failure.aiError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            default: return .network(urlError.localizedDescription)
            }
        }
        if error is DecodingError { return .malformedStream("The response couldn't be decoded.") }
        return .network(error.localizedDescription)
    }
}

extension AIEndpoint {
    /// The trimmed API key.
    /// - Throws: ``AIError/missingAPIKey`` when the provider requires a key and none is set.
    func validatedAPIKey() throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty, kind.requiresAPIKey { throw AIError.missingAPIKey }
        return key
    }

    /// `baseURL` with `path` appended; works whether or not `baseURL` ends in a slash.
    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let url = baseURL.appendingPathComponent(path)
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AIError.invalidConfiguration("The provider URL \(baseURL.absoluteString) is invalid.")
        }
        components.queryItems = (components.queryItems ?? []) + query
        guard let result = components.url else {
            throw AIError.invalidConfiguration("The provider URL \(baseURL.absoluteString) is invalid.")
        }
        return result
    }
}

extension AIRequest {
    /// The trimmed model id.
    /// - Throws: ``AIError/invalidConfiguration(_:)`` for an empty model, no turns, or a
    ///   non-positive output limit.
    func validatedModel() throws -> String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.invalidConfiguration("Choose a model in Settings → AI.") }
        guard !turns.isEmpty else { throw AIError.invalidConfiguration("There's nothing to send yet.") }
        guard maxOutputTokens > 0 else { throw AIError.invalidConfiguration("The output token limit must be positive.") }
        return model
    }
}

extension URLRequest {
    /// A request carrying a JSON body, using the session's idle timeout.
    static func aiJSONPost(url: URL, body: JSONValue, session: URLSession, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = session.configuration.timeoutIntervalForRequest
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body.serialized()
        return request
    }

    /// A GET request with the session's idle timeout.
    static func aiGet(url: URL, session: URLSession, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = session.configuration.timeoutIntervalForRequest
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

extension Array where Element == AIModelInfo {
    /// Newest first; undated models last, keeping their original relative order.
    func sortedNewestFirst() -> [AIModelInfo] {
        enumerated().sorted { lhs, rhs in
            switch (lhs.element.createdAt, rhs.element.createdAt) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
