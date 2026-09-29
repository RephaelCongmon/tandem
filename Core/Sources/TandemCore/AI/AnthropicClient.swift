import Foundation

/// Streaming client for the Anthropic Messages API (Claude), over raw HTTP + SSE.
///
/// Requests are shaped per model by ``ModelCatalog/anthropicCapabilities(for:)``: adaptive thinking
/// and `thinking.display`, `output_config.effort`, and server-side safety fallbacks
/// (`"fallbacks": "default"`). The conversation prefix is cached automatically with a top-level
/// `cache_control`, which matters because screenshots repeat across turns. If the API rejects an
/// optional feature with HTTP 400, the request is retried without it (at most three times, always
/// before any stream bytes arrive).
public struct AnthropicClient: AIClient {
    /// Value of the `anthropic-version` header.
    public static let apiVersion = "2023-06-01"
    /// Beta header value that enables `"fallbacks": "default"`.
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Maximum number of feature-degrading retries per request.
    static let maxDegradeRetries = 3

    public let endpoint: AIEndpoint
    private let session: URLSession

    /// - Parameters:
    ///   - endpoint: Base URL (e.g. `https://api.anthropic.com/v1/`) and API key.
    ///   - session: Session used for all requests; defaults to ``AIClientFactory/defaultSession``.
    public init(endpoint: AIEndpoint, session: URLSession = AIClientFactory.defaultSession) {
        self.endpoint = endpoint
        self.session = session
    }

