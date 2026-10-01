import AppKit
import Observation
import os
import TandemCore

/// The Glance a Studio last showed (restored when Tandem starts).
struct SavedGlance: Codable, Equatable {
    var text: String
    var title: String?
    var origin: GlanceContent.Origin
    var scrollOffset: Double
    var isVisible: Bool
}

/// The Studio's side of Glance: puts text (a note typed or pasted here, or an AI answer) in
/// a see-through overlay on the shared Mac's screen, and moves and scrolls it in real time.
///
/// The Studio owns the state. Text goes out as `GlanceContent` (answers stream as appends);
/// placement and scrolling go out as `GlanceLayout`, at most 60 a second, newest wins. The
/// Source answers each with `GlanceStatus`: the geometry it applied and measured, which the
/// controls clamp against and which times the round trip.
@MainActor
@Observable
final class GlanceInjector {
    enum ScrollAction {
        case lineUp, lineDown, pageUp, pageDown, top, bottom
    }

    /// The Glance tool on the live view: the stand-in you drag and scroll, and the controls.
    private(set) var isToolOn = false
    /// The text field.
    var draft = "" { didSet { if liveTyping, draft != oldValue { showDraft() } } }
    /// Send the text field as it's typed.
    var liveTyping: Bool {
        get { settings.glanceLiveTyping }
        set { settings.glanceLiveTyping = newValue; if newValue, !draft.isEmpty { showDraft() } }
    }
    /// Show each new AI answer as it's written.
    var followAnswers: Bool {
        get { settings.glanceFollowAnswers }
        set { settings.glanceFollowAnswers = newValue }
    }
    /// What the overlay shows, as the stand-in draws it.
    private(set) var content = GlanceOverlayContent.empty
    /// Where the overlay should be, how it's scrolled and how it looks.
    private(set) var layout: GlanceLayout
    /// The Source's latest report.
    private(set) var remote: GlanceStatus?
    /// From sending a layout to the Source's report that it's applied.
    private(set) var roundTripMillis: Double?
    /// The answer being followed as it streams.
    private(set) var followedMessageID: UUID?
    /// Recent round trips, newest last (for the debug benchmark).
    @ObservationIgnored private(set) var roundTripSamples: [Double] = []

    var hasContent: Bool { !content.text.isEmpty || content.isStreaming }
    /// There's a Glance now, or there isn't anymore (its shortcuts are only taken while there is).
    @ObservationIgnored var onHasContentChanged: ((Bool) -> Void)?
    var isShowingOnSource: Bool { remote?.state == .showing }

    @ObservationIgnored weak var chat: ChatController?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var connection: PeerConnection?
    @ObservationIgnored private var outbox = GlanceOutbox()
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var lastLayoutSend = -Double.infinity
    @ObservationIgnored private var layoutFlush: Task<Void, Never>?
    @ObservationIgnored private var layoutPending = false
    @ObservationIgnored private var sentAt: [UInt64: Double] = [:]
    @ObservationIgnored private var lastResync = -Double.infinity
    @ObservationIgnored private var resyncCheck: Task<Void, Never>?
    /// The last answer that finished; late updates for it are ignored.
    @ObservationIgnored private var finishedMessageID: UUID?
    @ObservationIgnored private var liveDraftDocument: UUID?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Glance")

    /// The fastest layout updates go out: a display refresh, or 15 a second over Bluetooth.
    static let layoutInterval = 1.0 / 60
    static let constrainedLayoutInterval = 1.0 / 15

    init(settings: SettingsStore) {
        self.settings = settings
        layout = GlanceLayout(
            isVisible: true,
            frame: settings.glanceFrame,
            backgroundOpacity: settings.glanceOpacity,
            textScale: settings.glanceTextScale,
            displayID: settings.glanceDisplayID
        ).sanitized
        if let saved = settings.glanceDocument, !saved.text.isEmpty {
            // A fresh document with the same text: the Source replaces whatever it holds.
            content = GlanceOverlayContent(text: saved.text, title: saved.title, origin: saved.origin, isStreaming: false)
            _ = outbox.update(text: saved.text, title: saved.title, origin: saved.origin, isStreaming: false)
            layout.scrollOffset = max(0, saved.scrollOffset)
            layout.isVisible = saved.isVisible
        }
    }

