import AppKit
import SwiftUI
import TandemCore
import TandemUI

@main
struct TandemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    init() {
        // No session restore: a restored-but-empty session stops SwiftUI from opening the
        // main window on a normal launch. Tandem decides itself (see MainWindowConfigurator).
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        Window("Tandem", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { TandemCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.settings.showInMenuBar },
            set: { model.settings.showInMenuBar = $0 }
        )) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tandem listens for the other Mac with no window open; macOS must not quit it.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        // The launch event says whether macOS opened Tandem as a login item.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let asLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        MainActor.assumeIsolated {
            AppModel.shared.launchedAtLogin = asLoginItem || AppEnvironment.simulateLoginLaunch
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host the app; don't start networking or capture under them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        MainActor.assumeIsolated {
            AppModel.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Returning true also lets SwiftUI create the window if none exists yet.
        MainActor.assumeIsolated { AppModel.shared.showMainWindow(reopenIfNeeded: false) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            if model.settings.role == .source { model.source.refreshPermission() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.prepareForTermination()
        }
    }
}

struct TandemCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.checkForUpdatesInteractively() }
                .disabled(model.updates.isUpdating)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Thread") { model.chat.newThread() }
                .keyboardShortcut("n")
                .disabled(model.settings.role != .studio)
        }
        CommandMenu("Capture") {
            if model.settings.role == .studio {
                Button("Capture & Ask") { model.studio.captureAndAsk() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!model.studio.canCapture)
                Button("Capture to Composer") { model.studio.captureToComposer() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.studio.canCapture)
                Divider()
                Button(model.settings.autoCaptureEnabled ? "Turn Off Auto-Capture" : "Turn On Auto-Capture") {
                    model.studio.toggleAutoCapture()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button(model.studio.livePreviewEnabled ? "Hide Live View" : "Show Live View") {
                    model.studio.livePreviewEnabled.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                if !model.settings.skills.isEmpty {
                    Divider()
                    ForEach(Array(model.settings.skills.prefix(9).enumerated()), id: \.element.id) { index, skill in
                        Button(skill.title) { model.chat.send(skill: skill) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                            .disabled(model.chat.isBusy)
                    }
                }
                Divider()
                Button("Stop Answering") { model.chat.stop() }
                    .keyboardShortcut(".")
                    .disabled(model.chat.streaming == nil)
            } else if model.settings.role == .source {
                Button("Send Snapshot") {
                    Task { model.toasts.showPush(await model.source.pushSnapshot(note: nil)) }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Send Snapshot with Note…") { QuickNotePanelController.shared.present(model: model) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(model.source.isSharingEnabled ? "Pause Sharing" : "Resume Sharing") { model.source.toggleSharing() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        CommandGroup(after: .appSettings) {
            if let role = model.settings.role {
                let other: AppRole = role == .source ? .studio : .source
                Button("Switch to \(other.shortTitle) Mode") { model.switchRole(to: other) }
            }
        }
    }
}