    // MARK: Streaming

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AIEventStream.make(redacting: [endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)]) { continuation in
            try await run(request, continuation: continuation)
        }
    }

    private func run(_ request: AIRequest, continuation: AIEventStream.Continuation) async throws {
        let apiKey = try endpoint.validatedAPIKey()
        let model = try request.validatedModel()
        let capabilities = ModelCatalog.anthropicCapabilities(for: model)
        var options = AnthropicWireOptions.initial(for: request, capabilities: capabilities)
        var retries = 0

        while true {
            let urlRequest = try makeURLRequest(for: request, capabilities: capabilities, options: options, apiKey: apiKey)
            let response: HTTPStreamingResponse
            do {
                response = try await HTTPStreaming.open(urlRequest, session: session)
            } catch let failure as AIHTTPFailure {
                if retries < Self.maxDegradeRetries,
                   let degraded = Self.degrade(options, status: failure.status, message: failure.message) {
                    retries += 1
                    aiLogger.notice("Claude rejected an optional feature for \(model, privacy: .public); retrying without it (\(degraded.summary, privacy: .public))")
                    options = degraded
                    continue
                }
                throw failure.aiError
            }
            var parser = AnthropicStreamParser(includeReasoning: request.includeReasoningSummary)
            try await HTTPStreaming.pump(response, parser: &parser, into: continuation)
            return
        }
    }

    // MARK: Request building

    func makeURLRequest(
        for request: AIRequest,
        capabilities: ModelCapabilities,
        options: AnthropicWireOptions,
        apiKey: String
    ) throws -> URLRequest {
        let body = try Self.makeBody(for: request, capabilities: capabilities, options: options)
        var headers = authHeaders(apiKey: apiKey)
        if options.fallbacks { headers["anthropic-beta"] = Self.fallbackBeta }
        return URLRequest.aiJSONPost(url: try endpoint.url("messages"), body: body, session: session, headers: headers)
    }

    private func authHeaders(apiKey: String) -> [String: String] {
        var headers = ["anthropic-version": Self.apiVersion]
        if !apiKey.isEmpty { headers["x-api-key"] = apiKey }
        return headers
    }

    /// The JSON body for `request`. Never includes `budget_tokens`, sampling parameters, or an
    /// assistant prefill.
    static func makeBody(for request: AIRequest, capabilities: ModelCapabilities, options: AnthropicWireOptions) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model.trimmingCharacters(in: .whitespacesAndNewlines)),
            "max_tokens": .int(request.maxOutputTokens),
            "stream": true,
            "messages": .array(try makeMessages(from: request.turns)),
            "cache_control": ["type": "ephemeral"]
        ]
        if !request.systemPrompt.isBlank {
            body["system"] = .string(request.systemPrompt)
        }
        if options.thinking, let thinking = thinkingConfig(for: request, capabilities: capabilities) {
            body["thinking"] = thinking
        }
        if options.effort, let effort = capabilities.resolvedEffort(request.effort) {
            body["output_config"] = ["effort": .string(effort.rawValue)]
        }
        if options.fallbacks {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    /// The `thinking` parameter for `request`, or `nil` when it should be omitted.
    static func thinkingConfig(for request: AIRequest, capabilities: ModelCapabilities) -> JSONValue? {
        if capabilities.sendsThinkingParam {
            var thinking: [String: JSONValue] = ["type": "adaptive"]
            if capabilities.supportsThinkingDisplay {
                thinking["display"] = .string(request.includeReasoningSummary ? "summarized" : "omitted")
            }
            return .object(thinking)
        }
        if capabilities.supportsThinkingDisplay, request.includeReasoningSummary {
            return ["type": "adaptive", "display": "summarized"]
        }
        return nil
    }

    /// Converts turns to Messages API `messages`: blank text parts and empty turns are skipped,
    /// consecutive same-role turns are merged (the API requires alternation), and leading assistant
    /// turns are dropped.
    /// - Throws: ``AIError/invalidConfiguration(_:)`` when nothing remains or the last turn isn't
    ///   from the user (that would be an assistant prefill, which current models reject).
    static func makeMessages(from turns: [AITurn]) throws -> [JSONValue] {
        var messages: [(role: AIRole, content: [JSONValue])] = []
        for turn in turns {
            var blocks: [JSONValue] = []
            for part in turn.parts {
                switch part {
                case .text(let text):
                    guard !text.isBlank else { continue }
                    blocks.append(["type": "text", "text": .string(text)])
                case .image(let image):
                    // Assistant turns can't carry images; we never replay model output as images.
                    guard turn.role == .user, !image.data.isEmpty else { continue }
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": .string(image.mimeType),
                            "data": .base64(image.data, prefix: "")
                        ]
                    ])
                }
            }
            guard !blocks.isEmpty else { continue }
            if let last = messages.indices.last, messages[last].role == turn.role {
                messages[last].content.append(contentsOf: blocks)
            } else {
                messages.append((turn.role, blocks))
            }
        }
        while messages.first?.role == .assistant { messages.removeFirst() }
        guard let last = messages.last else {
            throw AIError.invalidConfiguration("There's nothing to send yet — add a question or a screenshot.")
        }
        guard last.role == .user else {
            throw AIError.invalidConfiguration("The conversation must end with a user turn.")
        }
        return messages.map { ["role": .string($0.role.rawValue), "content": .array($0.content)] }
    }

    /// Decides whether an HTTP error can be retried with an optional feature removed.
    ///
    /// Only HTTP 400s qualify. The message is checked for, in order: `fallback`/`anthropic-beta`
    /// (drop fallbacks + beta header), `effort`/`output_config` (drop effort), `thinking`/`display`
    /// (drop thinking). Features already off are skipped.
    /// - Returns: The options for the retry, or `nil` if the error isn't recoverable this way.
    static func degrade(_ options: AnthropicWireOptions, status: Int, message: String) -> AnthropicWireOptions? {
        guard status == 400 else { return nil }
        let text = message.lowercased()
        var next = options
        if options.fallbacks, text.contains("fallback") || text.contains("anthropic-beta") {
            next.fallbacks = false
        } else if options.effort, text.contains("effort") || text.contains("output_config") {
            next.effort = false
        } else if options.thinking, text.contains("thinking") || text.contains("display") {
            next.thinking = false
        } else {
            return nil
        }
        return next
    }

    // MARK: Models

    public func listModels() async throws -> [AIModelInfo] {
        do {
            let apiKey = try endpoint.validatedAPIKey()
            let decoder = JSONDecoder.aiProviderDecoder()
            var models: [AIModelInfo] = []
            var seen = Set<String>()
            var afterID: String?
            for _ in 0..<50 { // hard stop against a misbehaving paginator
                var query = [URLQueryItem(name: "limit", value: "1000")]
                if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
                let urlRequest = URLRequest.aiGet(url: try endpoint.url("models", query: query), session: session, headers: authHeaders(apiKey: apiKey))
                let data = try await HTTPStreaming.data(for: urlRequest, session: session)
                guard let page = try? decoder.decode(AnthropicModelPage.self, from: data) else {
                    throw AIError.malformedStream("The model list couldn't be read.")
                }
                for model in page.data where seen.insert(model.id).inserted {
                    models.append(AIModelInfo(
                        id: model.id,
                        displayName: model.displayName ?? model.id,
                        createdAt: Self.parseDate(model.createdAt)
                    ))
                }
                guard page.hasMore == true, let lastID = page.lastId ?? page.data.last?.id, lastID != afterID else { break }
                afterID = lastID
            }
            return models.sortedNewestFirst()
        } catch {
            throw AIError.wrapping(error)
        }
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }
}

