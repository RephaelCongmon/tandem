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

/// Selecting regions on a frozen frame of the live view.
struct RegionSelection {
    enum Phase: Equatable {
        /// Waiting for the Source to hold its native still.
        case freezing
        case ready
        case failed(String)
    }

    /// The freeze request's id: the Source's handle for the held still.
    let id: UUID
    let connectionID: UUID
    /// The live view holds the frame it showed, which the Source's still matches unless
    /// the screen changed since.
    var heldOnStage: Bool
    /// Pixel size of what's shown, for mapping drags onto the picture.
    var frameSize: CGSize
    /// The Source's preview, shown instead when the screen changed after the held frame
    /// (or when there was no live frame to hold).
    var image: CGImage?
    var phase: Phase = .freezing
    /// Selections made on the local frame before the Source confirmed it matches.
    var queued: [SnapshotRegion] = []
    /// Everything picked from this freeze, outlined on the stage.
    var picked: [SnapshotRegion] = []
    var cropsInFlight = 0

    var canSelect: Bool { heldOnStage || image != nil }
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
    private(set) var regionSelection: RegionSelection?
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
        regionSelection = nil
        for id in Array(pending.keys) { resolve(id, with: .failure(SnapshotRequestError.notConnected)) }
        restartAutomation()
    }

    // MARK: Messages

    private func handle(_ message: ControlMessage) {
        switch message {
        case .sourceStatus(let status):
            let wasLive = sourceStatus?.state == .live
            // The Source dropped its held still: paused, or sharing something else now.
            if regionSelection != nil, (status.state != .live && status.state != .starting)
                || status.capture?.source != sourceStatus?.capture?.source {
                endRegionSelection()
            }
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
            endRegionSelection()
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
        try await send(SnapshotRequest(trigger: trigger, maxDimension: attachmentMaxDimension, quality: 0.9, skipIfUnchangedBelow: skipIfUnchangedBelow))
    }

    /// Pictures for the AI: as large as the current model reads them.
    private var attachmentMaxDimension: Int {
        min(ModelCatalog.capabilities(for: settings.currentModel, provider: settings.provider).maxImageLongEdge, 2576)
    }

    private func send(_ request: SnapshotRequest) async throws -> ReceivedSnapshot {
        guard let connection, connection.isConnected else { throw SnapshotRequestError.notConnected }
        if let status = sourceStatus, status.state != .live, status.state != .starting {
            throw SnapshotRequestError.sourceUnavailable(status.message ?? "The other Mac isn't sharing right now.")
        }
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

    /// Ask button / hotkey: asks about the pictures you selected and anything typed. With
    /// nothing to ask about yet, starts selecting instead of grabbing the screen.
    /// Returns false when it started a selection instead.
    @discardableResult
    func askAboutSelection() -> Bool {
        guard !chat.isBusy else { return true }
        let typed = chat.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPictures = chat.includesPictures && !chat.composerAttachments.isEmpty
        guard hasPictures || !typed.isEmpty else {
            beginRegionSelection()
            return false
        }
        if typed.isEmpty { chat.composerText = settings.pushPrompt }
        chat.sendFromComposer()
        return true
    }

    // MARK: Region selection

    /// Freezes the live view for dragging out regions. While selecting, calling it again
    /// adds the whole frozen frame.
    func beginRegionSelection() {
        if regionSelection != nil {
            addRegion(.full)
            return
        }
        guard let connection, connection.isConnected, canCapture else {
            chat.reportBanner("Couldn't capture: the shared Mac isn't sharing right now.")
            return
        }
        guard connection.peerSupportsRegionSnapshots else {
            // An older shared Mac sends only whole screens: still a deliberate pick.
            chat.reportBanner("Update Tandem on \(sourceName ?? "the shared Mac") to select regions. Added the whole screen for now.")
            captureWholeScreenToComposer()
            return
        }
        if !settings.showStage { settings.showStage = true }
        let started = monotonicSeconds()
        let held = liveState == .live ? renderer.freeze() : nil
        let selection = RegionSelection(id: UUID(), connectionID: connection.id, heldOnStage: held != nil,
                                        frameSize: CGSize(width: held?.width ?? 0, height: held?.height ?? 0))
        regionSelection = selection
        let log = self.log
        let elapsed = { Int((monotonicSeconds() - started) * 1000) }
        log.notice("TANDEM-TIMING region held on stage=\(held != nil, privacy: .public) after \(elapsed(), privacy: .public) ms")
        let request = SnapshotRequest(
            id: selection.id, trigger: .manual,
            maxDimension: connection.linkKind.isConstrained ? 960 : 1600, quality: 0.8,
            freeze: SnapshotFreeze(displayedFrameNanos: held?.capturedAtNanos)
        )
        Task {
            do {
                let snapshot = try await send(request)
                // The screen changed after the frozen frame: select on the Source's picture.
                let image = await Task.detached(priority: .userInitiated) { ImageCodec.decode(snapshot.data) }.value
                guard regionSelection?.id == selection.id else { return releaseFrozenStill(selection) }
                guard let image else {
                    regionSelection?.phase = .failed("Couldn't read the picture from the shared Mac.")
                    return
                }
                log.notice("TANDEM-TIMING region ready (Source preview, \(snapshot.data.count, privacy: .public) bytes) after \(elapsed(), privacy: .public) ms")
                let redo = !(regionSelection?.queued.isEmpty ?? true)
                regionSelection?.image = image
                regionSelection?.frameSize = CGSize(width: image.width, height: image.height)
                regionSelection?.queued.removeAll()
                regionSelection?.picked.removeAll()
                regionSelection?.phase = .ready
                if redo { chat.reportBanner("The shared screen changed while freezing. Select again on the updated picture.") }
            } catch SnapshotRequestError.unchanged {
                // The frozen frame shows exactly what the Source holds.
                log.notice("TANDEM-TIMING region ready (frozen frame matched, 0 bytes) after \(elapsed(), privacy: .public) ms")
                guard var current = regionSelection, current.id == selection.id else { return releaseFrozenStill(selection) }
                let queued = current.queued
                current.queued.removeAll()
                current.phase = .ready
                regionSelection = current
                for region in queued { requestCrop(region, from: current) }
            } catch {
                guard regionSelection?.id == selection.id else { return }
                regionSelection?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Adds a region of the frozen frame to the composer (requested once the Source holds it).
    func addRegion(_ region: SnapshotRegion) {
        guard var selection = regionSelection, selection.canSelect else { return }
        switch selection.phase {
        case .freezing:
            selection.queued.append(region)
            selection.picked.append(region)
            regionSelection = selection
        case .ready:
            selection.picked.append(region)
            regionSelection = selection
            requestCrop(region, from: selection)
        case .failed:
            break
        }
    }

    /// Back to the live view. Crops already requested still arrive.
    func endRegionSelection() {
        guard let selection = regionSelection else { return }
        regionSelection = nil
        if renderer.unfreeze() { connection?.send(.control(.keyframeRequest)) }
        releaseFrozenStill(selection)
    }

    private func releaseFrozenStill(_ selection: RegionSelection) {
        guard let connection, connection.id == selection.connectionID, connection.isConnected else { return }
        connection.send(.control(.releaseFrozenSnapshot(id: selection.id)))
    }

    private func requestCrop(_ region: SnapshotRegion, from selection: RegionSelection) {
        regionSelection?.cropsInFlight += 1
        let request = SnapshotRequest(trigger: .manual, maxDimension: attachmentMaxDimension, quality: 0.9,
                                      crop: SnapshotCrop(frozenID: selection.id, region: region))
        let started = monotonicSeconds()
        Task {
            defer { if regionSelection?.id == selection.id { regionSelection?.cropsInFlight -= 1 } }
            do {
                let snapshot = try await send(request)
                log.notice("TANDEM-TIMING region crop \(snapshot.header.pixelWidth, privacy: .public)x\(snapshot.header.pixelHeight, privacy: .public) (\(snapshot.data.count, privacy: .public) bytes) after \(Int((monotonicSeconds() - started) * 1000), privacy: .public) ms")
                guard connection?.id == selection.connectionID else { return }
                chat.addToComposer(snapshot, sourceName: sourceName)
            } catch {
                if regionSelection?.id == selection.id, let index = regionSelection?.picked.firstIndex(of: region) {
                    regionSelection?.picked.remove(at: index)
                }
                chat.reportBanner("Couldn't add the region: \(error.localizedDescription)")
            }
        }
    }

    /// The whole screen, for a shared Mac without region support.
    private func captureWholeScreenToComposer() {
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
