import AppKit
import Observation
import os
import TandemCore

enum SnapshotRequestError: Error, LocalizedError {
    case notConnected
    case sourceUnavailable(String)
    case timedOut
    case failed(String)
    case unchanged

    var errorDescription: String? {
        switch self {
        case .notConnected: return "No shared Mac is connected."
        case .sourceUnavailable(let reason): return reason
        case .timedOut: return "The shared Mac didn't send a screenshot in time."
        case .failed(let reason): return reason
        case .unchanged: return "The screen hasn't changed."
        }
    }
}

/// The Studio Mac: live view, snapshots, automation, and the chat.
@MainActor
@Observable
final class StudioEngine {
    enum LiveState: Equatable {
        case noSource
        case connecting
        case waitingForVideo
        case live
        case sourcePaused(String)
        case sourceProblem(String)
        case previewOff
    }

    private(set) var connection: PeerConnection?
    private(set) var sourceStatus: SourceStatus?
    private(set) var remoteCatalog: [CaptureSourceDescriptor] = []
    private(set) var liveStats = LiveStats()
    private(set) var hasVideo = false
    private(set) var isCapturing = false
    /// Snapshots pushed from the Source that are waiting in the composer.
    private(set) var lastPushAt: Date?
    var livePreviewEnabled = true { didSet { sendStreamRequest() } }
    /// False while the Studio window is minimized/occluded, to save bandwidth.
    var isStageVisible = true { didSet { if oldValue != isStageVisible { sendStreamRequest() } } }

    // Automation
    private(set) var nextAutoCaptureAt: Date?
    private(set) var lastAutoResult: String?
    @ObservationIgnored private var autoAsks: [Date] = []

