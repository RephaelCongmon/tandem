#if DEBUG
import AppKit
import Foundation
import os
import TandemCore
import TandemUI

/// Debug-only remote control for automated end-to-end checks. A command is a
/// distributed notification named `com.rofel.tandem.debug` whose object is
/// `"<profile>|<command>|<argument>"`; only the matching profile reacts.
/// Never compiled into Release builds.
@MainActor
enum DebugCommands {
    static let notificationName = Notification.Name("com.rofel.tandem.debug")
    private static var receiver: Receiver?

    /// Selector-based so delivery isn't suspended while Tandem runs in the background.
    private final class Receiver: NSObject {
        let model: AppModel
        init(model: AppModel) { self.model = model }

        @objc func received(_ note: Notification) {
            guard let raw = note.object as? String else { return }
            let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[0] == (AppEnvironment.profile ?? "") else { return }
            let argument = parts.count > 2 ? parts[2] : ""
            MainActor.assumeIsolated { DebugCommands.run(parts[1], argument: argument, model: model) }
        }
    }

    static func install(model: AppModel) {
        guard receiver == nil else { return }
        let receiver = Receiver(model: model)
        self.receiver = receiver
        DistributedNotificationCenter.default().addObserver(
            receiver, selector: #selector(Receiver.received(_:)), name: notificationName, object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    private static func run(_ command: String, argument: String, model: AppModel) {
        switch command {
        case "ask":
            model.chat.composerText = argument
            model.chat.sendFromComposer()
        case "captureAndAsk":
            model.studio.captureAndAsk()
        case "captureToComposer", "regionTool":
            // regionTool [on|off]; no argument toggles.
            if argument.isEmpty { model.studio.toggleRegionTool() } else { model.studio.setRegionTool(argument != "off") }
        case "regionDown":
            // Press on the live view with the tool (hold the frame); regionUp releases.
            model.studio.beginRegionDrag()
        case "regionUp":
            let values = argument.split(separator: " ").compactMap { Double($0) }
            model.studio.endRegionDrag(values.count == 4 ? SnapshotRegion(x: values[0], y: values[1], width: values[2], height: values[3]) : nil)
        case "regionBurst":
            // regionBurst N: N quick drags in a row over different parts of the frame.
            for index in 0..<max(1, Int(argument) ?? 4) where model.studio.beginRegionDrag() {
                let x = Double(index % 4) * 0.25
                model.studio.endRegionDrag(SnapshotRegion(x: x, y: 0.1, width: 0.2, height: 0.3))
            }
        case "regionDrag":
            // regionDrag x y width height (normalized) or empty for the whole frame: one drag with the tool.
            let values = argument.split(separator: " ").compactMap { Double($0) }
            if model.studio.beginRegionDrag() {
                model.studio.endRegionDrag(values.count == 4 ? SnapshotRegion(x: values[0], y: values[1], width: values[2], height: values[3]) : .full)
            }
        case "connectNamedSource":
            if let peer = model.connections.nearby.first(where: { $0.name == argument }) {
                model.connections.connect(to: peer.id)
            }
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
            if argument.isEmpty { model.openSettingsAction?() } else { model.openSettings(tab: argument) }
        case "front":
            // Visible without taking keyboard focus from the app in use.
            for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == "Tandem" { window.orderFrontRegardless() }
        case "close":
            for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == "Tandem" { window.close() }
        case "checkUpdates":
            Task {
                await model.updates.check()
                Logger(subsystem: "com.rofel.tandem", category: "Debug").notice("TANDEM-UPDATE current=\(model.updates.versionDescription, privacy: .public) latest=\(model.updates.latest?.version.description ?? "none", privacy: .public) access=\(String(describing: model.updates.access), privacy: .public) error=\(model.updates.checkError ?? "-", privacy: .public)")
            }
        case "checkForUpdates":
            model.checkForUpdatesInteractively()
        case "updateNow":
            Task {
                await model.updates.updateNow()
                Logger(subsystem: "com.rofel.tandem", category: "Debug").notice("TANDEM-UPDATE install error=\(model.updates.installError ?? "-", privacy: .public)")
            }
        case "skill":
            if let index = Int(argument), model.settings.skills.indices.contains(index - 1) {
                model.chat.send(skill: model.settings.skills[index - 1])
            }
        case "composerText":
            model.chat.composerText = argument
        case "effort":
            if let effort = ReasoningEffort(rawValue: argument) { model.settings.effort = effort }
        case "provider":
            // provider <kind> [model], e.g. `provider codex gpt-6-astra`
            let words = argument.split(separator: " ").map(String.init)
            if let kind = words.first.flatMap(AIProviderKind.init(rawValue:)) {
                model.settings.provider = kind
                if words.count > 1 { model.settings.currentModel = words[1] }
                if kind == .codex { model.codex.refreshInBackground() }
            }
        case "codexStatus":
            Task {
                await model.codex.refresh()
                Logger(subsystem: "com.rofel.tandem", category: "Debug").notice("TANDEM-CODEX \(model.codex.status?.summary ?? "nil", privacy: .public) models=\(model.codex.models.map(\.id), privacy: .public)")
            }
        case "claudeStatus":
            Task {
                await model.claudeCode.refresh()
                Logger(subsystem: "com.rofel.tandem", category: "Debug").notice("TANDEM-CLAUDE \(model.claudeCode.status?.summary ?? "nil", privacy: .public)")
            }
        case "show":
            Logger(subsystem: "com.rofel.tandem", category: "Debug").notice("TANDEM-SHOW hasAction=\(model.openMainWindowAction != nil, privacy: .public)")
            model.showMainWindow()
        case "newThread":
            model.chat.newThread()
        case "toast":
            model.toasts.show(argument, systemImage: "sparkles")
        case "kick":
            for viewer in model.source.viewers { model.connections.disconnect(viewer.connection) }
        case "localNetwork":
            model.connections.debugSimulateLocalNetwork(LocalNetworkAccess(rawValue: argument) ?? .denied)
        case "drop":
            // Cuts every link without a goodbye, like sleep or a network drop.
            for connection in model.connections.connections {
                let link = connection.link
                link.queue.async { link.transport.close() }
            }
        case "hotkey":
            if let action = HotkeyAction(rawValue: argument) { model.hotkeys.perform(action) }
        case "listen":
            model.studio.setListening(argument != "off")
        case "transcript":
            let transcription = model.studio.transcription
            let logger = Logger(subsystem: "com.rofel.tandem", category: "Debug")
            logger.notice("TANDEM-TRANSCRIPT engine=\(String(describing: transcription.engineState), privacy: .public) name=\(transcription.engineName ?? "-", privacy: .public) receiving=\(transcription.isReceivingAudio(), privacy: .public) level=\(transcription.level, privacy: .public) audio=\(String(describing: model.studio.sourceAudioStatus), privacy: .public) problem=\(model.studio.listeningProblem ?? "-", privacy: .public)")
            for segment in transcription.transcript.segments.suffix(20) {
                logger.notice("TANDEM-TRANSCRIPT [\(segment.start.formatted(date: .omitted, time: .standard), privacy: .public)] \(segment.text, privacy: .public)")
            }
            if let volatile = transcription.transcript.volatile {
                logger.notice("TANDEM-TRANSCRIPT (volatile) \(volatile.text, privacy: .public)")
            }
        case "lastAnswer":
            let logger = Logger(subsystem: "com.rofel.tandem", category: "Debug")
            if let thread = model.chat.selectedThread {
                for message in thread.messages.suffix(4) {
                    let transcript = message.transcript.map { "transcript(\($0.segments.count) seg, pending=\($0.pendingText ?? "-")): \($0.plainText)" } ?? "-"
                    let flat = { (text: String) in text.replacingOccurrences(of: "\n", with: " ⏎ ") }
                    logger.notice("TANDEM-ANSWER \(message.role.rawValue, privacy: .public) skill=\(message.skill?.title ?? "-", privacy: .public) first=\(message.firstTokenSeconds ?? -1, privacy: .public) total=\(message.totalSeconds ?? -1, privacy: .public) \(flat(transcript), privacy: .public) || \(flat(message.text), privacy: .public)")
                }
            }
        case "glance":
            // glance <text>: show a note (\n for new lines).
            model.studio.glance.show(argument.replacingOccurrences(of: "\\n", with: "\n"), title: nil, origin: .note)
        case "glanceType":
            // glanceType <text>: types it into the Glance field with live typing, ~25 keys a second.
            let glance = model.studio.glance
            glance.liveTyping = true
            glance.draft = ""
            Task { @MainActor in
                for character in argument.replacingOccurrences(of: "\\n", with: "\n") {
                    glance.draft.append(character)
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
            }
        case "glancePasteHTML":
            // glancePasteHTML <file>: what pasting that HTML into the Glance field shows.
            if let html = try? String(contentsOfFile: argument, encoding: .utf8) {
                let markdown = RichTextMarkdown.markdown(html: html) ?? html
                Logger(subsystem: "com.rofel.tandem", category: "Debug").notice("TANDEM-PASTE \(markdown.replacingOccurrences(of: "\n", with: " ⏎ "), privacy: .public)")
                model.studio.glance.draft = markdown
                model.studio.glance.showDraft()
            }
        case "glanceAnswer":
            model.studio.glance.showLatestAnswer()
        case "glanceFollow":
            model.studio.glance.followAnswers = argument != "off"
        case "glanceTool":
            if argument.isEmpty || (argument == "on") != model.studio.glance.isToolOn { model.studio.toggleGlanceTool() }
        case "glanceScroll":
            // glanceScroll top|bottom|up|down|pageUp|pageDown|<points>
            let glance = model.studio.glance
            switch argument {
            case "top": glance.scroll(.top)
            case "bottom": glance.scroll(.bottom)
            case "up": glance.scroll(.lineUp)
            case "down": glance.scroll(.lineDown)
            case "pageUp": glance.scroll(.pageUp)
            case "pageDown": glance.scroll(.pageDown)
            default: if let points = Double(argument) { glance.setScrollOffset(points, animated: false) }
            }
        case "glanceFrame":
            // glanceFrame x y width height (fractions of the Source's screen)
            let values = argument.split(separator: " ").compactMap { Double($0) }
            if values.count == 4 { model.studio.glance.setFrame(GlanceFrame(x: values[0], y: values[1], width: values[2], height: values[3]), animated: false) }
        case "glancePlace":
            if let placement = GlancePlacement(rawValue: argument) { model.studio.glance.place(placement) }
        case "glanceDisplay":
            // glanceDisplay <display id> | shared
            model.studio.glance.setDisplay(argument == "shared" || argument.isEmpty ? nil : argument)
        case "glanceVisible":
            model.studio.glance.setVisible(argument != "off")
        case "glanceOpacity":
            if let value = Double(argument) { model.studio.glance.setOpacity(value) }
        case "glanceScale":
            if let value = Double(argument) { model.studio.glance.setTextScale(value) }
        case "glanceClear":
            model.studio.glance.clear()
        case "glanceBench":
            // glanceBench N: N trackpad-like scroll steps at 60 Hz, then the round-trip spread.
            let glance = model.studio.glance
            let steps = max(1, Int(argument) ?? 120)
            let before = glance.roundTripSamples.count
            Task { @MainActor in
                for index in 0..<steps {
                    glance.scroll(by: index % 60 < 30 ? 6 : -6)
                    try? await Task.sleep(nanoseconds: 16_666_667)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                let samples = Array(glance.roundTripSamples.dropFirst(before)).sorted()
                let pick = { (q: Double) in samples.isEmpty ? -1 : samples[min(samples.count - 1, Int(Double(samples.count - 1) * q))] }
                Logger(subsystem: "com.rofel.tandem", category: "Debug").notice("TANDEM-GLANCE bench steps=\(steps, privacy: .public) acked=\(samples.count, privacy: .public) rtt min=\(pick(0), format: .fixed(precision: 1), privacy: .public) p50=\(pick(0.5), format: .fixed(precision: 1), privacy: .public) p95=\(pick(0.95), format: .fixed(precision: 1), privacy: .public) max=\(pick(1), format: .fixed(precision: 1), privacy: .public) ms")
            }
        case "glanceHide":
            // On the Source: what ⌃⌥G does there.
            model.source.glance.toggleHiddenHere()
        case "stageDrag":
            // stageDrag x1 y1 x2 y2 [hold]: a mouse drag on the live view (fractions of it, from
            // the top left), sent to the window in-process (the real pointer doesn't move). It
            // holds `hold` seconds before letting go, so `snap` can see the drag.
            let values = argument.split(separator: " ").compactMap { Double($0) }
            if values.count >= 4 {
                StageDragSimulator.run(from: CGPoint(x: values[0], y: values[1]), to: CGPoint(x: values[2], y: values[3]), hold: values.count > 4 ? values[4] : 0)
            }
        case "glanceAudit":
            // On the Source: `glanceAudit start`, drive the Glance from the Studio, then
            // `glanceAudit report` — proves it never took focus, activation or clicks.
            GlanceFocusAudit.shared.run(argument, model: model)
        case "glanceAllow":
            // On the Source: Settings › Sharing › Let the other Mac show text on this screen.
            model.settings.allowGlance = argument != "off"
            model.source.glance.allowedChanged()
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

    /// Drags on the live view with synthetic events delivered straight to the window.
    @MainActor
    enum StageDragSimulator {
        static func run(from: CGPoint, to: CGPoint, hold: Double) {
            let log = Logger(subsystem: "com.rofel.tandem", category: "Debug")
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView.map(findVideo) != nil }),
                  let content = window.contentView, let video = findVideo(in: content) else {
                log.notice("TANDEM-DRAG no live view")
                return
            }
            let rect = video.convert(video.bounds, to: nil)
            func point(_ fraction: CGPoint) -> NSPoint {
                NSPoint(x: rect.minX + rect.width * fraction.x, y: rect.maxY - rect.height * fraction.y)
            }
            func event(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseUp ? 0 : 1)
            }
            let start = point(from)
            let end = point(to)
            Task { @MainActor in
                if let down = event(.leftMouseDown, at: start) { window.sendEvent(down) }
                for step in 1...15 {
                    let t = Double(step) / 15
                    let location = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    if let drag = event(.leftMouseDragged, at: location) { window.sendEvent(drag) }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                log.notice("TANDEM-DRAG dragging (held \(hold, privacy: .public) s)")
                try? await Task.sleep(nanoseconds: UInt64(max(0, hold) * 1_000_000_000))
                if let up = event(.leftMouseUp, at: end) { window.sendEvent(up) }
                log.notice("TANDEM-DRAG released")
            }
        }

        private static func findVideo(in view: NSView) -> NSView? {
            if view is VideoLayerView.LayerHostView { return view }
            for subview in view.subviews {
                if let found = findVideo(in: subview) { return found }
            }
            return nil
        }
    }

    /// Watches for anything the Glance overlay could take from the app in use on the Source.
    @MainActor
    final class GlanceFocusAudit {
        static let shared = GlanceFocusAudit()
        private var observers: [NSObjectProtocol] = []
        private var tandemActivations = 0
        private var keyOrMain: [String] = []
        private var frontmostChanges: [String] = []
        private var frontBefore: String?
        private var started = Date()
        private let log = Logger(subsystem: "com.rofel.tandem", category: "Debug")

        func run(_ argument: String, model: AppModel) {
            if argument == "report" { report(model) } else { start() }
        }

        private func start() {
            for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observers.removeAll()
            tandemActivations = 0
            keyOrMain = []
            frontmostChanges = []
            started = Date()
            frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tandemActivations += 1 }
            })
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        let window = note.object as? NSWindow
                        self?.keyOrMain.append("\(name.rawValue.replacingOccurrences(of: "NSWindowDidBecome", with: "")):\(window?.title ?? "?")")
                    }
                })
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    self?.frontmostChanges.append(app?.localizedName ?? "?")
                }
            })
            log.notice("TANDEM-AUDIT start front=\(self.frontBefore ?? "-", privacy: .public) tandemActive=\(NSApp.isActive, privacy: .public)")
        }

        private func report(_ model: AppModel) {
            let panel = model.source.glance.debugPanel
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
            var clicksGoTo: [String] = []
            var drawnOnTop: [String] = []
            if let panel, panel.isVisible {
                let frame = panel.frame
                for fy in [0.2, 0.5, 0.8] {
                    for fx in [0.15, 0.5, 0.85] {
                        let point = NSPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)
                        let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                        clicksGoTo.append(hit == panel.windowNumber ? "OVERLAY" : Self.owner(of: hit))
                        drawnOnTop.append(Self.overlayIsAbove(hit, overlay: panel.windowNumber))
                    }
                }
            }
            let seconds = Int(Date().timeIntervalSince(started))
            log.notice("TANDEM-AUDIT report seconds=\(seconds, privacy: .public) frontBefore=\(self.frontBefore ?? "-", privacy: .public) frontNow=\(front, privacy: .public) appsActivated=\(self.frontmostChanges, privacy: .public) tandemBecameActive=\(self.tandemActivations, privacy: .public) tandemActiveNow=\(NSApp.isActive, privacy: .public) keyOrMainWindows=\(self.keyOrMain, privacy: .public)")
            log.notice("TANDEM-AUDIT overlay visible=\(panel?.isVisible ?? false, privacy: .public) key=\(panel?.isKeyWindow ?? false, privacy: .public) main=\(panel?.isMainWindow ?? false, privacy: .public) ignoresMouse=\(panel?.ignoresMouseEvents ?? false, privacy: .public) level=\(panel?.level.rawValue ?? -1, privacy: .public) frame=\(String(describing: panel?.frame), privacy: .public)")
            log.notice("TANDEM-AUDIT clicksGoTo=\(clicksGoTo, privacy: .public) overlayDrawnAboveThatWindow=\(drawnOnTop, privacy: .public)")
        }

        private static func owner(of windowNumber: Int) -> String {
            guard windowNumber > 0,
                  let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first
            else { return "none(\(windowNumber))" }
            return info[kCGWindowOwnerName as String] as? String ?? "?"
        }

        /// Whether the overlay is drawn above the window a click at that spot reaches.
        private static func overlayIsAbove(_ windowNumber: Int, overlay: Int) -> String {
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "?" }
            // Front to back.
            let order = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
            guard let overlayIndex = order.firstIndex(of: overlay) else { return "overlay-not-on-screen" }
            guard let clickedIndex = order.firstIndex(of: windowNumber) else { return "desktop" }
            return overlayIndex < clickedIndex ? "above" : "BELOW"
        }
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
        lines.append("source.screenPermission=\(source.hasScreenPermission) preflight=\(CGPreflightScreenCaptureAccess())")
        lines.append("source.audio=\(source.audioState) listeners=\(source.audioListenerIDs.count) requests=\(source.viewers.map { String(describing: $0.audioRequest) })")
        lines.append("chat.threads=\(model.chat.threads.count) streaming=\(model.chat.streaming != nil) banner=\(model.chat.banner ?? "-")")
        lines.append("chat.pictures=\(model.chat.composerAttachments.map { "\($0.id):\($0.attachment.pixelWidth)x\($0.attachment.pixelHeight):\($0.attachment.capturedAt.timeIntervalSince1970)" }) use=\(model.chat.useSelectedPictures)")
        lines.append("studio.regionTool=\(studio.isRegionToolOn) drag=\(studio.regionDrag.map { "\($0.id):\(Int($0.frameSize.width))x\(Int($0.frameSize.height)):preview=\($0.preview != nil)" } ?? "-") cropsInFlight=\(studio.regionCropsInFlight) capturing=\(studio.isCapturing)")
        lines.append("auto=\(model.settings.autoCaptureEnabled) last=\(studio.lastAutoResult ?? "-")")
        lines.append("studio.glance=\(studio.glance.debugDescription)")
        lines.append("hotkeys=\(HotkeyAction.allCases.filter { HotKeyCenter.shared.isRegistered($0.id) }.map(\.rawValue)) failed=\(model.hotkeys.errors.map { "\($0.key.rawValue): \($0.value)" })")
        lines.append("source.glance=window=\(source.glance.windowNumber) onScreen=\(source.glance.isOnScreen) hiddenHere=\(source.glance.isHiddenHere) from=\(source.glance.senderName ?? "-") rev=\(source.glance.document.revision) chars=\(source.glance.document.text.count) streaming=\(source.glance.document.isStreaming) layout=\(source.glance.layout) status=\(source.glance.status(for: nil))")
        lines.append("network.blocked=\(model.connections.localNetworkBlocked) failure=\(model.connections.lastFailure?.message ?? "-")")
        // Logged (not written to the container) so tools can read it without
        // triggering the "access data from other apps" privacy prompt.
        let logger = Logger(subsystem: "com.rofel.tandem", category: "Debug")
        let profile = AppEnvironment.profile ?? "default"
        for line in lines { logger.notice("TANDEM-STATE[\(profile, privacy: .public)] \(line, privacy: .public)") }
    }
}
#endif
