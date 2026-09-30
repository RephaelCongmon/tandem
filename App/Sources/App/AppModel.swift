import AppKit
import Observation
import os
import ServiceManagement
import TandemCore
import TandemUI

/// Root object graph. One per process.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings: SettingsStore
    let keys: APIKeyStore
    let trust: TrustedPeerStore
    let connections: ConnectionManager
    let source: SourceEngine
    let studio: StudioEngine
    let claudeCode: ClaudeCodeService
    let updates: UpdateController
    let hotkeys: HotkeyController
    let toasts = ToastCenter()
    private(set) var identity: DeviceIdentity
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// macOS opened Tandem at login. A sharing Mac then starts quietly in the menu bar.
    @ObservationIgnored var launchedAtLogin = false
    /// Set once the launch window was hidden or the user asked for the window.
    @ObservationIgnored private var launchWindowDecided = false
    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var activityOptions: ProcessInfo.ActivityOptions = []

    /// Set by the first SwiftUI view that appears; opens (or reopens) the main window.
    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    /// The Settings tab to show; set it before opening Settings to land on a pane.
    var settingsTab: String = AppModel.initialSettingsTab

    private static var initialSettingsTab: String {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "TandemSettingsTab") ?? "general"
        #else
        return "general"
        #endif
    }

    func openSettings(tab: String) {
        settingsTab = tab
        openSettingsAction?()
    }

    var chat: ChatController { studio.chat }
    var needsOnboarding: Bool { settings.role == nil }

    private init() {
        let defaults = AppEnvironment.defaults
        let settings = SettingsStore(defaults: defaults)
        self.settings = settings
        keys = APIKeyStore(servicePrefix: AppEnvironment.keychainPrefix)
        let keyStore = KeychainPairingKeyStore(service: "\(AppEnvironment.keychainPrefix).pairing")
        trust = TrustedPeerStore(keyStore: keyStore, defaults: defaults)
        let identity = DeviceIdentity.loadOrCreate(defaults: defaults, customName: settings.deviceName)
        self.identity = identity
        connections = ConnectionManager(settings: settings, trust: trust, identity: identity)
        source = SourceEngine(settings: settings)
        let updates = UpdateController(settings: settings)
        self.updates = updates
        let claudeCode = ClaudeCodeService(settings: settings)
        self.claudeCode = claudeCode
        studio = StudioEngine(
            settings: settings,
            keys: keys,
            claudeCodeExecutable: { claudeCode.executable },
            speechModelMirror: Self.speechModelMirror(updates: updates)
        )
        hotkeys = HotkeyController()

        connections.onEstablished = { [weak self] connection in
            guard let self else { return }
            // Route by the running role (also set during onboarding, before `settings.role`).
            self.route(connection)
            self.updateActivity()
            if connection.newlyPaired, let peer = connection.peer {
                self.toasts.show("Paired with \(peer.name)", systemImage: "checkmark.seal.fill")
            }
        }
        connections.onClosed = { [weak self] connection, _ in
            self?.source.detach(connection)
            self?.studio.detach(connection)
            self?.updateActivity()
        }
        source.onDenySessions = { [weak self] peerID in self?.connections.denySessions(from: peerID) }
        connections.onNeedsDecision = { [weak self] in self?.presentForDecision() }
        source.onNeedsDecision = { [weak self] in self?.presentForDecision() }
        hotkeys.model = self
        studio.sharedMacUpdater.toasts = toasts
        studio.sharedMacUpdater.onSourceRestarting = { [weak self] in
            // The shared Mac relaunches in a couple of seconds; don't wait out the backoff.
            Task { @MainActor [weak self] in
                for delay in [2.5, 1.5, 2, 3] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, !self.studio.isConnected else { return }
                    self.connections.retryNow()
                }
            }
        }
    }

    func start() {
        #if DEBUG
        let arguments = UserDefaults.standard
        if let raw = arguments.string(forKey: "TandemRole"), let role = AppRole(rawValue: raw) { settings.role = role }
        if arguments.bool(forKey: "TandemTestPattern") { settings.captureSource = TestPatternGenerator.sourceID }
        // Saved by the app itself, so reading it back never raises a Keychain prompt.
        if let key = ProcessInfo.processInfo.environment["TANDEM_DEBUG_API_KEY"], !key.isEmpty {
            try? keys.setKey(key, for: settings.provider)
        }
        DebugCommands.install(model: self)
        let showAfter = arguments.double(forKey: "TandemShowWindowAfter")
        if showAfter > 0 {
            // Stands in for clicking "Open Tandem" in the menu bar (for launch checks).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(showAfter * 1_000_000_000))
                Logger(subsystem: "com.rofel.tandem", category: "Debug").notice("TANDEM-SHOW hasAction=\(self.openMainWindowAction != nil, privacy: .public)")
                self.showMainWindow()
            }
        }
        #endif
        applyAppearance()
        if let role = settings.role { activate(role) }
        updates.startAutomaticChecks()
    }

    /// "Check for Updates…": checks now and reports the outcome.
    func checkForUpdatesInteractively() {
        Task {
            await updates.check()
            if updates.latest != nil {
                showMainWindow()
                updates.isPanelPresented = true
            } else if updates.access == .none {
                toasts.show("Add GitHub access in Settings › General to check for updates", systemImage: "key.fill", style: .warning)
                openSettingsAction?()
            } else if let error = updates.checkError {
                toasts.show(error, systemImage: "exclamationmark.triangle.fill", style: .warning)
            } else {
                toasts.show("Tandem \(updates.currentVersion) is up to date", systemImage: "checkmark.circle.fill", style: .success)
            }
        }
    }

    /// Whether the main window should close itself as it first appears: a sharing Mac
    /// opened at login keeps listening from the menu bar. Answers true at most once, only
    /// right after launch, and never once the user has asked for the window.
    func consumeStartsHidden() -> Bool {
        guard !launchWindowDecided else { return false }
        launchWindowDecided = true
        return launchedAtLogin && settings.role == .source && Date().timeIntervalSince(launchedAt) < 15
    }

    /// Called by any SwiftUI view that can open scenes, so AppKit code can open them too.
    func registerSceneActions(openMainWindow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        openMainWindowAction = openMainWindow
        openSettingsAction = openSettings
    }

    /// Fetches the speech model from Tandem's own releases (pinned and checksummed) using the
    /// update feed's GitHub access. Without access it throws, and the model comes from Hugging Face.
    private static func speechModelMirror(updates: UpdateController) -> ParakeetModelStore.MirrorDownload {
        { [weak updates] destination, progress in
            guard let updates else { throw UpdateError.accessDenied("Tandem is quitting.") }
            let folder = destination.deletingLastPathComponent().appendingPathComponent(".zip-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let mirror = ParakeetModelStore.Mirror.self
            let archive = try await updates.downloadReleaseFile(named: mirror.assetName, tag: mirror.releaseTag, to: folder) { progress($0 * 0.97) }
            guard try FileTools.sha256(of: archive) == mirror.sha256 else {
                throw UpdateError.invalidPackage("The speech model download didn't match Tandem's checksum.")
            }
            try await FileTools.unzip(archive, to: destination)
            progress(1)
        }
    }

    // MARK: Roles

    func activate(_ role: AppRole) {
        if settings.role != role { settings.role = role }
        connections.activate(role: role)
        switch role {
        case .source:
            studio.chat.stop()
            studio.transcription.suspend()
            ClaudeCodeSessionPool.shared.removeAll()
            source.activate()
        case .studio:
            source.deactivate()
            claudeCode.refreshInBackground()
            studio.transcription.resume()
            studio.transcription.prepareModelInBackground()
            // Once Claude Code has been found, have it running before the first question.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.studio.chat.prewarm()
            }
        }
        // Sessions established during onboarding are handed to the engine now.
        for connection in connections.establishedConnections { route(connection) }
        hotkeys.registerAll()
        updateActivity()
    }

    private func route(_ connection: PeerConnection) {
        switch connections.role {
        case .source: if connection.direction == .incoming { source.attach(connection) }
        case .studio: if connection.direction == .outgoing { studio.attach(connection) }
        case nil: break
        }
    }

    func switchRole(to role: AppRole) {
        guard settings.role != role else { return }
        connections.deactivate()
        source.deactivate()
        activate(role)
    }

    func resetOnboarding() {
        connections.deactivate()
        source.deactivate()
        studio.transcription.suspend()
        hotkeys.unregisterAll()
        settings.role = nil
        updateActivity()
    }

    /// Without a visible window macOS naps a background app (delaying its network
    /// callbacks by seconds) and may even quit it. While Tandem listens for or talks to
    /// the other Mac it tells the system this is user-requested, latency-critical work.
    /// Idle system sleep stays allowed, so an unattended laptop can still sleep.
    private func updateActivity() {
        var options: ProcessInfo.ActivityOptions = []
        if settings.role != nil, connections.role != nil { options.insert(.userInitiatedAllowingIdleSystemSleep) }
        if !connections.establishedConnections.isEmpty { options.formUnion([.userInitiatedAllowingIdleSystemSleep, .latencyCritical]) }
        guard options != activityOptions else { return }
        let previous = activity
        activity = options.isEmpty ? nil : ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: options.contains(.latencyCritical) ? "Connected to another Mac" : "Waiting for your other Mac"
        )
        activityOptions = options
        if let previous { ProcessInfo.processInfo.endActivity(previous) }
    }

    // MARK: Identity & preferences

    func applyDeviceName() {
        identity = DeviceIdentity.loadOrCreate(defaults: AppEnvironment.defaults, customName: settings.deviceName)
        connections.updateIdentity(identity)
    }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            toasts.show("Couldn't change login item: \(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill", style: .warning)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Shows the main window. `reopenIfNeeded` covers a Tandem that started in the
    /// background, where no view exists yet to open it: LaunchServices reopens the app,
    /// which makes SwiftUI create the window just as a Dock click does.
    func showMainWindow(reopenIfNeeded: Bool = true) {
        launchWindowDecided = true
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindowAction {
            openMainWindowAction()
        } else if reopenIfNeeded {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue == "main" || $0.title == "Tandem") && $0.canBecomeMain }
    }

    /// A pairing request or session approval needs someone at this Mac, and its prompt
    /// lives in the main window: bring the window forward (even when Tandem runs quietly
    /// in the menu bar) without taking keyboard focus from the app they're using.
    private func presentForDecision() {
        launchWindowDecided = true
        if let window = mainWindow {
            window.orderFrontRegardless()
        } else {
            openMainWindowAction?()
            // SwiftUI creates the window on its next pass.
            DispatchQueue.main.async { [weak self] in self?.mainWindow?.orderFrontRegardless() }
        }
        NSApp.requestUserAttention(.criticalRequest)
    }

    func prepareForTermination() {
        studio.chat.stop()
        ClaudeCodeSessionPool.shared.removeAll()
        studio.chat.flush()
        connections.deactivate()
        hotkeys.unregisterAll()
    }
}
