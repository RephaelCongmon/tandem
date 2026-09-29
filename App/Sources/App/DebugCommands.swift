#if DEBUG
import AppKit
import Foundation
import os
import TandemCore

/// Debug-only remote control for automated end-to-end checks. A command is a
/// distributed notification named `com.rofel.tandem.debug` whose object is
/// `"<profile>|<command>|<argument>"`; only the matching profile reacts.
/// Never compiled into Release builds.
@MainActor
enum DebugCommands {
    static let notificationName = Notification.Name("com.rofel.tandem.debug")
    private static var observer: NSObjectProtocol?

    static func install(model: AppModel) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notificationName, object: nil, queue: .main) { note in
            guard let raw = note.object as? String else { return }
            let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[0] == (AppEnvironment.profile ?? "") else { return }
            let argument = parts.count > 2 ? parts[2] : ""
            MainActor.assumeIsolated { run(parts[1], argument: argument, model: model) }
        }
    }

    private static func run(_ command: String, argument: String, model: AppModel) {
        switch command {
        case "ask":
            model.chat.composerText = argument
            model.chat.sendFromComposer()
        case "captureAndAsk":
            model.studio.captureAndAsk()
        case "captureToComposer":
            model.studio.captureToComposer()
        case "editFirstAttachment":
            model.chat.editRequest = model.chat.composerAttachments.first?.id
        case "push":
            Task { model.toasts.showPush(await model.source.pushSnapshot(note: argument.isEmpty ? nil : argument)) }
        case "noteSheet":
            QuickNotePanelController.shared.present(model: model)
        case "pause":
            model.source.setSharing(false)
        case "resume":
            model.source.setSharing(true)
        case "auto":
            model.settings.autoCaptureInterval = Double(argument) ?? 10
            model.settings.autoCaptureEnabled = true
            model.studio.restartAutomation()
        case "autoOff":
            model.settings.autoCaptureEnabled = false
            model.studio.restartAutomation()
        case "settings":
            model.openSettingsAction?()
        case "newThread":
            model.chat.newThread()
        case "toast":
            model.toasts.show(argument, systemImage: "sparkles")
        case "dump":
            dump(model: model)
        case "snap":
            snapshotWindows(name: argument.isEmpty ? "window" : argument)
        case "quit":
            NSApp.terminate(nil)
        default:
            NSLog("Tandem debug: unknown command \(command)")
        }
    }

    /// Renders every visible window (and attached sheet) to PNG and uploads it to
    /// the local QA server (`scripts/mock_ai_server.py`), which saves it to /tmp/tandem-qa.
    private static func snapshotWindows(name: String) {
        let profile = AppEnvironment.profile ?? "default"
        var index = 0
        for window in NSApp.windows where window.isVisible && window.frame.width > 200 {
            for (suffix, target) in [("", window), ("-sheet", window.attachedSheet)] {
                guard let target, let view = target.contentView?.superview ?? target.contentView else { continue }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let file = "\(profile)-\(name)-\(index)\(suffix).png"
                upload(png, as: file)
            }
            index += 1
        }
    }

    private static func upload(_ data: Data, as name: String) {
        guard let base = AppEnvironment.debugAIBaseURL ?? URL(string: "http://127.0.0.1:18765/v1/"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        components.path = "/upload/\(name)"
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Writes a state snapshot to the container's tmp directory.
    private static func dump(model: AppModel) {
        let studio = model.studio
        let source = model.source
        var lines: [String] = []
        lines.append("role=\(model.settings.role?.rawValue ?? "nil")")
        lines.append("connections=\(model.connections.connections.map { "\($0.peer?.name ?? "?"):\($0.phase):\($0.linkKind.rawValue):rtt=\($0.stats.rttMillis ?? -1)" })")
        lines.append("studio.isConnected=\(studio.isConnected) liveState=\(studio.liveState) hasVideo=\(studio.hasVideo) stageVisible=\(studio.isStageVisible) preview=\(studio.livePreviewEnabled)")
        lines.append("studio.sourceStatus=\(String(describing: studio.sourceStatus))")
        lines.append("studio.liveStats=\(studio.liveStats)")
        lines.append("source.viewers=\(source.viewers.map { "\($0.name) approved=\($0.approved) watching=\($0.isWatching) request=\(String(describing: $0.streamRequest))" })")
        lines.append("source.captureState=\(source.captureState) streaming=\(source.isStreaming) stats=\(source.streamStats)")
        lines.append("chat.threads=\(model.chat.threads.count) streaming=\(model.chat.streaming != nil) banner=\(model.chat.banner ?? "-")")
        lines.append("auto=\(model.settings.autoCaptureEnabled) last=\(studio.lastAutoResult ?? "-")")
        // Logged (not written to the container) so tools can read it without
        // triggering the "access data from other apps" privacy prompt.
        let logger = Logger(subsystem: "com.rofel.tandem", category: "Debug")
        let profile = AppEnvironment.profile ?? "default"
        for line in lines { logger.notice("TANDEM-STATE[\(profile, privacy: .public)] \(line, privacy: .public)") }
    }
}
#endif
