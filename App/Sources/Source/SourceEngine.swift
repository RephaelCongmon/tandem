import AppKit
import AVFoundation
import Observation
import os
import TandemCore

/// Everything the Source Mac does: capture, stream to viewers, answer snapshot
/// requests, and push snapshots (with optional notes) on demand.
@MainActor
@Observable
final class SourceEngine {
    enum CaptureState: Equatable {
        case idle
        case starting
        case live
        case needsPermission
        case error(String)
    }

    struct Viewer: Identifiable {
        let id: UUID
        let connection: PeerConnection
        var approved: Bool
        var streamRequest: StreamRequest?
        var automation: AutomationStatus?

        @MainActor var name: String { connection.peer?.name ?? "Studio" }
        var isWatching: Bool { approved && (streamRequest?.enabled ?? false) }
    }

    struct PushFeedback: Equatable {
        var date: Date
        var recipients: [String]
        var note: String?
        var error: String?
    }

    private(set) var viewers: [Viewer] = []
    private(set) var captureState: CaptureState = .idle
    private(set) var catalog: [CaptureSourceDescriptor] = []
    private(set) var current: CaptureSourceDescriptor?
    private(set) var isSharingEnabled = true
    private(set) var isLockPaused = false
    private(set) var lastReply: ReplyMirror?
    private(set) var lastPush: PushFeedback?
    private(set) var streamStats = VideoFanout.Stats()
    private(set) var hasScreenPermission = CaptureService.hasScreenRecordingPermission
    private(set) var isPushing = false
    /// A snapshot captured when the note panel opened, sent when the note is submitted.
    private(set) var preparedPush: CGImage?

    var pendingApprovals: [Viewer] { viewers.filter { !$0.approved } }
    var watchingCount: Int { viewers.filter(\.isWatching).count }
    var isActive: Bool { isSharingEnabled && !isLockPaused }
    var isStreaming: Bool { captureState == .live && watchingCount > 0 }

    @ObservationIgnored let previewLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private let preview = Locked(false)
    @ObservationIgnored private let capture = CaptureService()
    @ObservationIgnored private let fanout = VideoFanout()
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var lastFingerprints: [UUID: ImageCodec.Fingerprint] = [:]
    @ObservationIgnored private var captureChain: Task<Void, Never>?
    @ObservationIgnored private var runningConfig: CaptureConfig?
    @ObservationIgnored private var runningSource: CaptureSourceID?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastPreviewEnqueue = 0.0
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Source")

    init(settings: SettingsStore) {
        self.settings = settings
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor

        let fanout = self.fanout
        let preview = self.preview
        let layer = previewLayer
        capture.onFrame = { [weak self] sample, pixel, captured in
            fanout.submit(pixel, presentationTime: CMSampleBufferGetPresentationTimeStamp(sample), capturedAtNanos: captured)
            if preview.value { self?.enqueuePreview(sample, layer: layer) }
        }
        capture.onInterrupted = { [weak self] error in
            onMain { self?.captureInterrupted(error) }
        }
        fanout.onStats = { [weak self] stats in
            onMain { self?.streamStats = stats }
        }
        observeLockState()
    }

    // MARK: Lifecycle

    func activate() {
        refreshPermission()
        Task { await refreshCatalog() }
    }

    func deactivate() {
        for viewer in viewers { fanout.removeViewer(id: viewer.id) }
        viewers.removeAll()
        stopCapture()
    }

    func refreshPermission() {
        let had = hasScreenPermission
        hasScreenPermission = CaptureService.hasScreenRecordingPermission
        if hasScreenPermission, captureState == .needsPermission { captureState = .idle }
        if !hasScreenPermission, CaptureService.requiresScreenPermission(selectedSource) { captureState = .needsPermission }
        if had != hasScreenPermission {
            Task { await refreshCatalog() }
            reconcile()
        }
    }