/// Which optional request features are currently being sent (flipped off by degrade-retries).
struct AnthropicWireOptions: Hashable, Sendable {
    var fallbacks: Bool
    var effort: Bool
    var thinking: Bool

    static func initial(for request: AIRequest, capabilities: ModelCapabilities) -> AnthropicWireOptions {
        AnthropicWireOptions(
            fallbacks: capabilities.supportsFallbacks,
            effort: capabilities.resolvedEffort(request.effort) != nil,
            thinking: AnthropicClient.thinkingConfig(for: request, capabilities: capabilities) != nil
        )
    }

    var summary: String {
        "fallbacks: \(fallbacks), effort: \(effort), thinking: \(thinking)"
    }
}

// MARK: - Stream parsing

/// Turns Messages API SSE events into ``AIStreamEvent``s.
struct AnthropicStreamParser: AIStreamParser {
    /// Forward thinking text as `.reasoningDelta` (off when the caller didn't ask for a summary —
    /// some models summarize by default).
    let includeReasoning: Bool
    private(set) var isFinished = false

    private let decoder = JSONDecoder.aiProviderDecoder()
    private var servedModel: String?
    private var usage = AIUsage()
    private var sawUsage = false
    private var stopReason: String?
    private var stopDetails: Payload.StopDetails?
    private var reasoningEmitted = false
    private var needsReasoningSeparator = false

    init(includeReasoning: Bool) {
        self.includeReasoning = includeReasoning
    }

    private static let decodedTypes: Set<String> = [
        "message_start", "content_block_start", "content_block_delta", "message_delta", "error"
    ]