    // MARK: Connection

    func attach(_ connection: PeerConnection) {
        self.connection = connection
        remote = nil
        roundTripMillis = nil
        sentAt.removeAll()
        lastResync = monotonicSeconds()
        // A new connection: the Source holds nothing of ours, or an old copy. (The layout
        // sequence keeps counting; the Source counts per connection anyway.)
        if let message = outbox.resync() { connection.send(.control(.glanceContent(message))) }
        // Also introduces this Studio, so the Source reports its screen for the stand-in.
        sendLayoutNow(isResync: true)
    }

    func detach(_ connection: PeerConnection) {
        guard self.connection === connection else { return }
        self.connection = nil
        remote = nil
        resyncCheck?.cancel()
        layoutFlush?.cancel()
        layoutFlush = nil
        layoutPending = false
    }

    func handle(_ status: GlanceStatus) {
        let screenChanged = remote?.screen != status.screen
        remote = status
        if screenChanged {
            // Until now the frame was kept on a guessed screen: keep it on the real one.
            let bounds = self.bounds
            let clamped = layout.frame.clamped(to: bounds.visible, minWidth: bounds.minWidth, minHeight: bounds.minHeight)
            if clamped != layout.frame {
                layout.frame = clamped
                scheduleLayout(animated: false)
            }
        }
        if let sent = sentAt.removeValue(forKey: status.layoutSequence) {
            let millis = (monotonicSeconds() - sent) * 1000
            roundTripMillis = roundTripMillis.map { $0 * 0.7 + millis * 0.3 } ?? millis
            roundTripSamples.append(millis)
            if roundTripSamples.count > 1000 { roundTripSamples.removeFirst(roundTripSamples.count - 1000) }
            log.info("TANDEM-TIMING glance layout #\(status.layoutSequence) round trip \(millis, format: .fixed(precision: 1)) ms")
        }
        sentAt = sentAt.filter { $0.key > status.layoutSequence }
        // The Source lost part of the text (an append didn't fit), or holds none of it (Glance
        // was off there, or this session wasn't approved yet): send it all again, with the
        // layout. At most once a second, so a Source that can't keep it never causes a loop.
        resyncIfNeeded()
    }

