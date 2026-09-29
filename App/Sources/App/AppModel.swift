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
    let hotkeys: HotkeyController
    let toasts = ToastCenter()
    private(set) var identity: DeviceIdentity
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Set by the first SwiftUI view that appears; opens (or reopens) the main window.
    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?

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
        studio = StudioEngine(settings: settings, keys: keys)
        hotkeys = HotkeyController()

        connections.onEstablished = { [weak self] connection in
            guard let self else { return }
            switch self.settings.role {
            case .source: if connection.direction == .incoming { self.source.attach(connection) }
            case .studio: if connection.direction == .outgoing { self.studio.attach(connection) }
            case nil: break
            }
            if connection.newlyPaired, let peer = connection.peer {
                self.toasts.show("Paired with \(peer.name)", systemImage: "checkmark.seal.fill")
            }
        }
        connections.onClosed = { [weak self] connection, _ in
            self?.source.detach(connection)
            self?.studio.detach(connection)
        }
        hotkeys.model = self
    }

    func start() {
        #if DEBUG
        let arguments = UserDefaults.standard
        if let raw = arguments.string(forKey: "TandemRole"), let role = AppRole(rawValue: raw) { settings.role = role }
        if arguments.bool(forKey: "TandemTestPattern") { settings.captureSource = TestPatternGenerator.sourceID }
        #endif
        applyAppearance()
        if let role = settings.role { activate(role) }
    }

    // MARK: Roles

    func activate(_ role: AppRole) {
        if settings.role != role { settings.role = role }
        connections.activate(role: role)
        switch role {
        case .source:
            studio.chat.stop()
            source.activate()
        case .studio:
            source.deactivate()
        }
        hotkeys.registerAll()
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
        hotkeys.unregisterAll()
        settings.role = nil
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

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Tandem" }), window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    func prepareForTermination() {
        studio.chat.stop()
        studio.chat.flush()
        connections.deactivate()
        hotkeys.unregisterAll()
    }
}
