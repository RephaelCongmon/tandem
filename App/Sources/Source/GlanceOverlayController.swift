import AppKit
import Observation
import os
import SwiftUI
import TandemCore
import TandemUI

/// The Source's Glance: text from the Studio in a see-through overlay on this Mac's screen.
///
/// It's Glance's passive panel: borderless, never key, clicks pass through, on every Space
/// and over full-screen apps, and never captured (so the Studio's live view and the AI's
/// pictures don't include it). The Studio drives everything; the person here can hide it.
@MainActor
@Observable
final class GlanceOverlayController {
    private(set) var document = GlanceDocument()
    private(set) var layout = GlanceLayout(isVisible: false)
    /// Hidden by the person at this Mac; stays hidden until they show it again.
    private(set) var isHiddenHere = false
    /// The panel is on screen.
    private(set) var isOnScreen = false
    /// The Studio whose Glance this is.
    private(set) var senderName: String?

    /// There's something to show (an empty answer that's still being written counts).
    var hasGlance: Bool { document.id != nil && (!document.isEmpty || document.isStreaming) }

    /// Where the overlay goes: the shared display, else the screen with the shared window.
    @ObservationIgnored var placement: @MainActor () -> (screen: NSScreen, isSharedDisplay: Bool)? = {
        NSScreen.main.map { ($0, false) }
    }
    /// The panel exists; its window must be kept out of every capture.
    @ObservationIgnored var onWindowCreated: ((CGWindowID) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let model = GlanceOverlayModel()
    @ObservationIgnored private var panel: NSPanel?
    /// Studios that sent Glance messages on their current connection; they get status reports.
    @ObservationIgnored private var clients: [UUID: PeerConnection] = [:]
    /// Newest layout applied per connection (each Studio counts on its own).
    @ObservationIgnored private var sequences: [UUID: UInt64] = [:]
    @ObservationIgnored private var ownerID: UUID?
    @ObservationIgnored private var measured = (content: 0.0, viewport: 0.0)
    /// Connections whose append didn't fit what's held: they resend the whole text.
    @ObservationIgnored private var needsFullText: Set<UUID> = []
    @ObservationIgnored private var statusScheduled = false
    @ObservationIgnored private var appliedFrame = GlanceFrame.standard
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Glance")

    #if DEBUG
    /// The panel's window number (0 before it exists), for `dump`.
    var windowNumber: Int { panel?.windowNumber ?? 0 }
    #endif

    /// Smallest overlay, in points.
    static let minimumSize = CGSize(width: 220, height: 110)

    init(settings: SettingsStore) {
        self.settings = settings
        model.onMeasure = { [weak self] content, viewport in self?.measuredChanged(content: content, viewport: viewport) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placementChanged() }
        }
    }

    // MARK: From the Studio

    func receive(_ content: GlanceContent, from connection: PeerConnection) {
        register(connection)
        guard settings.allowGlance, !yields(to: connection, isResync: content.isResync) else { return scheduleStatus() }
        switch document.apply(content) {
        case .applied:
            needsFullText.remove(connection.id)
            adopt(connection)
            refresh(animated: false)
        case .stale:
            break
        case .needsFullText:
            needsFullText.insert(connection.id)
            log.info("Glance append didn't match revision \(self.document.revision); asking for the whole text")
        }
        scheduleStatus()
    }

    func receive(_ layout: GlanceLayout, from connection: PeerConnection) {
        register(connection)
        guard layout.sequence > sequences[connection.id] ?? 0 else { return }
        sequences[connection.id] = layout.sequence
        guard settings.allowGlance, !yields(to: connection, isResync: layout.isResync) else { return scheduleStatus() }
        self.layout = layout.sanitized
        adopt(connection)
        refresh(animated: layout.animated)
        if let sent = layout.sentAtNanos {
            // The Studio's clock, corrected by the link's measured offset (peer − local).
            let offset = connection.stats.clockOffsetNanos ?? 0
            let oneWay = Double(Int64(bitPattern: wallClockNanos()) - (Int64(bitPattern: sent) - offset)) / 1_000_000
            log.info("TANDEM-TIMING glance layout #\(layout.sequence) on screen \(oneWay, format: .fixed(precision: 1)) ms after the Studio sent it")
        }
        scheduleStatus()
    }

    /// A Studio's connection ended. Its Glance stays up (it's still useful, and the Studio
    /// reconnects after sleep or a network change); the header shows it's not connected.
    func connectionClosed(_ id: UUID) {
        clients[id] = nil
        sequences[id] = nil
        needsFullText.remove(id)
        if ownerID == id { refresh(animated: false) }
    }