    mutating func consume(_ event: SSEEvent) throws -> [AIStreamEvent] {
        guard !isFinished, let type = event.resolvedType(using: decoder) else { return [] }
        if type == "message_stop" {
            isFinished = true
            return [.completed(makeCompletion())]
        }
        guard Self.decodedTypes.contains(type) else { return [] } // ping, content_block_stop, future events

        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: Data(event.data.utf8))
        } catch {
            if type == "error" {
                throw AIError.http(status: 500, message: "The provider reported an error mid-stream.")
            }
            aiLogger.debug("Ignoring undecodable \(type, privacy: .public) event")
            return []
        }

        switch type {
        case "message_start":
            servedModel = payload.message?.model
            merge(payload.message?.usage)
            return [.started(model: servedModel)]

        case "content_block_start":
            guard let block = payload.contentBlock else { return [] }
            switch block.type {
            case "text":
                if let text = block.text, !text.isEmpty { return [.textDelta(text)] }
            case "thinking":
                if reasoningEmitted { needsReasoningSeparator = true }
                if let thinking = block.thinking { return reasoning(thinking) }
            case "fallback":
                return [.notice(fallbackNotice(from: block.from?.model, to: block.to?.model))]
            default:
                break // redacted_thinking, tool blocks, future block types
            }
            return []

        case "content_block_delta":
            guard let delta = payload.delta else { return [] }
            switch delta.type {
            case "text_delta":
                if let text = delta.text, !text.isEmpty { return [.textDelta(text)] }
            case "thinking_delta":
                if let thinking = delta.thinking { return reasoning(thinking) }
            default:
                break // signature_delta, input_json_delta, citations, …
            }
            return []

        case "message_delta":
            if let reason = payload.delta?.stopReason { stopReason = reason }
            if let details = payload.delta?.stopDetails { stopDetails = details }
            merge(payload.usage)
            return []

        case "error":
            throw Self.streamError(type: payload.error?.type, message: payload.error?.message)

        default:
            return []
        }
    }

    mutating func finish() throws -> [AIStreamEvent] {
        guard isFinished else { throw AIError.malformedStream("The response ended early.") }
        return []
    }

    private mutating func reasoning(_ text: String) -> [AIStreamEvent] {
        guard includeReasoning, !text.isEmpty else { return [] }
        var events: [AIStreamEvent] = []
        if needsReasoningSeparator {
            needsReasoningSeparator = false
            events.append(.reasoningDelta("\n\n"))
        }
        reasoningEmitted = true
        events.append(.reasoningDelta(text))
        return events
    }

    private mutating func fallbackNotice(from: String?, to: String?) -> String {
        if let to, !to.isEmpty {
            servedModel = to
            return "Continued on \(to) after a safety fallback"
        }
        if let from, !from.isEmpty {
            return "Continued after a safety fallback from \(from)"
        }
        return "Continued on another model after a safety fallback"
    }

    /// Later usage values (message_delta is cumulative) override earlier ones.
    private mutating func merge(_ update: Payload.Usage?) {
        guard let update else { return }
        sawUsage = true
        if let value = update.inputTokens { usage.inputTokens = value }
        if let value = update.outputTokens { usage.outputTokens = value }
        if let value = update.cacheReadInputTokens { usage.cacheReadTokens = value }
        if let value = update.cacheCreationInputTokens { usage.cacheWriteTokens = value }
    }

    private func makeCompletion() -> AICompletion {
        AICompletion(stopReason: mappedStopReason, usage: sawUsage ? usage : nil, servedModel: servedModel)
    }

    private var mappedStopReason: AIStopReason {
        switch stopReason {
        case nil, "end_turn", "stop_sequence": return .endTurn
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal(category: stopDetails?.category, explanation: stopDetails?.explanation)
        case let other?: return .other(other)
        }
    }

    /// Maps an Anthropic `error` event / error type to an ``AIError``.
    static func streamError(type: String?, message: String?) -> AIError {
        let message = (message?.isBlank ?? true) ? "The provider reported an error." : message ?? ""
        switch type {
        case "overloaded_error": return .overloaded(message)
        case "rate_limit_error": return .rateLimited(retryAfter: nil, message: message)
        case "authentication_error", "permission_error": return .authentication(message)
        case "invalid_request_error": return .http(status: 400, message: message)
        case "billing_error": return .http(status: 402, message: message)
        case "not_found_error": return .http(status: 404, message: message)
        case "request_too_large": return .http(status: 413, message: message)
        case "timeout_error": return .timeout
        default: return .http(status: 500, message: message) // api_error and unknown types
        }
    }

    /// The subset of SSE payload fields this client reads.
    private struct Payload: Decodable {
        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheReadInputTokens: Int?
            var cacheCreationInputTokens: Int?
        }

        struct Message: Decodable {
            var model: String?
            var usage: Usage?
        }

        struct ModelRef: Decodable {
            var model: String?
        }

        struct ContentBlock: Decodable {
            var type: String
            var text: String?
            var thinking: String?
            var from: ModelRef?
            var to: ModelRef?
        }

        struct StopDetails: Decodable {
            var category: String?
            var explanation: String?
        }

        struct Delta: Decodable {
            var type: String?
            var text: String?
            var thinking: String?
            var stopReason: String?
            var stopDetails: StopDetails?
        }

        struct ErrorBody: Decodable {
            var type: String?
            var message: String?
        }

        var message: Message?
        var contentBlock: ContentBlock?
        var delta: Delta?
        var usage: Usage?
        var error: ErrorBody?
    }
}

private struct AnthropicModelPage: Decodable {
    struct Model: Decodable {
        var id: String
        var displayName: String?
        var createdAt: String?
    }

    var data: [Model]
    var hasMore: Bool?
    var lastId: String?
}
