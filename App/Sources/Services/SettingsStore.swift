import Foundation
import Observation
import TandemCore
import TandemUI

/// What this Mac does.
enum AppRole: String, Codable, CaseIterable, Identifiable {
    /// Shares its screen/camera with the other Mac.
    case source
    /// Shows the live view and talks to the AI.
    case studio

    var id: String { rawValue }

    var peerRole: PeerRole { self == .source ? .source : .studio }

    var title: String {
        switch self {
        case .source: return "Share this Mac"
        case .studio: return "Ask from this Mac"
        }
    }

    var shortTitle: String {
        switch self {
        case .source: return "Source"
        case .studio: return "Studio"
        }
    }

    var detail: String {
        switch self {
        case .source: return "Stream this Mac's screen or camera to your other Mac. Nothing is saved here."
        case .studio: return "See the other Mac live and ask Claude or OpenAI about what's on it."
        }
    }

    var systemImage: String {
        switch self {
        case .source: return "rectangle.on.rectangle.angled"
        case .studio: return "sparkles.rectangle.stack"
        }
    }

    var hotkeyRole: HotkeyAction.Role { self == .source ? .source : .studio }
}

enum AppearancePreference: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LiveQualityPreset: String, Codable, CaseIterable, Identifiable {
    case smooth, balanced, crisp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .balanced: return "Balanced"
        case .crisp: return "Crisp"
        }
    }

    var detail: String {
        switch self {
        case .smooth: return "1080p at 60 fps — best for motion."
        case .balanced: return "1080p at 30 fps — great on any Wi-Fi."
        case .crisp: return "Up to 2880 px at 30 fps — sharpest text."
        }
    }

    var quality: StreamQuality {
        switch self {
        case .smooth: return .smooth
        case .balanced: return .balanced
        case .crisp: return .crisp
        }
    }
}

enum PushBehavior: String, Codable, CaseIterable, Identifiable {
    case askImmediately
    case attachToComposer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .askImmediately: return "Ask the AI right away"
        case .attachToComposer: return "Attach to the message I'm writing"
        }
    }
}

enum ChangeSensitivity: String, Codable, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Minimum screen difference (0…1) that counts as a change.
    var threshold: Double {
        switch self {
        case .low: return 0.08
        case .medium: return 0.03
        case .high: return 0.012
        }
    }
}

enum SnapshotResolution: Int, Codable, CaseIterable, Identifiable {
    case standard = 1920
    case high = 2576
    case native = 0
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard (1920 px)"
        case .high: return "High (2576 px)"
        case .native: return "Native resolution"
        }
    }
}

enum LinkPreference: String, Codable, CaseIterable, Identifiable {
    case automatic, networkOnly, bluetoothOnly
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .networkOnly: return "Network & cable only"
        case .bluetoothOnly: return "Bluetooth only"
        }
    }
}

/// All user preferences, persisted to (profile-scoped) UserDefaults.
@MainActor
@Observable
final class SettingsStore {
    static let defaultSystemPrompt = """
    You are Tandem, an assistant that can see screenshots of the user's other Mac. \
    Each screenshot shows what's on that screen right now; the user may have cropped, \
    highlighted or redacted parts of it. Answer about what is actually visible, be \
    specific (quote on-screen text, name UI elements and locations), and keep answers \
    concise and actionable. If something important isn't visible or is ambiguous, say \
    what you'd need to see.
    """

    static let defaultAutoPrompt = "Here's the latest view of my screen. Briefly point out anything important that changed or needs my attention. If nothing notable changed, reply with just \"No notable changes.\""

    static let defaultPushPrompt = "Take a look at my screen and help me with what I'm working on."

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()
    @ObservationIgnored private var isLoading = false

    // MARK: General
    var role: AppRole? = nil { didSet { store(role, "role") } }
    var deviceName: String = "" { didSet { store(deviceName, "deviceName") } }
    var appearance: AppearancePreference = .system { didSet { store(appearance, "appearance") } }
    var showInMenuBar: Bool = true { didSet { store(showInMenuBar, "showInMenuBar") } }
    var autoCheckUpdates: Bool = true { didSet { store(autoCheckUpdates, "updates.autoCheck") } }
    var linkPreference: LinkPreference = .automatic { didSet { store(linkPreference, "linkPreference") } }
    var bluetoothEnabled: Bool = true { didSet { store(bluetoothEnabled, "bluetoothEnabled") } }

