import AppKit
import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit
import TandemCore

/// Live stream parameters.
struct CaptureConfig: Equatable {
    var maxDimension: Int
    var fps: Int
    var showsCursor: Bool
}

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case cameraPermissionDenied
    case sourceUnavailable
    case snapshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Tandem needs Screen Recording permission. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording."
        case .cameraPermissionDenied:
            return "Tandem needs Camera permission. Turn it on in System Settings › Privacy & Security › Camera."
        case .sourceUnavailable:
            return "The selected display, window or camera isn't available anymore."
        case .snapshotFailed(let reason):
            return "Couldn't capture a snapshot: \(reason)"
        }
    }
}

/// Captures a display, window or camera. Frames are delivered on `outputQueue`.
///
/// Screen content uses ScreenCaptureKit (frames arrive only when pixels change,
/// which keeps idle bandwidth near zero); cameras use AVFoundation.
final class CaptureService: NSObject, @unchecked Sendable {
    let outputQueue = DispatchQueue(label: "tandem.capture", qos: .userInteractive)

    /// `(sampleBuffer, pixelBuffer, wallClockCaptureNanos)` for each new frame.
    var onFrame: ((CMSampleBuffer, CVPixelBuffer, UInt64) -> Void)?
    /// The stream stopped on its own (window closed, display unplugged, permission revoked).
    var onInterrupted: ((Error?) -> Void)?

