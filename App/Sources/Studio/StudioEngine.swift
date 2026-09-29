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
    var isStageVisible = true { didSet { if oldValue != isStageVisible { scheduleStreamRequest() } } }
    /// How many live-view stages are mounted (0 when the stage panel is hidden).
    @ObservationIgnored private var stageMounts = 0
    @ObservationIgnored private var streamRequestTask: Task<Void, Never>?

    // Automation
    private(set) var nextAutoCaptureAt: Date?
    private(set) var lastAutoResult: String?
    @ObservationIgnored private var autoAsks: [Date] = []

    let chat: ChatController
    @ObservationIgnored let renderer = LiveVideoRenderer()
    @ObservationIgnored private let settings: SettingsStore
    private struct PendingSnapshot {
        let continuation: CheckedContinuation<ReceivedSnapshot, Error>
        var deadline: Date
        let idleTimeout: Double
        var watchdog: Task<Void, Never>?
    }

    @ObservationIgnored private var pending: [UUID: PendingSnapshot] = [:]
    @ObservationIgnored private var automationTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Studio")

    init(settings: SettingsStore, keys: APIKeyStore, claudeCodeExecutable: @escaping @MainActor () -> URL? = { nil }) {
        self.settings = settings
        chat = ChatController(settings: settings, keys: keys, claudeCodeExecutable: claudeCodeExecutable)
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
            self?.resolve(id, with: .failure(SnapshotRequestError.failed(reason)))
        }
        connection.onSnapshotProgress = { [weak self] progress in
            // Data is still arriving: a slow (e.g. Bluetooth) transfer isn't a timeout.
            guard let self, var entry = self.pending[progress.id] else { return }
            entry.deadline = Date().addingTimeInterval(entry.idleTimeout)
            self.pending[progress.id] = entry
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
        connection.onSnapshotProgress = nil
        connection.onSnapshotRejected = nil
        self.connection = nil
        sourceStatus = nil
        remoteCatalog = []
        hasVideo = false
        liveStats = LiveStats()
        renderer.reset()
        for id in Array(pending.keys) { resolve(id, with: .failure(SnapshotRequestError.notConnected)) }
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
            resolve(id, with: .failure(SnapshotRequestError.unchanged))
        case .snapshotFailed(let id, let reason):
            resolve(id, with: .failure(SnapshotRequestError.failed(reason)))
        default:
            break
        }
    }

    private func received(_ snapshot: ReceivedSnapshot) {
        if pending[snapshot.header.id] != nil {
            resolve(snapshot.header.id, with: .success(snapshot))
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

    /// The stage view appeared/disappeared (e.g. panel hidden, focus mode swaps).
    func stageAppeared() {
        stageMounts += 1
        scheduleStreamRequest()
    }

    func stageDisappeared() {
        stageMounts = max(0, stageMounts - 1)
        scheduleStreamRequest()
    }

    /// Coalesces bursts of visibility changes into one request.
    private func scheduleStreamRequest() {
        streamRequestTask?.cancel()
        streamRequestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.sendStreamRequest()
        }
    }

    /// Stream only while someone can actually see it.
    var wantsLiveVideo: Bool { livePreviewEnabled && isStageVisible && stageMounts > 0 }

    func sendStreamRequest() {
        guard let connection, connection.isConnected else { return }
        let enabled = wantsLiveVideo
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
        // Idle timeout: extended whenever chunks arrive (see onSnapshotProgress).
        let timeout: Double = connection.linkKind.isConstrained ? 30 : 12
        isCapturing = true
        return try await withCheckedThrowingContinuation { continuation in
            let id = request.id
            var entry = PendingSnapshot(continuation: continuation, deadline: Date().addingTimeInterval(timeout), idleTimeout: timeout)
            entry.watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, let current = self.pending[id] else { return }
                    if Date() > current.deadline {
                        self.resolve(id, with: .failure(SnapshotRequestError.timedOut))
                        return
                    }
                }
            }
            pending[id] = entry
            connection.send(.control(.snapshotRequest(request)))
        }
    }

    /// Completes a pending snapshot request exactly once and stops its watchdog.
    private func resolve(_ id: UUID, with result: Result<ReceivedSnapshot, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.watchdog?.cancel()
        isCapturing = !pending.isEmpty
        entry.continuation.resume(with: result)
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
            let connectionID = connection?.id
            let snapshot = try await requestSnapshot(trigger: .interval, skipIfUnchangedBelow: threshold)
            // Automation may have been turned off (or the Source changed) meanwhile.
            guard !Task.isCancelled, settings.autoCaptureEnabled, connection?.id == connectionID else { return }
            if asking, chat.isBusy {
                chat.addToComposer(snapshot, sourceName: sourceName, automatic: true)
                lastAutoResult = "Skipped — still answering"
                return
            }
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
