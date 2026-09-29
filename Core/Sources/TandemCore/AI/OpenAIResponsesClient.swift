import Foundation

/// Streaming client for the OpenAI Responses API (`POST /responses`, SSE).
///
/// Requests are stateless (`store: false`); the whole conversation is sent each time. Reasoning
/// effort and summaries are shaped by ``ModelCatalog/openAICapabilities(for:)``, and if the API
/// rejects them with HTTP 400 the request is retried without them (at most twice, before any
/// stream bytes arrive).
public struct OpenAIResponsesClient: AIClient {
    /// Maximum number of feature-degrading retries per request.
    static let maxDegradeRetries = 2

    /// Model-list ids containing any of these aren't chat models and are hidden from `listModels()`.
    static let excludedModelIDFragments = [
        "embedding", "tts", "whisper", "transcri", "image", "dall-e", "realtime", "audio",
        "moderation", "davinci", "babbage", "live", "search", "computer-use", "codex"
    ]

    public let endpoint: AIEndpoint
    private let session: URLSession

    /// - Parameters:
    ///   - endpoint: Base URL (e.g. `https://api.openai.com/v1/`) and API key.
    ///   - session: Session used for all requests; defaults to ``AIClientFactory/defaultSession``.
    public init(endpoint: AIEndpoint, session: URLSession = AIClientFactory.defaultSession) {
        self.endpoint = endpoint
        self.session = session
    }

    // MARK: Streaming

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AIEventStream.make { continuation in
            try await run(request, continuation: continuation)
        }
    }

    private func run(_ request: AIRequest, continuation: AIEventStream.Continuation) async throws {
        let apiKey = try endpoint.validatedAPIKey()
        let model = try request.validatedModel()
        let capabilities = ModelCatalog.openAICapabilities(for: model)
        var options = OpenAIWireOptions.initial(for: request, capabilities: capabilities)
        var retries = 0

        while true {
            let body = try Self.makeBody(for: request, capabilities: capabilities, options: options)
            let urlRequest = URLRequest.aiJSONPost(
                url: try endpoint.url("responses"), body: body, session: session, headers: authHeaders(apiKey: apiKey)
            )
            let response: HTTPStreamingResponse
            do {
                response = try await HTTPStreaming.open(urlRequest, session: session)
            } catch let failure as AIHTTPFailure {
                if retries < Self.maxDegradeRetries,
                   let degraded = Self.degrade(options, status: failure.status, message: failure.message) {
                    retries += 1
                    aiLogger.notice("OpenAI rejected reasoning options for \(model, privacy: .public); retrying (effort: \(degraded.effort, privacy: .public), summary: \(degraded.summary, privacy: .public))")
                    options = degraded
                    continue
                }
                throw failure.aiError
            }
            var parser = OpenAIResponsesStreamParser(includeReasoning: request.includeReasoningSummary)
            try await HTTPStreaming.pump(response, parser: &parser, into: continuation)
            return
        }
    }

    private func authHeaders(apiKey: String) -> [String: String] {
        apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
    }

    // MARK: Request building

    /// The JSON body for `request`.
    static func makeBody(for request: AIRequest, capabilities: ModelCapabilities, options: OpenAIWireOptions) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model.trimmingCharacters(in: .whitespacesAndNewlines)),
            "input": .array(try makeInput(from: request.turns)),
            "stream": true,
            "store": false,
            "max_output_tokens": .int(request.maxOutputTokens)
        ]
        if !request.systemPrompt.isBlank {
            body["instructions"] = .string(request.systemPrompt)
        }
        var reasoning: [String: JSONValue] = [:]
        if options.effort, let effort = capabilities.resolvedEffort(request.effort) {
            reasoning["effort"] = .string(effort.rawValue)
        }
        if options.summary {
            reasoning["summary"] = "auto"
        }
        if !reasoning.isEmpty {
            body["reasoning"] = .object(reasoning)
        }
        return .object(body)
    }

    /// Converts turns to Responses `input` items. Blank text and empty turns are skipped.
    static func makeInput(from turns: [AITurn]) throws -> [JSONValue] {
        var items: [JSONValue] = []
        for turn in turns {
            switch turn.role {
            case .user:
                var content: [JSONValue] = []
                for part in turn.parts {
                    switch part {
                    case .text(let text):
                        guard !text.isBlank else { continue }
                        content.append(["type": "input_text", "text": .string(text)])
                    case .image(let image):
                        guard !image.data.isEmpty else { continue }
                        content.append([
                            "type": "input_image",
                            "image_url": .base64(image.data, prefix: "data:\(image.mimeType);base64,"),
                            "detail": "high"
                        ])
                    }
                }
                guard !content.isEmpty else { continue }
                items.append(["role": "user", "content": .array(content)])
            case .assistant:
                let text = turn.parts.compactMap { part -> String? in
                    if case .text(let text) = part, !text.isBlank { return text }
                    return nil
                }.joined(separator: "\n\n")
                guard !text.isEmpty else { continue }
                items.append(["role": "assistant", "content": .string(text)])
            }
        }
        guard !items.isEmpty else {
            throw AIError.invalidConfiguration("There's nothing to send yet — add a question or a screenshot.")
        }
        return items
    }

    /// Decides whether an HTTP 400 can be retried with reasoning options removed: a message
    /// mentioning `summary` drops the summary; one mentioning `reasoning`/`effort` drops the whole
    /// `reasoning` object. Returns `nil` when the error isn't recoverable this way.
    static func degrade(_ options: OpenAIWireOptions, status: Int, message: String) -> OpenAIWireOptions? {
        guard status == 400 else { return nil }
        let text = message.lowercased()
        var next = options
        if options.summary, text.contains("summary") {
            next.summary = false
        } else if options.effort || options.summary, text.contains("reasoning") || text.contains("effort") {
            next.effort = false
            next.summary = false
        } else {
            return nil
        }
        return next
    }

    // MARK: Models

    public func listModels() async throws -> [AIModelInfo] {
        do {
            let apiKey = try endpoint.validatedAPIKey()
            let urlRequest = URLRequest.aiGet(url: try endpoint.url("models"), session: session, headers: authHeaders(apiKey: apiKey))
            let data = try await HTTPStreaming.data(for: urlRequest, session: session)
            guard let list = try? JSONDecoder.aiProviderDecoder().decode(OpenAIModelList.self, from: data) else {
                throw AIError.malformedStream("The model list couldn't be read.")
            }
            return list.data
                .filter { Self.isChatModel($0.id) }
                .map { AIModelInfo(id: $0.id, displayName: $0.id, createdAt: $0.created.map { Date(timeIntervalSince1970: $0) }) }
                .sortedNewestFirst()
        } catch {
            throw AIError.wrapping(error)
        }
    }

    /// Whether a model-list id looks like a text/chat model.
    static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return !excludedModelIDFragments.contains { lowered.contains($0) }
    }
}

