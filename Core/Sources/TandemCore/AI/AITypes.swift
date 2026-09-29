import Foundation

/// Which API family a provider speaks.
public enum AIProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Anthropic Messages API (Claude).
    case anthropic
    /// OpenAI Responses API.
    case openAI
    /// Any OpenAI-compatible Chat Completions server (LM Studio, Ollama, vLLM, proxies).
    case openAICompatible
    /// The Claude Code CLI on this Mac, answering on the user's Claude subscription.
    /// `AIEndpoint.baseURL` is the path of the `claude` executable.
    case claudeCode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "Custom (OpenAI-compatible)"
        case .claudeCode: return "Claude Code"
        }
    }

    public var defaultBaseURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/")!
        case .openAI: return URL(string: "https://api.openai.com/v1/")!
        case .openAICompatible: return URL(string: "http://localhost:1234/v1/")!
        case .claudeCode: return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/claude")
        }
    }

    /// Whether an API key is mandatory for this provider.
    public var requiresAPIKey: Bool { self == .anthropic || self == .openAI }

    /// The order providers are offered in: the no-key subscription option first.
    public static let menuOrder: [AIProviderKind] = [.claudeCode, .anthropic, .openAI, .openAICompatible]

    /// Label for pickers, saying how each option is paid for.
    public var menuTitle: String {
        switch self {
        case .claudeCode: return "Claude Code — your Claude subscription"
        case .anthropic: return "Claude API — API key"
        case .openAI: return "OpenAI — API key"
        case .openAICompatible: return "Custom server (OpenAI-compatible)"
        }
    }
}

/// Reasoning depth. Maps to `output_config.effort` (Anthropic) and
/// `reasoning.effort` (OpenAI).
public enum ReasoningEffort: String, Codable, CaseIterable, Sendable, Identifiable {
    case low, medium, high, xhigh, max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Fast"
        case .medium: return "Balanced"
        case .high: return "Thorough"
        case .xhigh: return "Deep"
        case .max: return "Maximum"
        }
    }
}

/// An image attached to a turn. `data` is already encoded (JPEG/PNG).
public struct AIImage: Sendable, Hashable {
    public var data: Data
    public var mimeType: String
    public var width: Int
    public var height: Int

    public init(data: Data, mimeType: String, width: Int, height: Int) {
        self.data = data
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }
}

public enum AIPart: Sendable, Hashable {
    case text(String)
    case image(AIImage)
}

public enum AIRole: String, Sendable, Hashable, Codable {
    case user
    case assistant
}

public struct AITurn: Sendable, Hashable {
    public var role: AIRole
    public var parts: [AIPart]

    public init(role: AIRole, parts: [AIPart]) {
        self.role = role
        self.parts = parts
    }

    public static func user(_ parts: AIPart...) -> AITurn { AITurn(role: .user, parts: parts) }
    public static func assistant(_ text: String) -> AITurn { AITurn(role: .assistant, parts: [.text(text)]) }
}

/// Where and how to reach a provider.
public struct AIEndpoint: Sendable, Hashable {
    public var kind: AIProviderKind
    public var baseURL: URL
    public var apiKey: String

    public init(kind: AIProviderKind, baseURL: URL? = nil, apiKey: String) {
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.apiKey = apiKey
    }
}

/// One request for a streamed completion.
public struct AIRequest: Sendable, Hashable {
    public var model: String
    public var systemPrompt: String
    public var turns: [AITurn]
    public var maxOutputTokens: Int
    /// `nil` means "don't send an effort parameter".
    public var effort: ReasoningEffort?
    /// Ask the provider for a readable reasoning summary, streamed as `.reasoningDelta`.
    public var includeReasoningSummary: Bool

    public init(
        model: String,
        systemPrompt: String = "",
        turns: [AITurn],
        maxOutputTokens: Int = 32_000,
        effort: ReasoningEffort? = .low,
        includeReasoningSummary: Bool = true
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.turns = turns
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
        self.includeReasoningSummary = includeReasoningSummary
    }
}

public struct AIUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public enum AIStopReason: Sendable, Hashable, Codable {
    case endTurn
    case maxTokens
    /// The model or a safety classifier declined. `category`/`explanation` are informational.
    case refusal(category: String?, explanation: String?)
    case other(String)
}

public struct AICompletion: Sendable, Hashable {
    public var stopReason: AIStopReason
    public var usage: AIUsage?
    /// The model that actually produced the answer (may differ after a server-side fallback).
    public var servedModel: String?

    public init(stopReason: AIStopReason, usage: AIUsage? = nil, servedModel: String? = nil) {
        self.stopReason = stopReason
        self.usage = usage
        self.servedModel = servedModel
    }
}

public enum AIStreamEvent: Sendable, Hashable {
    /// The provider accepted the request; `model` is the serving model if known.
    case started(model: String?)
    case reasoningDelta(String)
    case textDelta(String)
    /// Informational note to surface in the UI (e.g. a safety fallback switched models).
    case notice(String)
    case completed(AICompletion)
}

public enum AIError: Error, LocalizedError, Sendable, Hashable {
    case missingAPIKey
    case invalidConfiguration(String)
    case authentication(String)
    case rateLimited(retryAfter: TimeInterval?, message: String)
    case overloaded(String)
    case http(status: Int, message: String)
    case network(String)
    case timeout
    case malformedStream(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an API key in Settings → AI to start asking."
        case .invalidConfiguration(let message):
            return message
        case .authentication(let message):
            return "The API key was rejected. \(message)"
        case .rateLimited(let retryAfter, let message):
            if let retryAfter { return "Rate limited — try again in \(Int(retryAfter.rounded(.up)))s. \(message)" }
            return "Rate limited. \(message)"
        case .overloaded(let message):
            return "The provider is overloaded right now. \(message)"
        case .http(let status, let message):
            return "Request failed (\(status)). \(message)"
        case .network(let message):
            return "Network error: \(message)"
        case .timeout:
            return "The request timed out."
        case .malformedStream(let message):
            return "Unexpected response from the provider: \(message)"
        case .cancelled:
            return "Stopped."
        }
    }

    /// Whether retrying the same request later could succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .network, .timeout: return true
        case .http(let status, _): return status >= 500
        default: return false
        }
    }
}

public struct AIModelInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var displayName: String
    public var createdAt: Date?

    public init(id: String, displayName: String, createdAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// A streaming chat client for one provider endpoint.
public protocol AIClient: Sendable {
    /// Streams events for `request`. Cancelling the consuming task cancels the HTTP request.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// Lists models available to the configured key.
    func listModels() async throws -> [AIModelInfo]
}