    func requestPermission() {
        if !CaptureService.requestScreenRecordingPermission() {
            CaptureService.openScreenRecordingSettings()
        }
        refreshPermission()
    }

    /// Show the live preview in the Source window (only costs anything while visible).
    func setPreviewVisible(_ visible: Bool) {
        preview.value = visible
        if !visible { previewLayer.sampleBufferRenderer.flush() }
    }

    private nonisolated func enqueuePreview(_ sample: CMSampleBuffer, layer: AVSampleBufferDisplayLayer) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
    }

    // MARK: Viewers

    func attach(_ connection: PeerConnection) {
        guard !viewers.contains(where: { $0.id == connection.id }) else { return }
        let approved = !settings.approveEachSession || connection.newlyPaired
        viewers.append(Viewer(id: connection.id, connection: connection, approved: approved))
        fanout.addViewer(id: connection.id, link: connection.link, quality: .balanced)
        let fanout = self.fanout
        let id = connection.id
        connection.ackSink.value = { [weak connection] ack in
            fanout.acknowledge(id: id, sequence: ack.sequence, rttMillis: connection?.link.stats.rttMillis)
        }
        connection.onControl = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            self.handle(message, from: connection)
        }
        if !approved { NSApp.requestUserAttention(.criticalRequest) }
        sendStatus(to: connection)
        if settings.allowRemoteSourceSelection { connection.send(.control(.sourceCatalog(catalog))) }
    }

    func detach(_ connection: PeerConnection) {
        guard viewers.contains(where: { $0.id == connection.id }) else { return }
        connection.ackSink.value = nil
        connection.onControl = nil
        fanout.removeViewer(id: connection.id)
        viewers.removeAll { $0.id == connection.id }
        lastFingerprints[connection.id] = nil
        reconcile()
    }

    func approve(_ viewerID: UUID, allow: Bool) {
        guard let index = viewers.firstIndex(where: { $0.id == viewerID }) else { return }
        if allow {
            viewers[index].approved = true
            sendStatus(to: viewers[index].connection)
            reconcile()
        } else {
            viewers[index].connection.close(reason: "The other Mac's user declined this session.")
        }
    }

    private func handle(_ message: ControlMessage, from connection: PeerConnection) {
        guard let index = viewers.firstIndex(where: { $0.id == connection.id }) else { return }
        switch message {
        case .streamRequest(let request):
            viewers[index].streamRequest = request
            reconcile()
        case .keyframeRequest:
            fanout.requestKeyframe(id: connection.id)
        case .snapshotRequest(let request):
            handleSnapshotRequest(request, viewer: viewers[index])
        case .sourceCatalogRequest:
            Task {
                await refreshCatalog()
                connection.send(.control(.sourceCatalog(settings.allowRemoteSourceSelection ? catalog : [])))
            }
        case .selectSource(let source):
            guard settings.allowRemoteSourceSelection, viewers[index].approved else { return }
            select(source)
        case .automationStatus(let status):
            viewers[index].automation = status
        case .replyMirror(let reply):
            if settings.showRepliesOnSource { lastReply = reply }
        default:
            break
        }
    }

    // MARK: Sharing controls

    var selectedSource: CaptureSourceID? {
        settings.captureSource ?? catalog.first(where: { $0.source.kind == .display })?.source
    }

    func setSharing(_ enabled: Bool) {
        isSharingEnabled = enabled
        reconcile()
    }

    func toggleSharing() { setSharing(!isSharingEnabled) }

    func select(_ source: CaptureSourceID) {
        settings.captureSource = source
        current = catalog.first { $0.source == source }
        lastFingerprints.removeAll()
        capture.invalidateFilter()
        runningSource = nil
        reconcile()
    }

    func refreshCatalog() async {
        do {
            catalog = try await CaptureService.catalog(excludeOwnApp: settings.excludeTandemWindows)
            hasScreenPermission = true
            if case .needsPermission = captureState { captureState = .idle }
        } catch CaptureError.permissionDenied {
            hasScreenPermission = false
            catalog = CameraCapture.availableCameras()
            if CaptureService.requiresScreenPermission(selectedSource) { captureState = .needsPermission }
        } catch {
            log.error("Catalog failed: \(error.localizedDescription, privacy: .public)")
        }
        if let selected = selectedSource {
            current = catalog.first { $0.source == selected } ?? current
        }
        broadcastStatus()
    }

    // MARK: Capture lifecycle

    private func effectiveQuality(for viewer: Viewer) -> StreamQuality {
        if viewer.connection.linkKind.isConstrained { return .bluetooth }
        let requested = viewer.streamRequest?.quality ?? .balanced
        return StreamQuality(
            maxDimension: min(max(requested.maxDimension, 480), 3840),
            maxFPS: min(max(requested.maxFPS, 1), 60),
            maxBitrateKbps: min(max(requested.maxBitrateKbps, 200), 40_000)
        )
    }

    /// Brings capture and every viewer's stream in line with the current state.
    private func reconcile() {
        let active = isActive
        var wanting: [StreamQuality] = []
        for viewer in viewers {
            let quality = effectiveQuality(for: viewer)
            let wants = active && viewer.isWatching
            fanout.setViewer(id: viewer.id, wantsVideo: wants, quality: quality)
            if wants { wanting.append(quality) }
        }
        let needsCapture = active && !wanting.isEmpty && selectedSource != nil
            && (hasScreenPermission || !CaptureService.requiresScreenPermission(selectedSource))
        if needsCapture, let source = selectedSource {
            let config = CaptureConfig(
                maxDimension: wanting.map(\.maxDimension).max() ?? 1920,
                fps: wanting.map(\.maxFPS).max() ?? 30,
                showsCursor: settings.showCursor
            )
            startOrUpdateCapture(source: source, config: config)
        } else {
            stopCapture()
        }
        broadcastStatus()
    }

    private func startOrUpdateCapture(source: CaptureSourceID, config: CaptureConfig) {
        guard runningSource != source || runningConfig != config else { return }
        let restart = runningSource != source
        runningSource = source
        runningConfig = config
        if restart { captureState = .starting }
        let capture = self.capture
        let fanout = self.fanout
        let exclude = settings.excludeTandemWindows
        let previous = captureChain
        captureChain = Task { [weak self] in
            await previous?.value
            do {
                if restart || !capture.isRunning {
                    fanout.resetStream()
                    let descriptor = try await capture.start(source: source, config: config, excludeOwnApp: exclude)
                    self?.current = descriptor
                } else {
                    try await capture.update(config: config)
                }
                guard let self, self.runningSource == source else { return }
                self.captureState = .live
            } catch {
                guard let self else { return }
                self.runningSource = nil
                self.runningConfig = nil
                if case CaptureError.permissionDenied = error {
                    self.hasScreenPermission = false
                    self.captureState = .needsPermission
                } else {
                    self.captureState = .error(error.localizedDescription)
                }
                self.log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.broadcastStatus()
        }
    }

    private func stopCapture() {
        guard runningSource != nil || capture.isRunning else {
            if captureState == .live || captureState == .starting { captureState = .idle }
            return
        }
        runningSource = nil
        runningConfig = nil
        let capture = self.capture
        let fanout = self.fanout
        let previous = captureChain
        captureChain = Task {
            await previous?.value
            await capture.stop()
            fanout.resetStream()
        }
        if captureState != .needsPermission { captureState = .idle }
        previewLayer.sampleBufferRenderer.flush()
    }

    private func captureInterrupted(_ error: Error?) {
        runningSource = nil
        runningConfig = nil
        // The window closed or the display went away: fall back to the main display.
        if settings.captureSource?.kind == .window {
            settings.captureSource = nil
        }
        Task {
            await refreshCatalog()
            reconcile()
        }
    }

    // MARK: Status

    private func status(for viewer: Viewer) -> SourceStatus {
        let state: SourceStatus.State
        var message: String?
        if !viewer.approved {
            state = .paused
            message = "Waiting for approval on \(DeviceIdentity.systemName)."
        } else if !hasScreenPermission && CaptureService.requiresScreenPermission(selectedSource) {
            state = .needsPermission
            message = "Screen Recording permission is needed on the shared Mac."
        } else if !isSharingEnabled {
            state = .paused
            message = "Sharing is paused on the shared Mac."
        } else if isLockPaused {
            state = .paused
            message = "The shared Mac is locked."
        } else {
            switch captureState {
            case .starting: state = .starting
            case .error(let text):
                state = .error
                message = text
            default: state = .live
            }
        }
        return SourceStatus(state: state, capture: current, message: message, allowsRemoteSourceSelection: settings.allowRemoteSourceSelection)
    }

    private func sendStatus(to connection: PeerConnection) {
        guard let viewer = viewers.first(where: { $0.id == connection.id }) else { return }
        connection.send(.control(.sourceStatus(status(for: viewer))))
    }

    @ObservationIgnored private var lastBroadcast: [UUID: SourceStatus] = [:]

    private func broadcastStatus() {
        for viewer in viewers {
            let status = status(for: viewer)
            guard lastBroadcast[viewer.id] != status else { continue }
            lastBroadcast[viewer.id] = status
            viewer.connection.send(.control(.sourceStatus(status)))
        }
    }

    // MARK: Snapshots

    private func handleSnapshotRequest(_ request: SnapshotRequest, viewer: Viewer) {
        let connection = viewer.connection
        guard viewer.approved else {
            connection.send(.control(.snapshotFailed(id: request.id, reason: "Waiting for approval on the shared Mac.")))
            return
        }
        guard isActive else {
            connection.send(.control(.snapshotFailed(id: request.id, reason: isLockPaused ? "The shared Mac is locked." : "Sharing is paused on the shared Mac.")))
            return
        }
        guard let source = selectedSource else {
            connection.send(.control(.snapshotFailed(id: request.id, reason: "Nothing is selected to share.")))
            return
        }
        let capture = self.capture
        let showCursor = settings.showCursor
        let exclude = settings.excludeTandemWindows
        let maxDimension = request.maxDimension
        let quality = min(max(request.quality, 0.5), 1)
        let title = current?.title
        let previousFingerprint = lastFingerprints[viewer.id]
        Task { [weak self] in
            do {
                let image = try await capture.snapshot(source: source, maxDimension: maxDimension, showsCursor: showCursor, excludeOwnApp: exclude)
                let encoded = await Task.detached(priority: .userInitiated) { () -> (Data, Int, Int, ImageCodec.Fingerprint?)? in
                    guard let jpeg = ImageCodec.jpeg(image, quality: quality) else { return nil }
                    return (jpeg.data, jpeg.width, jpeg.height, ImageCodec.fingerprint(image))
                }.value
                guard let self, let (data, width, height, fingerprint) = encoded else {
                    connection.send(.control(.snapshotFailed(id: request.id, reason: "Couldn't encode the snapshot.")))
                    return
                }
                if let threshold = request.skipIfUnchangedBelow, let fingerprint, let previousFingerprint,
                   fingerprint.difference(from: previousFingerprint) < threshold {
                    connection.send(.control(.snapshotUnchanged(id: request.id)))
                    return
                }
                if let fingerprint { self.lastFingerprints[viewer.id] = fingerprint }
                let header = SnapshotHeader(
                    id: request.id, trigger: request.trigger, note: nil,
                    pixelWidth: width, pixelHeight: height, byteCount: data.count,
                    chunkCount: PeerLink.chunkCount(byteCount: data.count, link: connection.linkKind),
                    mimeType: "image/jpeg", capturedAt: Date(), captureTitle: title
                )
                connection.sendSnapshot(header: header, data: data)
            } catch {
                connection.send(.control(.snapshotFailed(id: request.id, reason: error.localizedDescription)))
                if case CaptureError.permissionDenied = error { self?.refreshPermission() }
            }
        }
    }

    /// Captures right away (used when the note panel opens, so the panel itself
    /// is never in the picture and the moment is preserved).
    func prepareNotePush() async {
        preparedPush = try? await captureStill()
    }

    func discardPreparedPush() {
        preparedPush = nil
    }

    /// Sends a snapshot (optionally with a note) to every approved viewer.
    @discardableResult
    func pushSnapshot(note: String?) async -> PushFeedback {
        let recipients = viewers.filter(\.approved)
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteValue = (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote
        guard !recipients.isEmpty else {
            let feedback = PushFeedback(date: Date(), recipients: [], note: noteValue, error: "No Studio is connected.")
            lastPush = feedback
            preparedPush = nil
            return feedback
        }
        guard isActive else {
            let feedback = PushFeedback(date: Date(), recipients: [], note: noteValue, error: "Sharing is paused.")
            lastPush = feedback
            preparedPush = nil
            return feedback
        }
        isPushing = true
        defer { isPushing = false }
        do {
            let image: CGImage
            if let prepared = preparedPush {
                image = prepared
            } else {
                image = try await captureStill()
            }
            preparedPush = nil
            let quality = settings.snapshotQuality
            let maxDimension = settings.snapshotResolution.rawValue
            guard let encoded = await Task.detached(priority: .userInitiated, operation: {
                ImageCodec.jpeg(image, quality: quality, maxDimension: maxDimension)
            }).value else {
                throw CaptureError.snapshotFailed("encoding failed")
            }
            let fingerprint = ImageCodec.fingerprint(image)
            for viewer in recipients {
                let header = SnapshotHeader(
                    id: UUID(), trigger: .sourcePush, note: noteValue,
                    pixelWidth: encoded.width, pixelHeight: encoded.height, byteCount: encoded.data.count,
                    chunkCount: PeerLink.chunkCount(byteCount: encoded.data.count, link: viewer.connection.linkKind),
                    mimeType: "image/jpeg", capturedAt: Date(), captureTitle: current?.title
                )
                viewer.connection.sendSnapshot(header: header, data: encoded.data)
                if let fingerprint { lastFingerprints[viewer.id] = fingerprint }
            }
            let feedback = PushFeedback(date: Date(), recipients: recipients.map(\.name), note: noteValue, error: nil)
            lastPush = feedback
            return feedback
        } catch {
            if case CaptureError.permissionDenied = error { refreshPermission() }
            let feedback = PushFeedback(date: Date(), recipients: [], note: noteValue, error: error.localizedDescription)
            lastPush = feedback
            return feedback
        }
    }

    private func captureStill() async throws -> CGImage {
        guard let source = selectedSource else { throw CaptureError.sourceUnavailable }
        return try await capture.snapshot(
            source: source,
            maxDimension: settings.snapshotResolution.rawValue,
            showsCursor: settings.showCursor,
            excludeOwnApp: settings.excludeTandemWindows
        )
    }

    /// A small still of the selected source for the idle preview.
    func thumbnail(maxDimension: Int = 960) async -> CGImage? {
        guard let source = selectedSource, isActive, hasScreenPermission || !CaptureService.requiresScreenPermission(source) else { return nil }
        return try? await capture.snapshot(source: source, maxDimension: maxDimension, showsCursor: settings.showCursor, excludeOwnApp: settings.excludeTandemWindows)
    }

    // MARK: Screen lock

    private func observeLockState() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.pauseWhenLocked else { return }
                self.isLockPaused = true
                self.reconcile()
            }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLockPaused = false
                self.reconcile()
            }
        })
    }
}
