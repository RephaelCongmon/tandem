import Foundation

/// Streaming client for OpenAI-compatible Chat Completions servers (LM Studio, Ollama, vLLM,
/// llama.cpp, proxies): `POST /chat/completions` with `stream: true`.
///
/// Optional fields (`stream_options`, `reasoning_effort`) are dropped and the request retried if
/// the server answers HTTP 400. Servers that ignore `stream` and return one JSON body are
/// handled too.
public struct ChatCompletionsClient: AIClient {
    /// Maximum number of feature-degrading retries per request.
    static let maxDegradeRetries = 2
    /// Largest non-streamed JSON body accepted from servers that ignore `stream: true`.
    static let maxJSONBodyBytes = 16 * 1024 * 1024

    public let endpoint: AIEndpoint
    private let session: URLSession

    /// - Parameters:
    ///   - endpoint: Base URL (e.g. `http://localhost:1234/v1/`) and optional API key.
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
        var options = ChatWireOptions(streamOptions: true, reasoningEffort: request.effort != nil)
        var retries = 0

        while true {
            let body = try Self.makeBody(for: request, options: options)
            let urlRequest = URLRequest.aiJSONPost(
                url: try endpoint.url("chat/completions"), body: body, session: session, headers: authHeaders(apiKey: apiKey)
            )
            let response: HTTPStreamingResponse
            do {
                response = try await HTTPStreaming.open(urlRequest, session: session)
            } catch let failure as AIHTTPFailure {
                if retries < Self.maxDegradeRetries,
                   let degraded = Self.degrade(options, status: failure.status, message: failure.message) {
                    retries += 1
                    aiLogger.notice("Server rejected optional fields for \(model, privacy: .public); retrying (stream_options: \(degraded.streamOptions, privacy: .public), reasoning_effort: \(degraded.reasoningEffort, privacy: .public))")
                    options = degraded
                    continue
                }
                throw failure.aiError
            }

            var parser = ChatCompletionsStreamParser(includeReasoning: request.includeReasoningSummary)
            if response.contentType.contains("application/json") {
                // The server ignored `stream: true` and sent the whole completion at once.
                defer { response.cancel() }
                let data = try await HTTPStreaming.readBody(of: response.body, limit: Self.maxJSONBodyBytes)
                for event in try parser.consumeCompleteResponse(data) { continuation.yield(event) }
                return
            }
            try await HTTPStreaming.pump(response, parser: &parser, into: continuation)
            return
        }
    }

    private func authHeaders(apiKey: String) -> [String: String] {
        apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
    }

    // MARK: Request building

    /// The JSON body for `request`.
    static func makeBody(for request: AIRequest, options: ChatWireOptions) throws -> JSONValue {
        var messages: [JSONValue] = []
        if !request.systemPrompt.isBlank {
            messages.append(["role": "system", "content": .string(request.systemPrompt)])
        }
        messages.append(contentsOf: try makeMessages(from: request.turns))
        var body: [String: JSONValue] = [
            "model": .string(request.model.trimmingCharacters(in: .whitespacesAndNewlines)),
            "messages": .array(messages),
            "stream": true,
            "max_tokens": .int(request.maxOutputTokens)
        ]
        if options.streamOptions {
            body["stream_options"] = ["include_usage": true]
        }
        if options.reasoningEffort, let effort = request.effort {
            body["reasoning_effort"] = .string(effort.rawValue)
        }
        return .object(body)
    }

    /// Converts turns to chat `messages`. User turns with images use content-part arrays;
    /// text-only turns use a plain string, which every compatible server accepts.
    static func makeMessages(from turns: [AITurn]) throws -> [JSONValue] {
        var messages: [JSONValue] = []
        for turn in turns {
            switch turn.role {
            case .user:
                var content: [JSONValue] = []
                var texts: [String] = []
                var hasImage = false
                for part in turn.parts {
                    switch part {
                    case .text(let text):
                        guard !text.isBlank else { continue }
                        texts.append(text)
                        content.append(["type": "text", "text": .string(text)])
                    case .image(let image):
                        guard !image.data.isEmpty else { continue }
                        hasImage = true
                        content.append([
                            "type": "image_url",
                            "image_url": ["url": .base64(image.data, prefix: "data:\(image.mimeType);base64,")]
                        ])
                    }
                }
                guard !content.isEmpty else { continue }
                let value: JSONValue = hasImage ? .array(content) : .string(texts.joined(separator: "\n\n"))
                messages.append(["role": "user", "content": value])
            case .assistant:
                let text = turn.parts.compactMap { part -> String? in
                    if case .text(let text) = part, !text.isBlank { return text }
                    return nil
                }.joined(separator: "\n\n")
                guard !text.isEmpty else { continue }
                messages.append(["role": "assistant", "content": .string(text)])
            }
        }
        guard !messages.isEmpty else {
            throw AIError.invalidConfiguration("There's nothing to send yet — add a question or a screenshot.")
        }
        return messages
    }

    /// Decides whether an HTTP 400 can be retried with optional fields removed: a message naming
    /// `stream_options` or `reasoning_effort` drops that field; any other 400 drops both (once).
    static func degrade(_ options: ChatWireOptions, status: Int, message: String) -> ChatWireOptions? {
        guard status == 400 else { return nil }
        let text = message.lowercased()
        var next = options
        if options.streamOptions, text.contains("stream_options") {
            next.streamOptions = false
        } else if options.reasoningEffort, text.contains("reasoning_effort") || text.contains("reasoning") {
            next.reasoningEffort = false
        } else if options.streamOptions || options.reasoningEffort {
            next.streamOptions = false
            next.reasoningEffort = false
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
            guard let list = try? JSONDecoder.aiProviderDecoder().decode(ChatModelList.self, from: data) else {
                throw AIError.malformedStream("The model list couldn't be read.")
            }
            return list.data
                .map { AIModelInfo(id: $0.id, displayName: $0.id, createdAt: $0.created.map { Date(timeIntervalSince1970: $0) }) }
                .sortedNewestFirst()
        } catch {
            throw AIError.wrapping(error)
        }
    }
}

