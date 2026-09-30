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

/// The Studio Mac: live view, snapshots, automation, the live transcript, and the chat.
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
    /// Whether the Source is sending its audio (nil until it reports).
    private(set) var sourceAudioStatus: AudioStatus?
    private(set) var remoteCatalog: [CaptureSourceDescriptor] = []
    private(set) var liveStats = LiveStats()
    private(set) var hasVideo = false
    private(set) var isCapturing = false
    struct RegionSelection: Identifiable {
        let id: UUID
        let preview: ReceivedSnapshot
        let connectionID: UUID
        let sourceName: String?
    }
    var regionSelection: RegionSelection?
    private(set) var regionSelectionError: String?
    @ObservationIgnored private var selectionGeneration = UUID()
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
    let transcription: TranscriptionService
    /// Sends this version of Tandem to an older shared Mac.
    let sharedMacUpdater: SharedMacUpdater
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

    init(
        settings: SettingsStore,
        keys: APIKeyStore,
        claudeCodeExecutable: @escaping @MainActor () -> URL? = { nil },
        codexExecutable: @escaping @MainActor () -> URL? = { nil },
        speechModelMirror: ParakeetModelStore.MirrorDownload? = nil
    ) {
        self.settings = settings
        chat = ChatController(settings: settings, keys: keys, claudeCodeExecutable: claudeCodeExecutable, codexExecutable: codexExecutable)
        transcription = TranscriptionService(settings: settings, modelMirror: speechModelMirror)
        sharedMacUpdater = SharedMacUpdater(settings: settings)
        chat.studio = self
        chat.transcription = transcription
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
        let pipeline = transcription.pipeline
        connection.audioSink.value = { [weak link] packet in
            // Called on the link queue, where the link's clock offset (peer − local) lives.
            let offset = link?.stats.clockOffsetNanos ?? 0
            let local = min(Int64(bitPattern: packet.capturedAtNanos) - offset, Int64(bitPattern: wallClockNanos()))
            pipeline.receive(packet, capturedAt: Date(timeIntervalSince1970: Double(local) / 1_000_000_000))
        }
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
        sourceAudioStatus = nil
        if let hello = connection.remoteHello { sharedMacUpdater.sourceConnected(connection, hello: hello) }
        sendStreamRequest()
        sendAutomationStatus()
        sendAudioRequest()
        connection.send(.control(.sourceCatalogRequest))
        restartAutomation()
    }

    func detach(_ connection: PeerConnection) {
        guard self.connection?.id == connection.id else { return }
        cancelRegionSelection()
        sharedMacUpdater.sourceDisconnected(connection)
        connection.videoSink.value = nil
        connection.audioSink.value = nil
        connection.onControl = nil
        connection.onSnapshot = nil
        connection.onSnapshotProgress = nil
        connection.onSnapshotRejected = nil
        self.connection = nil
        sourceStatus = nil
        sourceAudioStatus = nil
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
        case .audioStatus(let status):
            sourceAudioStatus = status
        case .hello(let hello):
            if let connection { sharedMacUpdater.sourceConnected(connection, hello: hello) }
        case .updateReply, .updateStatus:
            sharedMacUpdater.handle(message)
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

    // MARK: Listening

    /// Turns the live transcript of the shared Mac's audio on or off.
    func setListening(_ listening: Bool) {
        transcription.setEnabled(listening)
        sendAudioRequest()
        if listening { chat.prewarm() }
    }

    /// Codecs this Mac can decode, best first.
    static let decodableAudioCodecs: [LiveAudioCodec] = LiveAudioCodec.allCases.filter { AudioFrameDecoder(codec: $0) != nil }

    func sendAudioRequest() {
        guard let connection, connection.isConnected else { return }
        connection.send(.control(.audioRequest(AudioRequest(enabled: settings.listen, codecs: Self.decodableAudioCodecs))))
    }

    /// Why the transcript isn't getting audio right now, if it isn't.
    var listeningProblem: String? {
        guard settings.listen else { return nil }
        if case .failed(let message) = transcription.engineState { return message }
        guard let connection, connection.isConnected else { return nil }
        if connection.remoteHello != nil, !connection.peerSupportsAudio {
            return "\(sourceName ?? "The shared Mac") needs Tandem 1.3 or later to send its audio. Update it there with Update Now (from 1.4 on, this Mac updates it for you)."
        }
        guard let status = sourceAudioStatus else { return nil }
        switch status.state {
        case .needsPermission, .notAllowed, .error, .paused:
            return status.message ?? "The shared Mac isn't sending audio."
        case .off, .starting, .live:
            return nil
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
    func requestSnapshot(trigger: SnapshotTrigger, skipIfUnchangedBelow: Double? = nil, prepareRegionSelection: Bool = false, region: SnapshotRegion? = nil, frozenSnapshotID: UUID? = nil) async throws -> ReceivedSnapshot {
        guard let connection, connection.isConnected else { throw SnapshotRequestError.notConnected }
        if prepareRegionSelection || region != nil {
            guard connection.peerSupportsRegionSnapshots else {
                throw SnapshotRequestError.failed("Update Tandem on the shared Mac to select regions.")
            }
        }
        if let status = sourceStatus, status.state != .live, status.state != .starting {
            throw SnapshotRequestError.sourceUnavailable(status.message ?? "The other Mac isn't sharing right now.")
        }
        let capabilities = ModelCatalog.capabilities(for: settings.currentModel, provider: settings.provider)
        let request = SnapshotRequest(
            trigger: trigger,
            maxDimension: prepareRegionSelection ? 1600 : min(capabilities.maxImageLongEdge, 2576),
            quality: prepareRegionSelection ? 0.8 : 0.9,
            skipIfUnchangedBelow: skipIfUnchangedBelow,
            prepareRegionSelection: prepareRegionSelection ? true : nil,
            region: region,
            frozenSnapshotID: frozenSnapshotID
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

    /// Ask using deliberately selected pictures and the text already in the composer.
    func captureAndAsk() {
        chat.sendFromComposer()
    }

    /// Freeze a preview; nothing is attached until the user draws and adds a region.
    func captureToComposer() {
        guard canCapture, !isCapturing else { return }
        let generation = UUID()
        selectionGeneration = generation
        let sessionID = regionSelection?.id ?? UUID()
        regionSelectionError = nil
        let connectionID = connection?.id
        let name = sourceName
        Task {
            do {
                let preview = try await requestSnapshot(trigger: .manual, prepareRegionSelection: true)
                guard selectionGeneration == generation, let connectionID, connection?.id == connectionID else {
                    if connection?.id == connectionID { connection?.send(.control(.discardRegionSelection(id: preview.header.id))) }
                    return
                }
                regionSelection = RegionSelection(id: sessionID, preview: preview, connectionID: connectionID, sourceName: name)
            } catch {
                guard selectionGeneration == generation else { return }
                regionSelectionError = error.localizedDescription
                if regionSelection == nil {
                    chat.reportBanner("Couldn't capture: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelRegionSelection() {
        if let selection = regionSelection, connection?.id == selection.connectionID {
            connection?.send(.control(.discardRegionSelection(id: selection.preview.header.id)))
        }
        selectionGeneration = UUID()
        regionSelection = nil
        regionSelectionError = nil
    }

    func addSelectedRegion(_ region: SnapshotRegion) {
        guard let selection = regionSelection, !isCapturing else { return }
        let generation = selectionGeneration
        regionSelectionError = nil
        Task {
            do {
                guard connection?.id == selection.connectionID else { throw SnapshotRequestError.notConnected }
                let snapshot = try await requestSnapshot(trigger: .manual, region: region, frozenSnapshotID: selection.preview.header.id)
                guard selectionGeneration == generation, connection?.id == selection.connectionID else { return }
                chat.addToComposer(snapshot, sourceName: selection.sourceName)
                cancelRegionSelection()
            } catch {
                guard selectionGeneration == generation else { return }
                regionSelectionError = error.localizedDescription
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