    let chat: ChatController
    @ObservationIgnored let renderer = LiveVideoRenderer()
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<ReceivedSnapshot, Error>] = [:]
    @ObservationIgnored private var automationTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Studio")

    init(settings: SettingsStore, keys: APIKeyStore) {
        self.settings = settings
        chat = ChatController(settings: settings, keys: keys)
        chat.studio = self
        renderer.onStats = { [weak self] stats in self?.liveStats = stats }
        renderer.onFirstFrame = { [weak self] in self?.hasVideo = true }
    }

    // MARK: Derived state

    var isConnected: Bool { connection?.isConnected ?? false }

    var sourceName: String? { connection?.peer?.name }

    var canCapture: Bool {
        guard isConnected, let status = sourceStatus else { return false }
        return status.state == .live || status.state == .starting
    }

    var liveState: LiveState {
        guard let connection, connection.isConnected else { return .noSource }
        guard let status = sourceStatus else { return .connecting }
        switch status.state {
        case .paused: return .sourcePaused(status.message ?? "Sharing is paused on the other Mac.")
        case .needsPermission: return .sourceProblem(status.message ?? "The other Mac needs Screen Recording permission.")
        case .error: return .sourceProblem(status.message ?? "The other Mac couldn't capture its screen.")
        case .live, .starting:
            if !livePreviewEnabled { return .previewOff }
            return hasVideo ? .live : .waitingForVideo
        }
    }

    // MARK: Connection lifecycle

    func attach(_ connection: PeerConnection) {
        guard connection.direction == .outgoing else { return }
        if let existing = self.connection, existing.id != connection.id { detach(existing) }
        self.connection = connection
        sourceStatus = nil
        hasVideo = false
        renderer.reset()
        let renderer = self.renderer
        let link = connection.link
        connection.videoSink.value = { message in renderer.handle(message, link: link) }
        connection.onControl = { [weak self] message in self?.handle(message) }
        connection.onSnapshot = { [weak self] snapshot in self?.received(snapshot) }
        connection.onSnapshotRejected = { [weak self] id, reason in
            self?.pending.removeValue(forKey: id)?.resume(throwing: SnapshotRequestError.failed(reason))
        }
        sendStreamRequest()
        sendAutomationStatus()
        connection.send(.control(.sourceCatalogRequest))
        restartAutomation()
    }

    func detach(_ connection: PeerConnection) {
        guard self.connection?.id == connection.id else { return }
        connection.videoSink.value = nil
        connection.onControl = nil
        connection.onSnapshot = nil
        self.connection = nil
        sourceStatus = nil
        remoteCatalog = []
        hasVideo = false
        liveStats = LiveStats()
        renderer.reset()
        for (_, continuation) in pending { continuation.resume(throwing: SnapshotRequestError.notConnected) }
        pending.removeAll()
        restartAutomation()
    }

    // MARK: Messages

    private func handle(_ message: ControlMessage) {
        switch message {
        case .sourceStatus(let status):
            let wasLive = sourceStatus?.state == .live
            sourceStatus = status
            if status.state != .live, status.state != .starting {
                hasVideo = false
                renderer.reset()
            } else if !wasLive {
                sendStreamRequest()
            }
        case .sourceCatalog(let catalog):
            remoteCatalog = catalog
        case .snapshotUnchanged(let id):
            pending.removeValue(forKey: id)?.resume(throwing: SnapshotRequestError.unchanged)
        case .snapshotFailed(let id, let reason):
            pending.removeValue(forKey: id)?.resume(throwing: SnapshotRequestError.failed(reason))
        default:
            break
        }
    }

    private func received(_ snapshot: ReceivedSnapshot) {
        if let continuation = pending.removeValue(forKey: snapshot.header.id) {
            continuation.resume(returning: snapshot)
            return
        }
        guard snapshot.header.trigger == .sourcePush else { return }
        lastPushAt = Date()
        NSApp.requestUserAttention(.informationalRequest)
        let note = snapshot.header.note
        switch settings.pushBehavior {
        case .askImmediately:
            let prompt = note?.isEmpty == false ? "" : settings.pushPrompt
            chat.ask(prompt: prompt, snapshot: snapshot, sourceName: sourceName, trigger: .sourcePush, sourceNote: note)
        case .attachToComposer:
            chat.addToComposer(snapshot, sourceName: sourceName)
            if let note, !note.isEmpty, chat.composerText.isEmpty { chat.composerText = note }
        }
    }

    // MARK: Requests

    func sendStreamRequest() {
        guard let connection, connection.isConnected else { return }
        let enabled = livePreviewEnabled && isStageVisible
        connection.send(.control(.streamRequest(StreamRequest(enabled: enabled, quality: settings.liveQuality.quality))))
        if !enabled {
            hasVideo = false
            renderer.reset()
        }
    }

    func selectRemoteSource(_ source: CaptureSourceID) {
        connection?.send(.control(.selectSource(source)))
        hasVideo = false
    }

    func refreshRemoteCatalog() {
        connection?.send(.control(.sourceCatalogRequest))
    }

    func mirror(_ reply: ReplyMirror) {
        guard let connection, connection.isConnected else { return }
        connection.send(.control(.replyMirror(reply)))
    }

    /// Asks the Source for a fresh still. Throws `SnapshotRequestError.unchanged`
    /// when `skipIfUnchangedBelow` is set and the screen didn't change.
    func requestSnapshot(trigger: SnapshotTrigger, skipIfUnchangedBelow: Double? = nil) async throws -> ReceivedSnapshot {
        guard let connection, connection.isConnected else { throw SnapshotRequestError.notConnected }
        if let status = sourceStatus, status.state != .live, status.state != .starting {
            throw SnapshotRequestError.sourceUnavailable(status.message ?? "The other Mac isn't sharing right now.")
        }
        let capabilities = ModelCatalog.capabilities(for: settings.currentModel, provider: settings.provider)
        let request = SnapshotRequest(
            trigger: trigger,
            maxDimension: min(capabilities.maxImageLongEdge, 2576),
            quality: 0.9,
            skipIfUnchangedBelow: skipIfUnchangedBelow
        )
        let timeout: Double = connection.linkKind.isConstrained ? 45 : 12
        isCapturing = true
        defer { isCapturing = !pending.isEmpty }
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            connection.send(.control(.snapshotRequest(request)))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.pending.removeValue(forKey: request.id)?.resume(throwing: SnapshotRequestError.timedOut)
            }
        }
    }

    /// Hotkey / button: capture now and ask using the composer text (or the default prompt).
    func captureAndAsk() {
        guard !chat.isBusy else { return }
        Task {
            do {
                let snapshot = try await requestSnapshot(trigger: .hotkey)
                let typed = chat.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = typed.isEmpty ? settings.pushPrompt : typed
                if !typed.isEmpty { chat.composerText = "" }
                chat.ask(prompt: prompt, snapshot: snapshot, sourceName: sourceName, trigger: .hotkey)
            } catch {
                chat.reportBanner("Couldn't capture: \(error.localizedDescription)")
            }
        }
    }

    /// Captures into the composer for the user to annotate and send.
    func captureToComposer() {
        Task {
            do {
                let snapshot = try await requestSnapshot(trigger: .manual)
                chat.addToComposer(snapshot, sourceName: sourceName)
            } catch {
                chat.reportBanner("Couldn't capture: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Automation

    func toggleAutoCapture() {
        settings.autoCaptureEnabled.toggle()
        restartAutomation()
    }

    /// Call after automation settings change.
    func restartAutomation() {
        automationTask?.cancel()
        automationTask = nil
        nextAutoCaptureAt = nil
        sendAutomationStatus()
        guard settings.autoCaptureEnabled, isConnected else { return }
        automationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = max(2, self.settings.autoCaptureInterval)
                self.nextAutoCaptureAt = Date().addingTimeInterval(interval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.autoCaptureTick()
            }
        }
    }

    private func autoCaptureTick() async {
        guard settings.autoCaptureEnabled, isConnected else { return }
        guard canCapture else {
            lastAutoResult = "Skipped — the other Mac isn't sharing"
            return
        }
        let asking = settings.autoAsk
        if asking, chat.isBusy {
            lastAutoResult = "Skipped — still answering"
            return
        }
        let hourAgo = Date().addingTimeInterval(-3600)
        autoAsks.removeAll { $0 < hourAgo }
        if asking, autoAsks.count >= settings.maxAutoAsksPerHour {
            lastAutoResult = "Paused — hourly limit of \(settings.maxAutoAsksPerHour) automatic questions reached"
            return
        }
        let threshold = settings.onlyWhenChanged ? settings.changeSensitivity.threshold : nil
        do {
            let snapshot = try await requestSnapshot(trigger: .interval, skipIfUnchangedBelow: threshold)
            if asking {
                autoAsks.append(Date())
                chat.ask(prompt: settings.autoPrompt, snapshot: snapshot, sourceName: sourceName, trigger: .interval)
                lastAutoResult = "Asked at \(Date().formatted(date: .omitted, time: .shortened))"
            } else {
                chat.addToComposer(snapshot, sourceName: sourceName, automatic: true)
                lastAutoResult = "Updated at \(Date().formatted(date: .omitted, time: .shortened))"
            }
        } catch SnapshotRequestError.unchanged {
            lastAutoResult = "No change at \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            lastAutoResult = "Skipped — \(error.localizedDescription)"
        }
    }

    func sendAutomationStatus() {
        guard let connection, connection.isConnected else { return }
        connection.send(.control(.automationStatus(AutomationStatus(
            autoCaptureEnabled: settings.autoCaptureEnabled,
            intervalSeconds: settings.autoCaptureInterval,
            asksAutomatically: settings.autoAsk
        ))))
    }
}