    private let lock = NSLock()
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var filterSource: CaptureSourceID?
    private var descriptor: CaptureSourceDescriptor?
    private var config: CaptureConfig?
    private var camera: CameraCapture?
    private var lastCameraFrame: CVPixelBuffer?
    #if DEBUG
    private var testPattern: TestPatternGenerator?
    #endif
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Capture")

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
        if testPattern != nil { return true }
        #endif
        return stream != nil || camera != nil
    }

    /// Whether capturing `source` needs Screen Recording permission.
    static func requiresScreenPermission(_ source: CaptureSourceID?) -> Bool {
        guard let source else { return true }
        #if DEBUG
        if source == TestPatternGenerator.sourceID { return false }
        #endif
        return source.kind != .camera
    }

    // MARK: Permissions

    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Catalog

    /// Everything this Mac can share, displays first.
    static func catalog(excludeOwnApp: Bool = true) async throws -> [CaptureSourceDescriptor] {
        var result: [CaptureSourceDescriptor] = []
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screens = NSScreen.screens
            for display in content.displays {
                let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
                let scale = screen?.backingScaleFactor ?? 2
                let isMain = CGDisplayIsMain(display.displayID) != 0
                result.append(CaptureSourceDescriptor(
                    source: CaptureSourceID(kind: .display, id: String(display.displayID)),
                    title: screen?.localizedName ?? "Display \(display.displayID)",
                    subtitle: isMain ? "Main display" : nil,
                    pixelWidth: Int(CGFloat(display.width) * scale),
                    pixelHeight: Int(CGFloat(display.height) * scale)
                ))
            }
            let ownBundle = Bundle.main.bundleIdentifier
            let hiddenApps: Set<String> = [
                "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.notificationcenterui",
                "com.apple.Spotlight", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent", "com.apple.wallpaper.agent"
            ]
            let windows = content.windows.filter { window in
                guard window.windowLayer == 0, window.isOnScreen,
                      window.frame.width >= 160, window.frame.height >= 120,
                      let app = window.owningApplication else { return false }
                if hiddenApps.contains(app.bundleIdentifier) { return false }
                if excludeOwnApp, app.bundleIdentifier == ownBundle { return false }
                return true
            }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            for window in windows.sorted(by: { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }) {
                let appName = window.owningApplication?.applicationName ?? "Window"
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result.append(CaptureSourceDescriptor(
                    source: CaptureSourceID(kind: .window, id: String(window.windowID)),
                    title: title.isEmpty ? appName : "\(appName) — \(title)",
                    subtitle: appName,
                    pixelWidth: Int(window.frame.width * scale),
                    pixelHeight: Int(window.frame.height * scale)
                ))
            }
        } catch {
            if !hasScreenRecordingPermission { throw CaptureError.permissionDenied }
            throw error
        }
        result.append(contentsOf: nonScreenSources())
        return result
    }

    /// Sources that work without Screen Recording permission.
    static func nonScreenSources() -> [CaptureSourceDescriptor] {
        var sources = CameraCapture.availableCameras()
        #if DEBUG
        sources.append(TestPatternGenerator.descriptor)
        #endif
        return sources
    }

    // MARK: Streaming

    /// Starts (or restarts) capturing `source`.
    func start(source: CaptureSourceID, config: CaptureConfig, excludeOwnApp: Bool) async throws -> CaptureSourceDescriptor {
        await stop()
        #if DEBUG
        if source == TestPatternGenerator.sourceID {
            let generator = TestPatternGenerator(queue: outputQueue, maxDimension: config.maxDimension) { [weak self] sample, pixel, captured in
                self?.onFrame?(sample, pixel, captured)
            }
            generator.start(fps: config.fps)
            lock.withLock {
                testPattern = generator
                self.descriptor = TestPatternGenerator.descriptor
                self.config = config
                filterSource = source
            }
            return TestPatternGenerator.descriptor
        }
        #endif
        if source.kind == .camera {
            let camera = try await CameraCapture.start(deviceID: source.id, queue: outputQueue, config: config) { [weak self] sample, pixel in
                guard let self else { return }
                self.lock.withLock { self.lastCameraFrame = pixel }
                self.onFrame?(sample, pixel, wallClockNanos())
            } onInterrupted: { [weak self] error in
                self?.onInterrupted?(error)
            }
            lock.withLock {
                self.camera = camera
                self.descriptor = camera.descriptor
                self.config = config
                filterSource = source
            }
            return camera.descriptor
        }

        let (filter, descriptor) = try await makeFilter(for: source, excludeOwnApp: excludeOwnApp)
        let stream = SCStream(filter: filter, configuration: streamConfiguration(for: filter, config: config), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        lock.withLock {
            self.stream = stream
            self.filter = filter
            self.filterSource = source
            self.descriptor = descriptor
            self.config = config
        }
        log.info("Capture started: \(descriptor.title, privacy: .private)")
        return descriptor
    }

    func update(config: CaptureConfig) async throws {
        let (stream, filter, camera, changed) = lock.withLock { () -> (SCStream?, SCContentFilter?, CameraCapture?, Bool) in
            let changed = self.config != config
            self.config = config
            return (self.stream, self.filter, self.camera, changed)
        }
        guard changed else { return }
        if let camera {
            camera.apply(config)
            return
        }
        guard let stream, let filter else { return }
        try await stream.updateConfiguration(streamConfiguration(for: filter, config: config))
    }

    func stop() async {
        let (stream, camera) = lock.withLock { () -> (SCStream?, CameraCapture?) in
            let current = (self.stream, self.camera)
            self.stream = nil
            self.camera = nil
            lastCameraFrame = nil
            #if DEBUG
            testPattern?.stop()
            testPattern = nil
            #endif
            return current
        }
        if let stream {
            try? await stream.stopCapture()
        }
        camera?.stop()
    }

    private func streamConfiguration(for filter: SCContentFilter, config: CaptureConfig) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let (width, height) = Self.targetSize(for: filter, maxDimension: config.maxDimension)
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, config.fps)))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 5
        configuration.showsCursor = config.showsCursor
        configuration.scalesToFit = true
        configuration.capturesAudio = false
        configuration.captureResolution = .best
        return configuration
    }

    /// Even pixel dimensions no larger than `maxDimension` on the long edge.
    static func targetSize(for filter: SCContentFilter, maxDimension: Int) -> (Int, Int) {
        let scale = CGFloat(filter.pointPixelScale)
        var width = filter.contentRect.width * scale
        var height = filter.contentRect.height * scale
        let longest = max(width, height)
        if maxDimension > 0, longest > CGFloat(maxDimension) {
            let factor = CGFloat(maxDimension) / longest
            width *= factor
            height *= factor
        }
        let evenWidth = max(2, Int(width.rounded()) & ~1)
        let evenHeight = max(2, Int(height.rounded()) & ~1)
        return (evenWidth, evenHeight)
    }

    private func makeFilter(for source: CaptureSourceID, excludeOwnApp: Bool) async throws -> (SCContentFilter, CaptureSourceDescriptor) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !Self.hasScreenRecordingPermission { throw CaptureError.permissionDenied }
            throw error
        }
        switch source.kind {
        case .display:
            // Never substitute a different display for the one the user chose.
            guard let display = content.displays.first(where: { String($0.displayID) == source.id }) else {
                throw CaptureError.sourceUnavailable
            }
            let own = excludeOwnApp ? content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier } : []
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
            let (w, h) = Self.targetSize(for: filter, maxDimension: 0)
            let descriptor = CaptureSourceDescriptor(
                source: CaptureSourceID(kind: .display, id: String(display.displayID)),
                title: screen?.localizedName ?? "Display",
                subtitle: CGDisplayIsMain(display.displayID) != 0 ? "Main display" : nil,
                pixelWidth: w, pixelHeight: h
            )
            return (filter, descriptor)
        case .window:
            guard let window = content.windows.first(where: { String($0.windowID) == source.id }) else {
                throw CaptureError.sourceUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let appName = window.owningApplication?.applicationName ?? "Window"
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let (w, h) = Self.targetSize(for: filter, maxDimension: 0)
            let descriptor = CaptureSourceDescriptor(
                source: source,
                title: title.isEmpty ? appName : "\(appName) — \(title)",
                subtitle: appName,
                pixelWidth: w, pixelHeight: h
            )
            return (filter, descriptor)
        case .camera:
            throw CaptureError.sourceUnavailable
        }
    }

    // MARK: Snapshots

    /// Captures a still at up to `maxDimension` px (0 = native) with ScreenCaptureKit,
    /// or grabs the latest camera frame.
    func snapshot(source: CaptureSourceID, maxDimension: Int, showsCursor: Bool, excludeOwnApp: Bool) async throws -> CGImage {
        #if DEBUG
        if source == TestPatternGenerator.sourceID, let image = TestPatternGenerator.snapshot(maxDimension: maxDimension) {
            return image
        }
        #endif
        if source.kind == .camera {
            let frame = lock.withLock { lastCameraFrame }
            guard let frame, let image = ImageCodec.cgImage(from: frame) else {
                throw CaptureError.snapshotFailed("The camera isn't running.")
            }
            return ImageCodec.scaled(image, maxDimension: maxDimension)
        }
        var filter = lock.withLock { filterSource == source ? self.filter : nil }
        if filter == nil {
            let made = try await makeFilter(for: source, excludeOwnApp: excludeOwnApp)
            filter = made.0
            lock.withLock {
                if self.stream == nil {
                    self.filter = made.0
                    self.filterSource = source
                }
            }
        }
        guard let filter else { throw CaptureError.sourceUnavailable }
        let configuration = SCStreamConfiguration()
        let (width, height) = Self.targetSize(for: filter, maxDimension: maxDimension)
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = showsCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .best
        configuration.scalesToFit = true
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            if !Self.hasScreenRecordingPermission { throw CaptureError.permissionDenied }
            throw CaptureError.snapshotFailed(error.localizedDescription)
        }
    }

    /// Forgets the cached filter (e.g. after the selected window closed).
    func invalidateFilter() {
        lock.lock()
        if stream == nil {
            filter = nil
            filterSource = nil
        }
        lock.unlock()
    }
}