    /// A Studio's session was approved here: anything it sent before was dropped, so tell it
    /// what's shown (it then resends its Glance).
    func viewerApproved(_ connection: PeerConnection) {
        register(connection)
        scheduleStatus()
    }

    /// Creates the (hidden) panel up front, so its window is known before any capture filter
    /// is built and is never in a frame, even when Tandem's own windows are shared.
    func prepare() {
        if panel == nil { _ = makePanel() }
    }

    // MARK: Here

    /// ⌃⌥G and the menu bar on this Mac.
    func toggleHiddenHere() {
        setHiddenHere(!isHiddenHere)
    }

    func setHiddenHere(_ hidden: Bool) {
        guard isHiddenHere != hidden else { return }
        isHiddenHere = hidden
        refresh(animated: false)
        scheduleStatus()
    }

    /// The Source's Glance setting changed.
    func allowedChanged() {
        if !settings.allowGlance {
            document.clear()
            senderName = nil
        }
        refresh(animated: false)
        scheduleStatus()
    }

    /// The shared display or window changed, or a display was added/removed/rearranged.
    func placementChanged() {
        refresh(animated: false)
        scheduleStatus()
    }

    /// Leaving the Source role.
    func teardown() {
        document.clear()
        layout = GlanceLayout(isVisible: false)
        clients.removeAll()
        sequences.removeAll()
        ownerID = nil
        senderName = nil
        isHiddenHere = false
        refresh(animated: false)
    }

    // MARK: Showing

    private func register(_ connection: PeerConnection) {
        guard clients[connection.id] == nil else { return }
        clients[connection.id] = connection
        scheduleStatus()
    }

    /// A Studio that's only catching up (just connected) doesn't replace a Glance another
    /// connected Studio is showing; the person there has to show something first.
    private func yields(to connection: PeerConnection, isResync: Bool?) -> Bool {
        guard isResync == true, let owner = ownerID, owner != connection.id, clients[owner] != nil else { return false }
        return hasGlance
    }

    private func adopt(_ connection: PeerConnection) {
        ownerID = connection.id
        if let name = connection.peer?.name { senderName = name }
    }

    private func refresh(animated: Bool) {
        let wanted = settings.allowGlance && !isHiddenHere && layout.isVisible && hasGlance
        guard wanted, let target = target() else {
            panel?.orderOut(nil)
            isOnScreen = false
            return
        }
        let panel = self.panel ?? makePanel()
        let content = GlanceOverlayContent(
            text: document.text,
            title: document.title,
            origin: document.origin,
            isStreaming: document.isStreaming,
            from: senderName,
            isDisconnected: ownerID.map { clients[$0] == nil } ?? true
        )
        let hint = settings.combo(for: .toggleGlance).map { "\($0.displayString) hides this · only you can see it" }
            ?? "Hide it from Tandem in the menu bar · only you can see it"
        let layout = self.layout
        let apply = { [model] in
            if model.content != content { model.content = content }
            model.scrollOffset = layout.scrollOffset
            model.backgroundOpacity = layout.backgroundOpacity
            model.textScale = layout.textScale
            model.hint = hint
        }
        if animated {
            withAnimation(.easeOut(duration: 0.22), apply)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, apply)
        }