/// Which optional reasoning fields are currently being sent.
struct OpenAIWireOptions: Hashable, Sendable {
    var effort: Bool
    var summary: Bool

    static func initial(for request: AIRequest, capabilities: ModelCapabilities) -> OpenAIWireOptions {
        OpenAIWireOptions(
            effort: capabilities.resolvedEffort(request.effort) != nil,
            summary: request.includeReasoningSummary && capabilities.supportsThinkingDisplay
        )
    }
}

// MARK: - Stream parsing

/// Turns Responses API SSE events into ``AIStreamEvent``s.
struct OpenAIResponsesStreamParser: AIStreamParser {
    let includeReasoning: Bool
    private(set) var isFinished = false

    private let decoder = JSONDecoder.aiProviderDecoder()
    private var servedModel: String?
    private var sawRefusal = false
    private var reasoningEmitted = false
    private var needsReasoningSeparator = false

    init(includeReasoning: Bool) {
        self.includeReasoning = includeReasoning
    }

    private static let handledTypes: Set<String> = [
        "response.created", "response.output_text.delta", "response.reasoning_summary_part.added",
        "response.reasoning_summary_text.delta", "response.refusal.delta", "response.completed",
        "response.incomplete", "response.failed", "error"
    ]

    mutating func consume(_ event: SSEEvent) throws -> [AIStreamEvent] {
        guard !isFinished, let type = event.resolvedType(using: decoder), Self.handledTypes.contains(type) else { return [] }
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: Data(event.data.utf8))
        } catch {
            if type == "error" || type == "response.failed" {
                throw AIError.http(status: 500, message: "The provider reported an error mid-stream.")
            }
            aiLogger.debug("Ignoring undecodable \(type, privacy: .public) event")
            return []
        }

        switch type {
        case "response.created":
            servedModel = payload.response?.model ?? servedModel
            return [.started(model: servedModel)]

        case "response.output_text.delta":
            guard let delta = payload.delta, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]

        case "response.reasoning_summary_part.added":
            if (payload.summaryIndex ?? 0) > 0 || reasoningEmitted { needsReasoningSeparator = true }
            return []

        case "response.reasoning_summary_text.delta":
            guard includeReasoning, let delta = payload.delta, !delta.isEmpty else { return [] }
            var events: [AIStreamEvent] = []
            if needsReasoningSeparator, reasoningEmitted { events.append(.reasoningDelta("\n\n")) }
            needsReasoningSeparator = false
            reasoningEmitted = true
            events.append(.reasoningDelta(delta))
            return events

        case "response.refusal.delta":
            guard let delta = payload.delta, !delta.isEmpty else { return [] }
            sawRefusal = true
            return [.textDelta(delta)]

        case "response.completed":
            isFinished = true
            let stop: AIStopReason = sawRefusal ? .refusal(category: nil, explanation: nil) : .endTurn
            return [.completed(completion(stop, response: payload.response))]

        case "response.incomplete":
            isFinished = true
            let stop: AIStopReason
            switch payload.response?.incompleteDetails?.reason {
            case "max_output_tokens": stop = .maxTokens
            case "content_filter": stop = .refusal(category: "content_filter", explanation: nil)
            case let reason: stop = .other(reason ?? "incomplete")
            }
            return [.completed(completion(stop, response: payload.response))]

        case "response.failed":
            let error = payload.response?.error
            throw Self.streamError(code: error?.code?.value, type: error?.type, message: error?.message ?? "The response failed.")

        case "error":
            throw Self.streamError(
                code: payload.code?.value ?? payload.error?.code?.value,
                type: payload.error?.type,
                message: payload.message ?? payload.error?.message ?? "The provider reported an error."
            )

        default:
            return []
        }
    }

    mutating func finish() throws -> [AIStreamEvent] {
        guard isFinished else { throw AIError.malformedStream("The response ended early.") }
        return []
    }

    private func completion(_ stop: AIStopReason, response: Payload.Response?) -> AICompletion {
        var usage: AIUsage?
        if let raw = response?.usage {
            usage = AIUsage(
                inputTokens: raw.inputTokens ?? 0,
                outputTokens: raw.outputTokens ?? 0,
                cacheReadTokens: raw.inputTokensDetails?.cachedTokens ?? 0
            )
        }
        return AICompletion(stopReason: stop, usage: usage, servedModel: response?.model ?? servedModel)
    }

    /// Maps an OpenAI(-compatible) stream error code/type to an ``AIError``.
    static func streamError(code: String?, type: String?, message: String) -> AIError {
        switch code ?? type {
        case "rate_limit_exceeded", "rate_limit_error", "tokens", "requests":
            return .rateLimited(retryAfter: nil, message: message)
        case "insufficient_quota":
            return .http(status: 429, message: message)
        case "invalid_api_key", "authentication_error", "permission_error":
            return .authentication(message)
        case "server_is_overloaded", "overloaded", "overloaded_error", "service_unavailable", "slow_down":
            return .overloaded(message)
        case "vector_store_timeout", "timeout":
            return .timeout
        case nil, "server_error", "api_error", "internal_error":
            return .http(status: 500, message: message)
        default:
            return .http(status: 400, message: message) // invalid_prompt, invalid_image, …
        }
    }

    /// The subset of SSE payload fields this client reads.
    private struct Payload: Decodable {
        struct Usage: Decodable {
            struct InputDetails: Decodable {
                var cachedTokens: Int?
            }

            var inputTokens: Int?
            var outputTokens: Int?
            var inputTokensDetails: InputDetails?
        }

        struct IncompleteDetails: Decodable {
            var reason: String?
        }

        struct ErrorBody: Decodable {
            var code: LenientText?
            var type: String?
            var message: String?
        }

        struct Response: Decodable {
            var model: String?
            var usage: Usage?
            var incompleteDetails: IncompleteDetails?
            var error: ErrorBody?
        }

        var delta: String?
        var summaryIndex: Int?
        var response: Response?
        var code: LenientText?
        var message: String?
        var error: ErrorBody?
    }
}

private struct OpenAIModelList: Decodable {
    struct Model: Decodable {
        var id: String
        var created: Double?
    }

    var data: [Model]
}