    // MARK: Source
    var captureSource: CaptureSourceID? = nil { didSet { store(captureSource, "source.capture") } }
    var showCursor: Bool = true { didSet { store(showCursor, "source.showCursor") } }
    var excludeTandemWindows: Bool = true { didSet { store(excludeTandemWindows, "source.excludeTandem") } }
    var allowRemoteSourceSelection: Bool = true { didSet { store(allowRemoteSourceSelection, "source.allowRemoteSelection") } }
    var acceptPairingRequests: Bool = true { didSet { store(acceptPairingRequests, "source.acceptPairing") } }
    var approveEachSession: Bool = false { didSet { store(approveEachSession, "source.approveEachSession") } }
    var showRepliesOnSource: Bool = true { didSet { store(showRepliesOnSource, "source.showReplies") } }
    var pauseWhenLocked: Bool = true { didSet { store(pauseWhenLocked, "source.pauseWhenLocked") } }
    var snapshotResolution: SnapshotResolution = .high { didSet { store(snapshotResolution, "source.snapshotResolution") } }
    var snapshotQuality: Double = 0.9 { didSet { store(snapshotQuality, "source.snapshotQuality") } }

    // MARK: Studio / AI
    var provider: AIProviderKind = .claudeCode { didSet { store(provider, "ai.provider") } }
    var claudeCodeModel: String = ModelCatalog.defaultModelID(for: .claudeCode) ?? "claude-opus-5-5" { didSet { store(claudeCodeModel, "ai.claudeCodeModel") } }
    /// Where `claude` is installed, when it isn't found automatically. Empty means "find it".
    var claudeCodePath: String = "" { didSet { store(claudeCodePath, "ai.claudeCodePath") } }
    var anthropicModel: String = ModelCatalog.defaultModelID(for: .anthropic) ?? "claude-opus-5-5" { didSet { store(anthropicModel, "ai.anthropicModel") } }
    var openAIModel: String = ModelCatalog.defaultModelID(for: .openAI) ?? "gpt-6-astra" { didSet { store(openAIModel, "ai.openAIModel") } }
    var customModel: String = "" { didSet { store(customModel, "ai.customModel") } }
    var customBaseURL: String = AIProviderKind.openAICompatible.defaultBaseURL.absoluteString { didSet { store(customBaseURL, "ai.customBaseURL") } }
    var effort: ReasoningEffort = .low { didSet { store(effort, "ai.effort") } }
    var maxOutputTokens: Int = 16_000 { didSet { store(maxOutputTokens, "ai.maxOutputTokens") } }
    var showReasoning: Bool = true { didSet { store(showReasoning, "ai.showReasoning") } }
    var systemPrompt: String = SettingsStore.defaultSystemPrompt { didSet { store(systemPrompt, "ai.systemPrompt") } }
    var maxImagesInContext: Int = 4 { didSet { store(maxImagesInContext, "ai.maxImages") } }
    var liveQuality: LiveQualityPreset = .balanced { didSet { store(liveQuality, "studio.liveQuality") } }
    var attachLiveSnapshot: Bool = true { didSet { store(attachLiveSnapshot, "studio.attachLive") } }
    var pushBehavior: PushBehavior = .askImmediately { didSet { store(pushBehavior, "studio.pushBehavior") } }
    var pushPrompt: String = SettingsStore.defaultPushPrompt { didSet { store(pushPrompt, "studio.pushPrompt") } }
    var mirrorReplies: Bool = true { didSet { store(mirrorReplies, "studio.mirrorReplies") } }
    var autoConnect: Bool = true { didSet { store(autoConnect, "studio.autoConnect") } }
    var lastSourceID: String? = nil { didSet { store(lastSourceID, "studio.lastSourceID") } }
    var showStage: Bool = true { didSet { store(showStage, "studio.showStage") } }

    // MARK: Automation
    var autoCaptureEnabled: Bool = false { didSet { store(autoCaptureEnabled, "auto.enabled") } }
    var autoCaptureInterval: Double = 30 { didSet { store(autoCaptureInterval, "auto.interval") } }
    var onlyWhenChanged: Bool = true { didSet { store(onlyWhenChanged, "auto.onlyWhenChanged") } }
    var changeSensitivity: ChangeSensitivity = .medium { didSet { store(changeSensitivity, "auto.sensitivity") } }
    var autoAsk: Bool = true { didSet { store(autoAsk, "auto.ask") } }
    var autoPrompt: String = SettingsStore.defaultAutoPrompt { didSet { store(autoPrompt, "auto.prompt") } }
    var maxAutoAsksPerHour: Int = 60 { didSet { store(maxAutoAsksPerHour, "auto.maxPerHour") } }

    // MARK: Privacy
    var keepImages: Bool = false { didSet { store(keepImages, "privacy.keepImages") } }
    var historyRetentionDays: Int = 30 { didSet { store(historyRetentionDays, "privacy.retentionDays") } }