extension CaptureService: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(sampleBuffer, pixelBuffer, wallClockNanos())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Capture stopped: \(error.localizedDescription, privacy: .public)")
        lock.lock()
        let isCurrent = self.stream === stream
        if isCurrent {
            self.stream = nil
            self.filter = nil
            self.filterSource = nil
        }
        lock.unlock()
        if isCurrent { onInterrupted?(error) }
    }
}

/// AVFoundation camera capture producing 420v frames.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let descriptor: CaptureSourceDescriptor
    private let session = AVCaptureSession()
    private let handler: (CMSampleBuffer, CVPixelBuffer) -> Void
    private let onInterrupted: (Error?) -> Void
    private var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []

    private init(descriptor: CaptureSourceDescriptor, handler: @escaping (CMSampleBuffer, CVPixelBuffer) -> Void, onInterrupted: @escaping (Error?) -> Void) {
        self.descriptor = descriptor
        self.handler = handler
        self.onInterrupted = onInterrupted
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Picks a preset and frame rate for the requested stream quality, so a
    /// Bluetooth viewer gets a small, slow stream instead of full-size frames.
    func apply(_ config: CaptureConfig) {
        session.beginConfiguration()
        let preset: AVCaptureSession.Preset
        switch config.maxDimension {
        case ..<900: preset = .vga640x480
        case ..<1400: preset = .hd1280x720
        case ..<2000: preset = .hd1920x1080
        default: preset = .high
        }
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
        session.commitConfiguration()
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let wanted = Double(max(1, config.fps))
        let supported = device.activeFormat.videoSupportedFrameRateRanges
        if let range = supported.first(where: { $0.minFrameRate <= wanted && wanted <= $0.maxFrameRate }) ?? supported.first {
            let fps = min(max(wanted, range.minFrameRate), range.maxFrameRate)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            self?.onInterrupted(note.userInfo?[AVCaptureSessionErrorKey] as? Error)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.onInterrupted(nil)
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice, device.uniqueID == self.device?.uniqueID else { return }
            self.onInterrupted(nil)
        })
    }

    static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
    }

    static func availableCameras() -> [CaptureSourceDescriptor] {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else { return [] }
        return discovery().devices.map { device in
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            return CaptureSourceDescriptor(
                source: CaptureSourceID(kind: .camera, id: device.uniqueID),
                title: device.localizedName,
                subtitle: "Camera",
                pixelWidth: Int(dimensions.width),
                pixelHeight: Int(dimensions.height)
            )
        }
    }

    static func start(
        deviceID: String,
        queue: DispatchQueue,
        config: CaptureConfig,
        handler: @escaping (CMSampleBuffer, CVPixelBuffer) -> Void,
        onInterrupted: @escaping (Error?) -> Void
    ) async throws -> CameraCapture {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CaptureError.cameraPermissionDenied }
        default:
            throw CaptureError.cameraPermissionDenied
        }
        // The chosen camera only — never a different one.
        guard let device = discovery().devices.first(where: { $0.uniqueID == deviceID }) else {
            throw CaptureError.sourceUnavailable
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let descriptor = CaptureSourceDescriptor(
            source: CaptureSourceID(kind: .camera, id: device.uniqueID),
            title: device.localizedName,
            subtitle: "Camera",
            pixelWidth: Int(dimensions.width),
            pixelHeight: Int(dimensions.height)
        )
        let capture = CameraCapture(descriptor: descriptor, handler: handler, onInterrupted: onInterrupted)
        try capture.configure(device: device, queue: queue)
        capture.device = device
        capture.apply(config)
        capture.observeInterruptions()
        capture.session.startRunning()
        return capture
    }

    private func configure(device: AVCaptureDevice, queue: DispatchQueue) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.sourceUnavailable }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.sourceUnavailable }
        session.addOutput(output)
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(sampleBuffer, pixelBuffer)
    }
}
