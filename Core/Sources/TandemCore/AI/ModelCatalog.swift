import Foundation

/// What a model accepts. Used to shape requests (thinking/effort/fallbacks) and to size screenshots.
public struct ModelCapabilities: Sendable, Hashable {
    /// Always send an explicit `thinking` parameter (Anthropic adaptive thinking).
    public var sendsThinkingParam: Bool
    /// The model accepts a reasoning-visibility setting: Anthropic `thinking.display`, OpenAI
    /// `reasoning.summary`. When `sendsThinkingParam` is false but this is true (thinking is always
    /// on), `thinking` is only sent to ask for a summary.
    public var supportsThinkingDisplay: Bool
    /// Effort levels the model accepts, lowest first. Empty means "never send an effort".
    public var supportedEfforts: [ReasoningEffort]
    /// Anthropic server-side safety fallbacks (`"fallbacks": "default"`) are available.
    public var supportsFallbacks: Bool
    /// Longest image edge, in pixels, the model uses without downscaling. Resize screenshots to fit.
    public var maxImageLongEdge: Int

    public init(
        sendsThinkingParam: Bool,
        supportsThinkingDisplay: Bool,
        supportedEfforts: [ReasoningEffort],
        supportsFallbacks: Bool,
        maxImageLongEdge: Int
    ) {
        self.sendsThinkingParam = sendsThinkingParam
        self.supportsThinkingDisplay = supportsThinkingDisplay
        self.supportedEfforts = supportedEfforts
        self.supportsFallbacks = supportsFallbacks
        self.maxImageLongEdge = maxImageLongEdge
    }

    /// The effort to send for `requested`: itself when supported, otherwise the nearest lower
    /// supported level (e.g. `xhigh` → `high`), otherwise the lowest supported level.
    /// `nil` when nothing was requested or the model takes no effort parameter.
    public func resolvedEffort(_ requested: ReasoningEffort?) -> ReasoningEffort? {
        guard let requested, !supportedEfforts.isEmpty else { return nil }
        if supportedEfforts.contains(requested) { return requested }
        let order = ReasoningEffort.allCases
        if let index = order.firstIndex(of: requested) {
            for candidate in order[..<index].reversed() where supportedEfforts.contains(candidate) {
                return candidate
            }
        }
        return supportedEfforts.first
    }
}

/// A model offered in pickers before (or instead of) a live model list.
public struct AIModelPreset: Sendable, Hashable, Identifiable {
    /// The API model id.
    public var id: String
    public var displayName: String
    /// One-line description for pickers.
    public var summary: String
    public var provider: AIProviderKind

    public init(id: String, displayName: String, summary: String, provider: AIProviderKind) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.provider = provider
    }
}

/// Model presets and per-model capability rules.
public enum ModelCatalog {
    // MARK: Presets

