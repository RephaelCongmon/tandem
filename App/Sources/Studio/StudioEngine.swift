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
    /// A drag with the region tool. The live view holds the frame it showed.
    struct RegionDrag {
        /// The freeze request's id: the Source's handle for the still it captures.
        let id: UUID
        let connectionID: UUID
        /// Pixel size of the held frame, for mapping the drag onto the picture.
        let frameSize: CGSize
        /// The Source's picture, shown instead when its screen changed after the held frame.
        var preview: CGImage?
        /// True once the Source holds the still, false if it couldn't capture it.
        let prepared: Task<Bool, Never>
    }
    /// While on, every drag on the live view adds that part of the shared screen to the composer.
    private(set) var isRegionToolOn = false
    private(set) var regionDrag: RegionDrag?
    /// Regions requested but not in the composer yet.
    private(set) var regionCropsInFlight = 0
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
    /// Text in a see-through overlay on the shared Mac's screen.
    let glance: GlanceInjector
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
        glance = GlanceInjector(settings: settings)
        glance.chat = chat
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
        glance.attach(connection)
        restartAutomation()
    }

    func detach(_ connection: PeerConnection) {
        guard self.connection?.id == connection.id else { return }
        setRegionTool(false)
        glance.detach(connection)
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
            // Paused, or sharing something else now: the Source dropped its stills.
            if isRegionToolOn, (status.state != .live && status.state != .starting)
                || status.capture?.source != sourceStatus?.capture?.source {
                setRegionTool(false)
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
        case .glanceStatus(let status):
            glance.handle(status)
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
            // Nothing to drag on without the live view.
            setRegionTool(false)
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
    func requestSnapshot(id: UUID = UUID(), trigger: SnapshotTrigger, skipIfUnchangedBelow: Double? = nil, prepareRegionSelection: Bool = false, region: SnapshotRegion? = nil, frozenSnapshotID: UUID? = nil, displayedFrameNanos: UInt64? = nil) async throws -> ReceivedSnapshot {
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
            id: id,
            trigger: trigger,
            maxDimension: prepareRegionSelection ? (connection.linkKind.isConstrained ? 960 : 1600) : min(capabilities.maxImageLongEdge, 2576),
            quality: prepareRegionSelection ? 0.8 : 0.9,
            skipIfUnchangedBelow: skipIfUnchangedBelow,
            prepareRegionSelection: prepareRegionSelection ? true : nil,
            region: region,
            frozenSnapshotID: frozenSnapshotID,
            displayedFrameNanos: displayedFrameNanos
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
        // Asking ends region selection, like picking any other tool.
        setRegionTool(false)
        chat.sendFromComposer()
    }

    // MARK: Glance

    /// The Glance tool: drag, resize and scroll the shared Mac's Glance on the live view.
    func toggleGlanceTool() {
        if !glance.isToolOn { setRegionTool(false) }
        glance.toggleTool()
    }

    // MARK: Region tool

    /// Select Region: turns the region tool on or off.
    func toggleRegionTool() {
        setRegionTool(!isRegionToolOn)
    }

    /// While the tool is on, each drag on the live view freezes that frame and adds the
    /// dragged part of the shared screen to the composer, at full resolution.
    func setRegionTool(_ on: Bool) {
        guard on else {
            endRegionDrag(nil)
            isRegionToolOn = false
            return
        }
        guard !isRegionToolOn else { return }
        guard let connection, connection.isConnected, canCapture else {
            chat.reportBanner("Couldn't select a region: the shared Mac isn't sharing right now.")
            return
        }
        guard connection.peerSupportsRegionSnapshots else {
            chat.reportBanner("Update Tandem on \(sourceName ?? "the shared Mac") to select regions.")
            return
        }
        // Both tools are drags on the live view.
        glance.setTool(false)
        // Regions are dragged on the live view, so make sure it's showing.
        if !settings.showStage { settings.showStage = true }
        if !livePreviewEnabled { livePreviewEnabled = true }
        isRegionToolOn = true
    }

    /// The pointer went down on the live view: hold that frame and have the Source capture a
    /// native still of the same moment. Returns false when no drag can start.
    @discardableResult
    func beginRegionDrag() -> Bool {
        guard isRegionToolOn, regionDrag == nil, let connection, connection.isConnected, liveState == .live,
              connection.peerSupportsRegionSnapshots else { return false }
        // A Source without the region tool holds one still: finish the previous crop first.
        let fast = connection.peerSupportsRegionTool
        guard fast || regionCropsInFlight == 0 else { return false }
        guard let held = renderer.freeze() else { return false }
        let id = UUID()
        let connectionID = connection.id
        let started = monotonicSeconds()
        let log = self.log
        let prepared = Task { [weak self] () -> Bool in
            guard let self else { return false }
            do {
                // The Source's screen changed after the held frame: show its picture instead.
                let preview = try await self.requestSnapshot(id: id, trigger: .manual, prepareRegionSelection: true,
                                                            displayedFrameNanos: fast ? held.capturedAtNanos : nil)
                let image = await Task.detached(priority: .userInitiated) { ImageCodec.decode(preview.data) }.value
                log.info("TANDEM-TIMING region still held (preview \(preview.data.count, privacy: .public) bytes) after \(Int((monotonicSeconds() - started) * 1000), privacy: .public) ms")
                if self.regionDrag?.id == id { self.regionDrag?.preview = image }
                return true
            } catch SnapshotRequestError.unchanged {
                log.info("TANDEM-TIMING region still held (frozen frame current, no preview) after \(Int((monotonicSeconds() - started) * 1000), privacy: .public) ms")
                return true
            } catch {
                if self.regionDrag?.id == id {
                    self.endRegionDrag(nil)
                    self.chat.reportBanner("Couldn't select a region: \(error.localizedDescription)")
                }
                return false
            }
        }
        regionDrag = RegionDrag(id: id, connectionID: connectionID, frameSize: CGSize(width: held.width, height: held.height), prepared: prepared)
        return true
    }

    /// The pointer came up: send the region to the composer (nil for a click or a drag that
    /// selected nothing) and go back to the live view.
    func endRegionDrag(_ region: SnapshotRegion?) {
        guard let drag = regionDrag else { return }
        regionDrag = nil
        if renderer.unfreeze() { connection?.send(.control(.keyframeRequest)) }
        guard let region else {
            if connection?.id == drag.connectionID { connection?.send(.control(.discardRegionSelection(id: drag.id))) }
            return
        }
        let fast = connection?.peerSupportsRegionTool ?? false
        let name = sourceName
        let started = monotonicSeconds()
        let log = self.log
        regionCropsInFlight += 1
        Task {
            defer { regionCropsInFlight -= 1 }
            // A regionTool Source answers once its still is captured; others need it held first.
            if !fast, !(await drag.prepared.value) { return }
            do {
                guard connection?.id == drag.connectionID else { throw SnapshotRequestError.notConnected }
                let snapshot = try await requestSnapshot(trigger: .manual, region: region, frozenSnapshotID: drag.id)
                log.info("TANDEM-TIMING region crop \(snapshot.header.pixelWidth, privacy: .public)x\(snapshot.header.pixelHeight, privacy: .public) in the composer \(Int((monotonicSeconds() - started) * 1000), privacy: .public) ms after release")
                guard connection?.id == drag.connectionID else { return }
                chat.addToComposer(snapshot, sourceName: name)
            } catch {
                chat.reportBanner("Couldn't add the region: \(error.localizedDescription)")
            }
        }
    }

    /// Adds the whole frame on screen right now, as if dragged corner to corner.
    func addWholeScreen() {
        if beginRegionDrag() { endRegionDrag(.full) }
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