    private func resyncIfNeeded() {
        guard let status = remote else { return }
        let missing = status.documentID == nil && hasContent && status.state != .notAllowed
        guard status.needsFullText || missing else { return }
        let wait = 1 - (monotonicSeconds() - lastResync)
        guard wait <= 0 else {
            // Check again once the second is up, in case no other report comes.
            resyncCheck?.cancel()
            resyncCheck = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 10_000_000)
                guard !Task.isCancelled else { return }
                self?.resyncIfNeeded()
            }
            return
        }
        guard let message = outbox.resync() else { return }
        lastResync = monotonicSeconds()
        send(message)
        sendLayoutNow(isResync: true)
    }

    /// Why Glance can't be used right now, if it can't.
    var problem: String? {
        guard let connection, connection.isConnected else { return "Connect to the shared Mac to use Glance." }
        if connection.remoteHello != nil, !connection.peerSupportsGlance {
            return "Update Tandem on \(connection.peer?.name ?? "the shared Mac") to show Glances there."
        }
        if let remote, !remote.isFromYou, remote.documentID != nil {
            return "Another Mac's Glance is showing on \(connection.peer?.name ?? "the shared Mac"). Show something to replace it."
        }
        switch remote?.state {
        case .notAllowed: return "Glance is turned off on \(connection.peer?.name ?? "the shared Mac") (its Settings › Sharing)."
        case .hiddenOnSource: return "Hidden on \(connection.peer?.name ?? "the shared Mac") by the person using it."
        default: return nil
        }
    }

    // MARK: Tool

    func toggleTool() { setTool(!isToolOn) }

    func setTool(_ on: Bool) {
        guard on != isToolOn else { return }
        if on, let connection, connection.remoteHello != nil, !connection.peerSupportsGlance {
            chat?.reportBanner(problem ?? "Update Tandem on the shared Mac to use Glance.")
            return
        }
        isToolOn = on
    }

    // MARK: Text

    /// Shows the text field's contents.
    func showDraft() {
        let text = draft
        if liveDraftDocument != outbox.documentID || followedMessageID != nil {
            startDocument()
            liveDraftDocument = outbox.documentID
        }
        update(text: text, title: nil, origin: .note, isStreaming: false)
        if !layout.isVisible { setVisible(true) }
    }

    /// Shows `text` from the top, replacing whatever was showing.
    func show(_ text: String, title: String?, origin: GlanceContent.Origin) {
        startDocument()
        update(text: text, title: title, origin: origin, isStreaming: false)
        setVisible(true)
    }

    func showAnswer(_ message: ChatMessage) {
        show(message.text, title: question(before: message.id, in: chat?.threads.first { $0.messages.contains { $0.id == message.id } }), origin: .answer)
    }

    /// The newest answer: the one being written, else the last one in the thread.
    func showLatestAnswer() {
        if let streaming = chat?.streaming {
            follow(streaming)
        } else if let message = chat?.selectedThread?.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
            showAnswer(message)
        } else {
            chat?.reportBanner("There's no answer to show yet.")
        }
    }

    /// The chat's streaming answer changed (called ~30 times a second while it's written).
    func answerUpdated(_ reply: StreamingReply, isFinal: Bool) {
        // A flush that lands after the answer finished mustn't start it over.
        if !isFinal, reply.messageID == finishedMessageID { return }
        guard followAnswers || followedMessageID == reply.messageID else { return }
        follow(reply, isFinal: isFinal)
    }

    private func follow(_ reply: StreamingReply, isFinal: Bool = false) {
        if followedMessageID != reply.messageID {
            startDocument()
            followedMessageID = reply.messageID
            setVisible(true)
        }
        let thread = chat?.threads.first { $0.id == reply.threadID }
        update(text: reply.text, title: question(before: reply.messageID, in: thread), origin: .answer, isStreaming: !isFinal)
        if isFinal {
            followedMessageID = nil
            finishedMessageID = reply.messageID
        }
    }

    /// Takes the text off the shared Mac's screen.
    func clear() {
        startDocument()
        update(text: "", title: nil, origin: .note, isStreaming: false)
    }

    private func startDocument() {
        outbox.startDocument()
        followedMessageID = nil
        liveDraftDocument = nil
        // New text starts at the top.
        layout.scrollOffset = 0
        scheduleLayout(animated: false)
    }

    private func update(text: String, title: String?, origin: GlanceContent.Origin, isStreaming: Bool) {
        let had = hasContent
        content = GlanceOverlayContent(text: text, title: title, origin: origin, isStreaming: isStreaming)
        if hasContent != had { onHasContentChanged?(hasContent) }
        if let message = outbox.update(text: text, title: title, origin: origin, isStreaming: isStreaming) {
            send(message)
        }
        save()
    }

    private func send(_ message: GlanceContent) {
        guard let connection, connection.isConnected else { return }
        connection.send(.control(.glanceContent(message)))
    }

    private func question(before messageID: UUID, in thread: ChatThread?) -> String? {
        guard let messages = thread?.messages, let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        guard let question = messages[..<index].last(where: { $0.role == .user })?.text else { return nil }
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }

    // MARK: Visibility & look

    func toggleVisible() { setVisible(!layout.isVisible) }

    func setVisible(_ visible: Bool) {
        guard layout.isVisible != visible else { return }
        layout.isVisible = visible
        scheduleLayout(animated: false)
        save()
    }

    func setOpacity(_ opacity: Double) {
        layout.backgroundOpacity = min(max(opacity, GlanceLayout.opacityRange.lowerBound), GlanceLayout.opacityRange.upperBound)
        scheduleLayout(animated: false)
        save()
    }

    func setTextScale(_ scale: Double) {
        let scale = min(max(scale, GlanceLayout.textScaleRange.lowerBound), GlanceLayout.textScaleRange.upperBound)
        // Keep the same part of the text in view.
        layout.scrollOffset *= scale / layout.textScale
        layout.textScale = scale
        scheduleLayout(animated: true)
        save()
    }

    func stepTextScale(_ steps: Int) {
        setTextScale(((layout.textScale + Double(steps) * 0.1) * 10).rounded() / 10)
    }

    // MARK: Scrolling

    /// Heights in the Source's points: measured there, or a guess until it reports.
    private var viewportHeight: Double {
        if let remote, remote.viewportHeight > 0 { return remote.viewportHeight }
        return layout.frame.height * (remote?.screen.height ?? 900) - 70
    }

    private var maxScrollOffset: Double { remote?.maxScrollOffset ?? .infinity }

    func scroll(_ action: ScrollAction) {
        let viewport = viewportHeight
        let current = min(layout.scrollOffset, maxScrollOffset)
        let target: Double
        switch action {
        case .lineUp: target = current - GlanceScroll.lineStep(viewport: viewport)
        case .lineDown: target = current + GlanceScroll.lineStep(viewport: viewport)
        case .pageUp: target = current - GlanceScroll.pageStep(viewport: viewport)
        case .pageDown: target = current + GlanceScroll.pageStep(viewport: viewport)
        case .top: target = 0
        case .bottom: target = maxScrollOffset.isFinite ? maxScrollOffset : current + GlanceScroll.pageStep(viewport: viewport) * 4
        }
        setScrollOffset(target, animated: true)
    }

    /// A trackpad or wheel scroll, in the Source's points (positive = further down the text).
    func scroll(by delta: Double) {
        setScrollOffset(min(layout.scrollOffset, maxScrollOffset) + delta, animated: false)
    }

    func setScrollOffset(_ offset: Double, animated: Bool) {
        let clamped = min(max(0, offset.isFinite ? offset : 0), maxScrollOffset)
        guard clamped != layout.scrollOffset else { return }
        layout.scrollOffset = clamped
        scheduleLayout(animated: animated)
        save()
    }

    /// 0…1 down the text.
    var scrollFraction: Double {
        guard maxScrollOffset.isFinite, maxScrollOffset > 0 else { return 0 }
        return min(1, layout.scrollOffset / maxScrollOffset)
    }

    // MARK: Placement

    /// The usable part of the Source's screen and the overlay's minimum size, as fractions.
    private var bounds: (visible: GlanceFrame, minWidth: Double, minHeight: Double) {
        let screen = remote?.screen
        return (
            screen?.visibleFrame ?? .unit,
            GlanceOverlayController.minimumSize.width / (screen?.width ?? 1440),
            GlanceOverlayController.minimumSize.height / (screen?.height ?? 900)
        )
    }

    /// Moves or resizes the overlay to `frame` (fractions of the Source's screen).
    func setFrame(_ frame: GlanceFrame, animated: Bool) {
        let bounds = self.bounds
        let clamped = frame.clamped(to: bounds.visible, minWidth: bounds.minWidth, minHeight: bounds.minHeight)
        guard clamped != layout.frame else { return }
        layout.frame = clamped
        scheduleLayout(animated: animated)
        save()
    }

    /// A drag on the resize handle: the top-left corner stays, and the size stops at the
    /// screen's edge (rather than pushing the overlay along).
    func resize(from start: GlanceFrame, dx: Double, dy: Double) {
        let visible = bounds.visible
        var frame = start
        frame.width = min(start.width + dx, visible.maxX - start.x)
        frame.height = min(start.height + dy, visible.maxY - start.y)
        setFrame(frame, animated: false)
    }

    /// The shared Mac's displays, when it has more than one.
    var displays: [GlanceDisplay] { (remote?.displays.count ?? 0) > 1 ? remote?.displays ?? [] : [] }

    /// Puts the overlay on one of the shared Mac's displays (nil: whichever is shared). It keeps
    /// its place relative to the screen.
    func setDisplay(_ id: String?) {
        guard layout.displayID != id else { return }
        layout.displayID = id
        settings.glanceDisplayID = id
        scheduleLayout(animated: false)
    }

    func place(_ placement: GlancePlacement) {
        setFrame(layout.frame.placed(placement, in: bounds.visible), animated: true)
    }

    /// Size presets: a fraction of the usable screen.
    func resize(widthFraction: Double, heightFraction: Double) {
        let visible = bounds.visible
        var frame = layout.frame
        let centerX = frame.x + frame.width / 2
        frame.width = visible.width * widthFraction
        frame.height = visible.height * heightFraction
        frame.x = centerX - frame.width / 2
        setFrame(frame, animated: true)
    }

    // MARK: Sending layouts

    /// Sends the layout now if the last one went out at least a frame ago, else at the end
    /// of that frame (only the newest state goes).
    private func scheduleLayout(animated: Bool) {
        layout.animated = animated
        layoutPending = true
        let interval = connection?.linkKind.isConstrained == true ? Self.constrainedLayoutInterval : Self.layoutInterval
        let wait = interval - (monotonicSeconds() - lastLayoutSend)
        if wait <= 0 {
            sendLayoutNow()
        } else if layoutFlush == nil {
            layoutFlush = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.layoutFlush = nil
                self?.sendLayoutNow()
            }
        }
    }

    private func sendLayoutNow(isResync: Bool = false) {
        layoutPending = false
        guard let connection, connection.isConnected else { return }
        sequence += 1
        var message = layout
        message.sequence = sequence
        message.sentAtNanos = wallClockNanos()
        message.isResync = isResync ? true : nil
        let now = monotonicSeconds()
        sentAt[sequence] = now
        if sentAt.count > 240 { sentAt = sentAt.filter { $0.key > sequence - 120 } }
        lastLayoutSend = now
        connection.send(.control(.glanceLayout(message)))
    }

    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.settings.glanceFrame = self.layout.frame
            self.settings.glanceOpacity = self.layout.backgroundOpacity
            self.settings.glanceTextScale = self.layout.textScale
            let saved = self.content.text.isEmpty ? nil : SavedGlance(
                text: self.content.text, title: self.content.title, origin: self.content.origin,
                scrollOffset: self.layout.scrollOffset, isVisible: self.layout.isVisible
            )
            if self.settings.glanceDocument != saved { self.settings.glanceDocument = saved }
        }
    }

    #if DEBUG
    /// Debug state for `dump`.
    var debugDescription: String {
        "tool=\(isToolOn) visible=\(layout.isVisible) doc=\(outbox.documentID.uuidString.prefix(8)) rev=\(outbox.revision) chars=\(content.text.count) streaming=\(content.isStreaming) frame=\(layout.frame) scroll=\(layout.scrollOffset) seq=\(sequence) remote=\(remote.map { "\($0.state.rawValue) rev=\($0.revision) seq=\($0.layoutSequence) scroll=\($0.scrollOffset)/\($0.maxScrollOffset) content=\($0.contentHeight) viewport=\($0.viewportHeight) screen=\($0.screen.width)x\($0.screen.height) shared=\($0.screen.isSharedDisplay) frame=\($0.frame)" } ?? "-") rtt=\(roundTripMillis ?? -1)"
    }
    #endif
}