    /// Claude presets; the first is the default.
    public static let anthropicPresets: [AIModelPreset] = [
        AIModelPreset(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", summary: "Best all-rounder for screen help", provider: .anthropic),
        AIModelPreset(id: "claude-fable-5-1", displayName: "Claude Fable 5.1", summary: "Most capable; slower and pricier", provider: .anthropic),
        AIModelPreset(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", summary: "Fast and capable", provider: .anthropic),
        AIModelPreset(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", summary: "Fastest and lightest; no reasoning", provider: .anthropic)
    ]

    /// OpenAI presets; the first (flagship) is the default.
    public static let openAIPresets: [AIModelPreset] = [
        AIModelPreset(id: "gpt-6-astra", displayName: "GPT-6 Astra", summary: "OpenAI's flagship", provider: .openAI),
        AIModelPreset(id: "gpt-6-sol", displayName: "GPT-6 Sol", summary: "Balanced speed and depth", provider: .openAI),
        AIModelPreset(id: "gpt-6-luna", displayName: "GPT-6 Luna", summary: "Fastest and cheapest", provider: .openAI)
    ]

    /// Presets for `kind`. OpenAI-compatible servers have none (their models are user-defined).
    public static func presets(for kind: AIProviderKind) -> [AIModelPreset] {
        switch kind {
        case .anthropic: return anthropicPresets
        case .openAI: return openAIPresets
        case .openAICompatible: return []
        }
    }

    /// The default model id for `kind`, or `nil` when the user must pick one.
    public static func defaultModelID(for kind: AIProviderKind) -> String? {
        presets(for: kind).first?.id
    }

    // MARK: Capabilities

    /// Capabilities of `model` on a provider of kind `provider`.
    public static func capabilities(for model: String, provider: AIProviderKind) -> ModelCapabilities {
        switch provider {
        case .anthropic: return anthropicCapabilities(for: model)
        case .openAI: return openAICapabilities(for: model)
        case .openAICompatible: return openAICompatibleCapabilities
        }
    }

    private static let allEfforts = ReasoningEffort.allCases

    /// Fable / Mythos: thinking is always on; `thinking` is only sent to request a summary.
    static let claudeAlwaysThinking = ModelCapabilities(
        sendsThinkingParam: false, supportsThinkingDisplay: true, supportedEfforts: allEfforts,
        supportsFallbacks: false, maxImageLongEdge: 2576
    )
    /// Opus 5.x, Sonnet 5.5+: adaptive thinking with display, every effort, server-side fallbacks.
    static let claudeFrontier = ModelCapabilities(
        sendsThinkingParam: true, supportsThinkingDisplay: true, supportedEfforts: allEfforts,
        supportsFallbacks: true, maxImageLongEdge: 2576
    )
    /// Opus 4.7/4.8, Sonnet 5, and unrecognized Claude ids.
    static let claudeAdaptive = ModelCapabilities(
        sendsThinkingParam: true, supportsThinkingDisplay: true, supportedEfforts: allEfforts,
        supportsFallbacks: false, maxImageLongEdge: 2576
    )
    /// Opus 4.6 / Sonnet 4.6: adaptive thinking (no `display` field; reasoning is summarized by
    /// default), no `xhigh`, standard-resolution vision.
    static let claude46 = ModelCapabilities(
        sendsThinkingParam: true, supportsThinkingDisplay: false, supportedEfforts: [.low, .medium, .high, .max],
        supportsFallbacks: false, maxImageLongEdge: 1568
    )
    /// Haiku and pre-4.6 models: no thinking or effort parameters.
    static let claudeLegacy = ModelCapabilities(
        sendsThinkingParam: false, supportsThinkingDisplay: false, supportedEfforts: [],
        supportsFallbacks: false, maxImageLongEdge: 1568
    )

    /// Capability rules for a Claude model id. Accepts platform-style ids too
    /// (`anthropic.claude-…`, `…@date`, `…[1m]`, `…:0`). Unknown ids get the Opus 4.8 profile.
    public static func anthropicCapabilities(for model: String) -> ModelCapabilities {
        guard let parsed = ClaudeModelID(model) else { return claudeAdaptive }
        switch parsed.family {
        case .legacy, .haiku:
            return claudeLegacy
        case .fable, .mythos:
            var capabilities = claudeAlwaysThinking
            capabilities.supportsFallbacks = parsed.family == .fable && parsed.version >= ClaudeModelID.Version(5, 1)
            return capabilities
        case .opus:
            if parsed.version >= ClaudeModelID.Version(5, 0) { return claudeFrontier }
            if parsed.version >= ClaudeModelID.Version(4, 7) { return claudeAdaptive }
            if parsed.version == ClaudeModelID.Version(4, 6) { return claude46 }
            return claudeLegacy
        case .sonnet:
            if parsed.version >= ClaudeModelID.Version(5, 5) { return claudeFrontier }
            if parsed.version >= ClaudeModelID.Version(5, 0) { return claudeAdaptive }
            if parsed.version == ClaudeModelID.Version(4, 6) { return claude46 }
            return claudeLegacy
        case .unknown:
            return claudeAdaptive
        }
    }

    /// Capability rules for an OpenAI model id. GPT-6 (and unknown ids) take every effort level;
    /// GPT-5 and o-series take low/medium/high; older chat models take no reasoning parameters.
    public static func openAICapabilities(for model: String) -> ModelCapabilities {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let efforts: [ReasoningEffort]
        if id.hasPrefix("gpt-5") || id.range(of: #"^o[1-9]"#, options: .regularExpression) != nil {
            efforts = [.low, .medium, .high]
        } else if id.hasPrefix("gpt-4") || id.hasPrefix("gpt-3") || id.hasPrefix("chatgpt-4") {
            efforts = []
        } else {
            efforts = allEfforts
        }
        return ModelCapabilities(
            sendsThinkingParam: false,
            supportsThinkingDisplay: !efforts.isEmpty,
            supportedEfforts: efforts,
            supportsFallbacks: false,
            maxImageLongEdge: 2048
        )
    }

    /// OpenAI-compatible servers: effort is passed through as requested (and dropped on rejection);
    /// screenshots are kept modest because local vision models are slow on large images.
    public static let openAICompatibleCapabilities = ModelCapabilities(
        sendsThinkingParam: false, supportsThinkingDisplay: false, supportedEfforts: allEfforts,
        supportsFallbacks: false, maxImageLongEdge: 1568
    )
}

/// A parsed Claude model id such as `claude-opus-5-5` or `claude-sonnet-4-5-20250929`.
struct ClaudeModelID: Hashable {
    enum Family: Hashable {
        case opus, sonnet, haiku, fable, mythos
        /// `claude-3-…`, `claude-2…`, `claude-instant-…`.
        case legacy
        case unknown
    }

    struct Version: Hashable, Comparable {
        var major: Int
        var minor: Int

        init(_ major: Int, _ minor: Int) {
            self.major = major
            self.minor = minor
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }
    }

    var family: Family
    var version: Version

    /// Returns `nil` when `model` doesn't look like a Claude id at all.
    init?(_ model: String) {
        var id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let claudeRange = id.range(of: "claude-") else {
            if id.contains("haiku") { self.init(family: .haiku, version: Version(0, 0)); return }
            return nil
        }
        id = String(id[claudeRange.upperBound...])
        if let cut = id.firstIndex(where: { $0 == "@" || $0 == "[" || $0 == ":" }) {
            id = String(id[..<cut])
        }
        let components = id.split(separator: "-").map(String.init)
        guard let first = components.first else { return nil }

        if first.first?.isNumber == true || first == "instant" || id.contains("haiku") {
            let family: Family = id.contains("haiku") ? .haiku : .legacy
            self.init(family: family, version: Version(0, 0))
            return
        }

        let family: Family
        switch first {
        case "opus": family = .opus
        case "sonnet": family = .sonnet
        case "fable": family = .fable
        case "mythos": family = .mythos
        default: family = .unknown
        }
        guard components.count > 1, let major = Int(components[1]) else {
            // e.g. `claude-opus-latest`: treat as the newest of its family.
            self.init(family: family, version: Version(Int.max, 0))
            return
        }
        var minor = 0
        if components.count > 2, components[2].count <= 2, let value = Int(components[2]) {
            minor = value // an 8-digit component is a date snapshot, not a minor version
        }
        self.init(family: family, version: Version(major, minor))
    }

    private init(family: Family, version: Version) {
        self.family = family
        self.version = version
    }
}