        let screen = target.screen.frame
        let visible = GlanceFrame(rect: target.screen.visibleFrame, in: screen)
        appliedFrame = layout.frame.clamped(
            to: visible,
            minWidth: Self.minimumSize.width / screen.width,
            minHeight: Self.minimumSize.height / screen.height
        )
        let rect = appliedFrame.rect(in: screen).integral
        if panel.frame != rect {
            if animated, panel.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(rect, display: true)
                }
            } else {
                panel.setFrame(rect, display: true)
            }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        isOnScreen = true
    }

    private func makePanel() -> NSPanel {
        let panel = GlanceOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A hint for other apps' captures (not a guarantee); Tandem's own capture leaves the
        // window out entirely (`CaptureService.alwaysExcludedWindowIDs`).
        panel.sharingType = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "Glance"
        let host = NSHostingView(rootView: GlanceOverlayHost(model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        if panel.windowNumber > 0 { onWindowCreated?(CGWindowID(panel.windowNumber)) }
        return panel
    }

    // MARK: Status

    private func measuredChanged(content: Double, viewport: Double) {
        guard abs(content - measured.content) > 0.5 || abs(viewport - measured.viewport) > 0.5 else { return }
        measured = (content, viewport)
        scheduleStatus()
    }

    /// One report per run-loop turn, however many messages arrived in it.
    private func scheduleStatus() {
        guard !statusScheduled else { return }
        statusScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.statusScheduled = false
                self?.sendStatus()
            }
        }
    }

    private func sendStatus() {
        for connection in clients.values where connection.isConnected {
            connection.send(.control(.glanceStatus(status(for: connection.id))))
        }
    }

    func status(for connectionID: UUID?) -> GlanceStatus {
        let screen: GlanceScreen
        if let target = target() {
            let frame = target.screen.frame
            screen = GlanceScreen(
                width: frame.width,
                height: frame.height,
                visibleFrame: GlanceFrame(rect: target.screen.visibleFrame, in: frame),
                isSharedDisplay: target.isSharedDisplay,
                displayID: target.screen.displayID.map(String.init)
            )
        } else {
            screen = GlanceScreen(width: 1440, height: 900, visibleFrame: .unit, isSharedDisplay: false)
        }
        let isFromYou = document.id == nil || ownerID == nil || ownerID == connectionID
        let state: GlanceStatus.State = !settings.allowGlance ? .notAllowed
            : isHiddenHere ? .hiddenOnSource
            : isOnScreen ? .showing : .hidden
        let offset = measured.viewport > 0
            ? GlanceScroll.clamp(layout.scrollOffset, content: measured.content, viewport: measured.viewport)
            : layout.scrollOffset
        return GlanceStatus(
            state: state,
            documentID: document.id,
            revision: document.revision,
            needsFullText: connectionID.map { needsFullText.contains($0) } ?? false,
            isFromYou: isFromYou,
            layoutSequence: connectionID.flatMap { sequences[$0] } ?? 0,
            frame: appliedFrame,
            scrollOffset: offset,
            contentHeight: measured.content,
            viewportHeight: measured.viewport,
            screen: screen,
            displays: displays
        )
    }

    /// The display the Studio chose, if it's still connected; else where `placement` puts it.
    private func target() -> (screen: NSScreen, isSharedDisplay: Bool)? {
        let shared = placement()
        guard let id = layout.displayID, let chosen = NSScreen.screens.first(where: { $0.displayID.map(String.init) == id }) else {
            return shared
        }
        let isShared = shared?.isSharedDisplay == true && shared?.screen.displayID == chosen.displayID
        return (chosen, isShared)
    }

    /// This Mac's displays, for the Studio's display menu.
    private var displays: [GlanceDisplay] {
        let shared = placement()
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let isShared = shared?.isSharedDisplay == true && shared?.screen.displayID == id
            return GlanceDisplay(id: String(id), name: screen.localizedName, isShared: isShared)
        }
    }

    // MARK: Where

    /// The shared display; the screen with most of the shared window; or the main screen.
    static func screen(for capture: CaptureSourceDescriptor?) -> (screen: NSScreen, isSharedDisplay: Bool)? {
        let screens = NSScreen.screens
        guard let main = NSScreen.main ?? screens.first else { return nil }
        guard let capture else { return (main, false) }
        switch capture.source.kind {
        case .display:
            #if DEBUG
            // The synthetic pattern stands in for the main display in QA.
            if capture.source == TestPatternGenerator.sourceID { return (main, true) }
            #endif
            if let id = UInt32(capture.source.id), let screen = screens.first(where: { $0.displayID == id }) {
                return (screen, true)
            }
            return (main, false)
        case .window:
            guard let id = UInt32(capture.source.id),
                  let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]])?.first,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return (main, false) }
            // Window bounds are top-left based on the primary display; screens are bottom-left based.
            let primaryHeight = screens.first?.frame.height ?? main.frame.height
            let center = CGPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
            return (screens.first { $0.frame.contains(center) } ?? main, false)
        case .camera:
            return (main, false)
        }
    }
}

/// What the panel's SwiftUI view reads.
@MainActor
@Observable
private final class GlanceOverlayModel {
    var content = GlanceOverlayContent.empty
    var scrollOffset: Double = 0
    var backgroundOpacity = GlanceLayout.defaultOpacity
    var textScale: Double = 1
    var hint: String?
    @ObservationIgnored var onMeasure: ((Double, Double) -> Void)?
}

private struct GlanceOverlayHost: View {
    let model: GlanceOverlayModel

    var body: some View {
        GlanceOverlayView(
            content: model.content,
            scrollOffset: model.scrollOffset,
            backgroundOpacity: model.backgroundOpacity,
            textScale: model.textScale,
            hint: model.hint,
            onMeasure: { model.onMeasure?($0, $1) }
        )
    }
}

/// Never key or main, so the app in use keeps the keyboard (Glance's passive mode).
private final class GlanceOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