/// Which optional fields are currently being sent.
struct ChatWireOptions: Hashable, Sendable {
    var streamOptions: Bool
    var reasoningEffort: Bool
}

// MARK: - Stream parsing

/// Turns Chat Completions stream chunks (`data: {json}` … `data: [DONE]`) into ``AIStreamEvent``s.
struct ChatCompletionsStreamParser: AIStreamParser {
    let includeReasoning: Bool
    private(set) var isFinished = false

    private let decoder = JSONDecoder.aiProviderDecoder()
    private var started = false
    private var sawChunk = false
    private var servedModel: String?
    private var finishReason: String?
    private var sawRefusal = false
    private var usage: AIUsage?

    init(includeReasoning: Bool) {
        self.includeReasoning = includeReasoning
    }

    mutating func consume(_ event: SSEEvent) throws -> [AIStreamEvent] {
        guard !isFinished else { return [] }
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            isFinished = true
            return startIfNeeded(model: nil) + [.completed(makeCompletion())]
        }
        guard !payload.isEmpty else { return [] }
        guard let chunk = try? decoder.decode(Chunk.self, from: Data(payload.utf8)) else {
            aiLogger.debug("Ignoring an undecodable chat completion chunk")
            return []
        }
        return try consume(chunk)
    }

    mutating func finish() throws -> [AIStreamEvent] {
        guard !isFinished else { return [] }
        guard sawChunk else { throw AIError.malformedStream("The response ended early.") }
        isFinished = true
        return [.completed(makeCompletion())]
    }

    /// Parses a non-streamed `chat.completion` JSON body into the full event sequence.
    mutating func consumeCompleteResponse(_ data: Data) throws -> [AIStreamEvent] {
        guard let chunk = try? decoder.decode(Chunk.self, from: data) else {
            throw AIError.malformedStream("The response couldn't be decoded.")
        }
        var events = try consume(chunk)
        isFinished = true
        events.append(.completed(makeCompletion()))
        return events
    }

    private mutating func consume(_ chunk: Chunk) throws -> [AIStreamEvent] {
        if let error = chunk.error {
            let message = error.message?.value ?? "The server reported an error."
            throw OpenAIResponsesStreamParser.streamError(code: error.code?.value, type: error.type?.value, message: message)
        }
        sawChunk = true
        var events = startIfNeeded(model: chunk.model)
        if servedModel == nil { servedModel = chunk.model }

        if let choice = chunk.choices?.first {
            // `delta` when streaming, `message` in a complete response.
            let delta = choice.delta ?? choice.message
            if includeReasoning,
               let reasoning = [delta?.reasoningContent?.value, delta?.reasoning?.value].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                events.append(.reasoningDelta(reasoning))
            }
            if let text = delta?.content?.value, !text.isEmpty {
                events.append(.textDelta(text))
            }
            if let refusal = delta?.refusal?.value, !refusal.isEmpty {
                sawRefusal = true
                events.append(.textDelta(refusal))
            }
            if let reason = choice.finishReason?.value { finishReason = reason }
        }
        if let raw = chunk.usage {
            usage = AIUsage(
                inputTokens: raw.promptTokens ?? 0,
                outputTokens: raw.completionTokens ?? 0,
                cacheReadTokens: raw.promptTokensDetails?.cachedTokens ?? 0
            )
        }
        return events
    }

    private mutating func startIfNeeded(model: String?) -> [AIStreamEvent] {
        guard !started else { return [] }
        started = true
        return [.started(model: model)]
    }

    private func makeCompletion() -> AICompletion {
        let stop: AIStopReason
        switch finishReason {
        case nil, "stop", "end_turn", "eos": stop = sawRefusal ? .refusal(category: nil, explanation: nil) : .endTurn
        case "length", "max_tokens": stop = .maxTokens
        case "content_filter": stop = .refusal(category: "content_filter", explanation: nil)
        case let other?: stop = .other(other)
        }
        return AICompletion(stopReason: stop, usage: usage, servedModel: servedModel)
    }

    /// Lenient view of a chunk (or complete response); unexpected shapes decode as `nil`.
    private struct Chunk: Decodable {
        struct Delta: Decodable {
            var content: LenientText?
            var reasoningContent: LenientText?
            var reasoning: LenientText?
            var refusal: LenientText?
        }

        struct Choice: Decodable {
            var delta: Delta?
            var message: Delta?
            var finishReason: LenientText?
        }

        struct Usage: Decodable {
            struct Details: Decodable {
                var cachedTokens: Int?
            }

            var promptTokens: Int?
            var completionTokens: Int?
            var promptTokensDetails: Details?
        }

        struct ErrorBody: Decodable {
            var message: LenientText?
            var type: LenientText?
            var code: LenientText?

            init(from decoder: Decoder) throws {
                // `error` may be an object or a bare string.
                if let text = try? decoder.singleValueContainer().decode(String.self) {
                    message = LenientText(text)
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                message = try? container.decodeIfPresent(LenientText.self, forKey: .message)
                type = try? container.decodeIfPresent(LenientText.self, forKey: .type)
                code = try? container.decodeIfPresent(LenientText.self, forKey: .code)
            }

            private enum CodingKeys: String, CodingKey {
                case message, type, code
            }
        }

        var model: String?
        var choices: [Choice]?
        var usage: Usage?
        var error: ErrorBody?
    }
}

private struct ChatModelList: Decodable {
    struct Model: Decodable {
        var id: String
        var created: Double?
    }

    var data: [Model]
}