    // MARK: Shortcuts
    /// Per-action overrides. Missing = default combo; `nil` value = disabled.
    var hotkeyOverrides: [String: KeyCombo?] = [:] { didSet { store(hotkeyOverrides, "hotkeys") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        reload()
    }

    /// Loads every value from defaults (falling back to the built-in defaults)
    /// without writing anything back.
    private func reload() {
        isLoading = true
        defer { isLoading = false }
        let defaults = self.defaults
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: "tandem.\(key)"),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        role = load("role", nil)
        deviceName = load("deviceName", "")
        appearance = load("appearance", .system)
        showInMenuBar = load("showInMenuBar", true)
        autoCheckUpdates = load("updates.autoCheck", true)
        linkPreference = load("linkPreference", .automatic)
        bluetoothEnabled = load("bluetoothEnabled", true)
        captureSource = load("source.capture", nil)
        showCursor = load("source.showCursor", true)
        excludeTandemWindows = load("source.excludeTandem", true)
        allowRemoteSourceSelection = load("source.allowRemoteSelection", true)
        acceptPairingRequests = load("source.acceptPairing", true)
        approveEachSession = load("source.approveEachSession", false)
        showRepliesOnSource = load("source.showReplies", true)
        pauseWhenLocked = load("source.pauseWhenLocked", true)
        snapshotResolution = load("source.snapshotResolution", .high)
        snapshotQuality = load("source.snapshotQuality", 0.9)
        provider = load("ai.provider", .claudeCode)
        claudeCodeModel = load("ai.claudeCodeModel", ModelCatalog.defaultModelID(for: .claudeCode) ?? "claude-opus-5-5")
        claudeCodePath = load("ai.claudeCodePath", "")
        anthropicModel = load("ai.anthropicModel", ModelCatalog.defaultModelID(for: .anthropic) ?? "claude-opus-5-5")
        openAIModel = load("ai.openAIModel", ModelCatalog.defaultModelID(for: .openAI) ?? "gpt-6-astra")
        customModel = load("ai.customModel", "")
        customBaseURL = load("ai.customBaseURL", AIProviderKind.openAICompatible.defaultBaseURL.absoluteString)
        effort = load("ai.effort", .low)
        maxOutputTokens = load("ai.maxOutputTokens", 16_000)
        showReasoning = load("ai.showReasoning", true)
        systemPrompt = load("ai.systemPrompt", Self.defaultSystemPrompt)
        maxImagesInContext = load("ai.maxImages", 4)
        liveQuality = load("studio.liveQuality", .balanced)
        attachLiveSnapshot = load("studio.attachLive", true)
        pushBehavior = load("studio.pushBehavior", .askImmediately)
        pushPrompt = load("studio.pushPrompt", Self.defaultPushPrompt)
        mirrorReplies = load("studio.mirrorReplies", true)
        autoConnect = load("studio.autoConnect", true)
        lastSourceID = load("studio.lastSourceID", nil)
        showStage = load("studio.showStage", true)
        autoCaptureEnabled = load("auto.enabled", false)
        autoCaptureInterval = load("auto.interval", 30)
        onlyWhenChanged = load("auto.onlyWhenChanged", true)
        changeSensitivity = load("auto.sensitivity", .medium)
        autoAsk = load("auto.ask", true)
        autoPrompt = load("auto.prompt", Self.defaultAutoPrompt)
        maxAutoAsksPerHour = load("auto.maxPerHour", 60)
        keepImages = load("privacy.keepImages", false)
        historyRetentionDays = load("privacy.retentionDays", 30)
        hotkeyOverrides = load("hotkeys", [:])
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        guard !isLoading, let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: "tandem.\(key)")
    }

    // MARK: Derived

    /// The model id for the active provider.
    var currentModel: String {
        get {
            switch provider {
            case .anthropic: return anthropicModel
            case .openAI: return openAIModel
            case .openAICompatible: return customModel
            case .claudeCode: return claudeCodeModel
            }
        }
        set {
            switch provider {
            case .anthropic: anthropicModel = newValue
            case .openAI: openAIModel = newValue
            case .openAICompatible: customModel = newValue
            case .claudeCode: claudeCodeModel = newValue
            }
        }
    }

    var currentModelDisplayName: String {
        let model = currentModel
        if let preset = ModelCatalog.presets(for: provider).first(where: { $0.id == model }) { return preset.displayName }
        return model.isEmpty ? "No model" : model
    }

    func combo(for action: HotkeyAction) -> KeyCombo? {
        if let override = hotkeyOverrides[action.id] { return override }
        return action.defaultCombo
    }

    func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) {
        if combo == action.defaultCombo {
            hotkeyOverrides[action.id] = nil
        } else {
            hotkeyOverrides[action.id] = .some(combo)
        }
    }

    /// Restores every setting to its default, in memory and on disk.
    func resetAll() {
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("tandem.") && $0 != "tandem.deviceID" && $0 != "tandem.trustedPeers"
        }
        for key in keys { defaults.removeObject(forKey: key) }
        reload()
    }
}
