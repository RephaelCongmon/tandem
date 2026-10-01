import Foundation
import Observation
import TandemCore

@MainActor @Observable
final class GlanceInjectController {
    var draft = ""
    var isPresented = false
    private(set) var layout = GlanceLayout()
    private(set) var scrollFraction = 0.0
    private(set) var status: GlanceStatus?
    private(set) var error: String?
    private var connectionID: UUID?
    private var supported = false
    private var available = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var hasPendingUpdate = false
    @ObservationIgnored var send: (GlanceCommand) -> Void
    init(send: @escaping (GlanceCommand) -> Void = { _ in }) { self.send = send }
    var canInject: Bool { connectionID != nil && supported && available && status?.enabled != false }
    var canManage: Bool { canInject && status?.isOwner == true && status?.hasContent == true }
    var availabilityMessage: String? {
        if connectionID == nil { return "Connect to your other Mac to inject text." }
        if !supported { return "Update Tandem on the shared Mac to use Glance Inject." }
        if !available { return "Resume sharing on the other Mac to use Glance Inject." }
        if status?.enabled == false { return status?.error ?? "Glance Inject is disabled on the shared Mac." }
        return nil
    }
    func configure(connectionID: UUID?, supported: Bool, available: Bool) {
        let changed = self.connectionID != connectionID
        let query = connectionID != nil && supported && (changed || !self.supported || (!self.available && available))
        if changed || !available {
            cancelPending()
            status = nil
            scrollFraction = 0
            error = nil
            if changed { revision = 0 }
        }
        self.connectionID = connectionID
        self.supported = supported
        self.available = available
        if query && canInject { sendCommand { .init(revision: $0) } }
    }
    func inject(_ text: String, title: String = "Injected text") {
        guard canInject else { error = availabilityMessage; return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Paste some text to inject."; return }
        guard text.utf8.count <= GlanceContent.maximumBytes else { error = "Glance text must be 64 KiB or less."; return }
        cancelPending()
        error = nil
        scrollFraction = 0
        isPresented = true
        sendCommand { .init(revision: $0, content: .init(text: text, title: String(title.prefix(128))), layout: layout, visible: true, scrollFraction: 0) }
    }
    func receive(_ status: GlanceStatus) {
        if let error = status.error { self.error = error }
        if status.isOwner && status.revision < revision { return }
        self.status = status
        if status.isOwner { revision = max(revision, status.revision) }
        if !hasPendingUpdate {
            layout = status.layout
            scrollFraction = status.scrollFraction
        }
        if !status.isOwner { cancelPending() }
    }
    func updateLayout(_ layout: GlanceLayout) {
        guard canManage, layout.isFinite else { return }
        self.layout = layout.bounded
        scheduleUpdate()
    }
    func scrollBy(_ points: Double) {
        guard let maximum = status?.maxScrollPoints, maximum > 0 else { return }
        setScroll(scrollFraction + points / maximum)
    }
    func setScroll(_ fraction: Double) {
        guard canManage, fraction.isFinite else { return }
        scrollFraction = min(1, max(0, fraction))
        scheduleUpdate()
    }
    func setVisible(_ visible: Bool) {
        guard canManage else { return }
        flushUpdate()
        sendCommand { .init(revision: $0, visible: visible) }
    }
    func clear() {
        guard canManage else { return }
        cancelPending()
        sendCommand { .init(revision: $0, clear: true) }
    }
    private func sendCommand(_ make: (UInt64) -> GlanceCommand) {
        guard canInject else { return }
        revision += 1
        send(make(revision))
    }
    private func scheduleUpdate() {
        hasPendingUpdate = true
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 33_333_333) } catch { return }
            self?.flushUpdate()
        }
    }
    private func flushUpdate() {
        updateTask?.cancel()
        updateTask = nil
        guard hasPendingUpdate, canManage else { return }
        hasPendingUpdate = false
        sendCommand { .init(revision: $0, layout: layout, scrollFraction: scrollFraction) }
    }
    private func cancelPending() {
        updateTask?.cancel()
        updateTask = nil
        hasPendingUpdate = false
    }
}
