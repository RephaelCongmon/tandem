import CoreMedia
import CoreVideo
import Foundation
import os
import TandemCore

/// Encodes captured frames once and fans them out to every viewer, with
/// per-viewer flow control that keeps latency near one round trip:
///
/// - Each viewer acknowledges frames; a viewer only receives a new frame while
///   fewer than ~RTT/frame-interval + 1 frames are unacknowledged.
/// - If no viewer can take a frame, it isn't encoded at all (no queueing, no
///   forced keyframes). A viewer that misses a frame others received waits for
///   the next keyframe.
/// - Bitrate adapts to how often frames get skipped.
/// - The newest captured frame always wins: a frame arriving while the encoder
///   is busy replaces the pending one.
final class VideoFanout: @unchecked Sendable {
    struct Stats: Equatable {
        var framesPerSecond: Double = 0
        var bitrateKbps: Int = 0
        var width: Int = 0
        var height: Int = 0
    }

    private final class Viewer {
        let link: PeerLink
        var wantsVideo = false
        var quality: StreamQuality
        var needsKeyframe = true
        /// Just started or explicitly asked: gets a keyframe right away. A viewer
        /// that merely fell behind waits for the throttled/periodic keyframe.
        var keyframeUrgent = true
        var lastFormat: VideoFormat?
        var inflight: [(sequence: UInt32, sentAt: Double)] = []
        var rttMillis: Double = 20

        init(link: PeerLink, quality: StreamQuality) {
            self.link = link
            self.quality = quality
        }
    }

    private struct PendingFrame {
        var pixelBuffer: CVPixelBuffer
        var presentationTime: CMTime
        var capturedAtNanos: UInt64
    }

    var onStats: ((Stats) -> Void)?

    private let queue = DispatchQueue(label: "tandem.encode", qos: .userInteractive)
    private var viewers: [UUID: Viewer] = [:]
    private var encoder: H264Encoder?
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var sequence: UInt32 = 0
    private var targets: [Int64: [UUID]] = [:]
    private var lastFrame: PendingFrame?
    private var currentBitrateKbps = 8_000
    private var framesEncoded = 0
    private var framesSkipped = 0
    private var framesSentWindow = 0
    private var windowStart = monotonicSeconds()
    private var lastRefreshAt = 0.0
    private var refreshScheduled = false
    private var lastForcedKeyframeAt = 0.0

    private let slotLock = NSLock()
    private var slot: PendingFrame?
    private var slotScheduled = false

    private let log = Logger(subsystem: "com.rofel.tandem", category: "Fanout")

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.adapt() }
        timer.resume()
        adaptTimer = timer
    }

    private var adaptTimer: DispatchSourceTimer?

    deinit {
        adaptTimer?.cancel()
        encoder?.invalidate()
    }

    // MARK: Viewers

    func addViewer(id: UUID, link: PeerLink, quality: StreamQuality) {
        queue.async {
            self.viewers[id] = Viewer(link: link, quality: quality)
        }
    }

    func removeViewer(id: UUID) {
        queue.async {
            self.viewers[id] = nil
            if self.viewers.isEmpty {
                self.encoder?.invalidate()
                self.encoder = nil
                self.lastFrame = nil
            }
        }
    }

    func setViewer(id: UUID, wantsVideo: Bool, quality: StreamQuality) {
        queue.async {
            guard let viewer = self.viewers[id] else { return }
            let started = wantsVideo && !viewer.wantsVideo
            viewer.wantsVideo = wantsVideo
            viewer.quality = quality
            if started {
                viewer.needsKeyframe = true
                viewer.keyframeUrgent = true
                viewer.inflight.removeAll()
                self.refreshIfIdle()
            }
        }
    }

    func requestKeyframe(id: UUID) {
        queue.async {
            guard let viewer = self.viewers[id] else { return }
            viewer.needsKeyframe = true
            viewer.keyframeUrgent = true
            viewer.lastFormat = nil
            viewer.inflight.removeAll()
            self.refreshIfIdle()
        }
    }

    func acknowledge(id: UUID, sequence: UInt32, rttMillis: Double?) {
        queue.async {
            guard let viewer = self.viewers[id] else { return }
            viewer.inflight.removeAll { $0.sequence <= sequence }
            if let rttMillis { viewer.rttMillis = rttMillis }
        }
    }

    /// Clears everything (capture stopped or source switched).
    func resetStream() {
        queue.async {
            self.encoder?.invalidate()
            self.encoder = nil
            self.encoderWidth = 0
            self.encoderHeight = 0
            self.lastFrame = nil
            self.targets.removeAll()
            for viewer in self.viewers.values {
                viewer.needsKeyframe = true
                viewer.keyframeUrgent = true
                viewer.lastFormat = nil
                viewer.inflight.removeAll()
            }
        }
    }

    // MARK: Frames

    /// Called on the capture queue for every new frame.
    func submit(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, capturedAtNanos: UInt64) {
        slotLock.lock()
        slot = PendingFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime, capturedAtNanos: capturedAtNanos)
        let schedule = !slotScheduled
        slotScheduled = true
        slotLock.unlock()
        guard schedule else { return }
        queue.async { self.drainSlot() }
    }

    private func drainSlot() {
        slotLock.lock()
        let frame = slot
        slot = nil
        slotScheduled = false
        slotLock.unlock()
        guard let frame else { return }
        lastFrame = frame
        encode(frame)
    }

    /// Re-encodes the last frame so a viewer gets a keyframe even when the screen is
    /// static. Refreshes requested in quick succession are deferred, never dropped.
    private func refreshIfIdle() {
        guard lastFrame != nil else { return }
        let now = monotonicSeconds()
        let wait = 0.1 - (now - lastRefreshAt)
        if wait > 0 {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.refreshScheduled = false
                self?.refreshIfIdle()
            }
            return
        }
        guard var frame = lastFrame else { return }
        lastRefreshAt = now
        frame.presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        encode(frame)
    }

    private func encode(_ frame: PendingFrame) {
        let wanting = viewers.filter { $0.value.wantsVideo }
        guard !wanting.isEmpty else { return }
        let now = monotonicSeconds()
        let fps = wanting.values.map(\.quality.maxFPS).max() ?? 30
        let frameIntervalMillis = 1000 / Double(max(fps, 1))

        var eligible: [UUID] = []
        for (id, viewer) in wanting {
            // Drop acks that never came (keeps a lost ack from stalling forever).
            viewer.inflight.removeAll { now - $0.sentAt > 2 }
            let limit: Int
            if viewer.link.linkKind.isConstrained {
                limit = 1
            } else {
                limit = min(6, max(2, Int((viewer.rttMillis / frameIntervalMillis).rounded(.up)) + 1))
            }
            if viewer.inflight.count < limit { eligible.append(id) }
        }
        guard !eligible.isEmpty else {
            framesSkipped += 1
            return
        }
        for (id, viewer) in wanting where !eligible.contains(id) {
            viewer.needsKeyframe = true
        }

        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        if encoder == nil || width != encoderWidth || height != encoderHeight {
            encoder?.invalidate()
            let target = targetBitrate()
            currentBitrateKbps = min(currentBitrateKbps, target)
            if currentBitrateKbps < 300 { currentBitrateKbps = target }
            do {
                encoder = try H264Encoder(width: width, height: height, fps: fps, bitrateKbps: currentBitrateKbps) { [weak self] encoded in
                    self?.queue.async { self?.distribute(encoded) }
                }
                encoderWidth = width
                encoderHeight = height
                for viewer in viewers.values {
                    viewer.needsKeyframe = true
                    viewer.keyframeUrgent = true
                    viewer.lastFormat = nil
                }
            } catch {
                log.error("Encoder unavailable: \(error.localizedDescription, privacy: .public)")
                encoder = nil
                return
            }
        }
        encoder?.setFrameRate(fps)

        // Urgent viewers (new / asked) get a keyframe now; viewers that merely fell
        // behind get one at most once a second, so a slow viewer can't cause a storm.
        let urgent = eligible.contains { viewers[$0]?.keyframeUrgent == true }
        let lagging = eligible.contains { viewers[$0]?.needsKeyframe == true }
        let forceKeyframe = urgent || (lagging && now - lastForcedKeyframeAt > 1.0)
        if forceKeyframe { lastForcedKeyframeAt = now }
        targets[frame.presentationTime.value] = eligible
        do {
            try encoder?.encode(frame.pixelBuffer, presentationTime: frame.presentationTime, capturedAtNanos: frame.capturedAtNanos, forceKeyframe: forceKeyframe)
            framesEncoded += 1
        } catch {
            targets[frame.presentationTime.value] = nil
            log.error("Encode failed: \(error.localizedDescription, privacy: .public)")
        }
        if targets.count > 32 { targets.removeAll() }
    }

    private func distribute(_ encoded: EncodedFrame) {
        guard let recipients = targets.removeValue(forKey: encoded.presentationTime.value) else { return }
        sequence &+= 1
        let seq = sequence
        let micros = UInt64(max(0, encoded.presentationTime.seconds) * 1_000_000)
        let frame = VideoFrame(sequence: seq, isKeyframe: encoded.isKeyframe, presentationMicros: micros, capturedAtNanos: encoded.capturedAtNanos, data: encoded.data)
        let now = monotonicSeconds()
        for id in recipients {
            guard let viewer = viewers[id], viewer.wantsVideo else { continue }
            if viewer.needsKeyframe && !encoded.isKeyframe { continue }
            var formatToSend: VideoFormat?
            if encoded.isKeyframe, let format = encoded.format, viewer.needsKeyframe || viewer.lastFormat != format {
                formatToSend = format
                viewer.lastFormat = format
            }
            if encoded.isKeyframe {
                viewer.needsKeyframe = false
                viewer.keyframeUrgent = false
            }
            viewer.inflight.append((seq, now))
            framesSentWindow += 1
            let link = viewer.link
            let format = formatToSend
            link.queue.async {
                // Format rides the video queue so it stays ordered with frames.
                if let format { link.send(.videoFormat(format), priority: .video) }
                link.send(.videoFrame(frame), priority: .video)
            }
        }
    }

    // MARK: Adaptation

    private func targetBitrate() -> Int {
        let wanting = viewers.values.filter(\.wantsVideo)
        if wanting.contains(where: { $0.link.linkKind.isConstrained }) { return StreamQuality.bluetooth.maxBitrateKbps }
        return wanting.map(\.quality.maxBitrateKbps).max() ?? StreamQuality.balanced.maxBitrateKbps
    }

    private func adapt() {
        let now = monotonicSeconds()
        let elapsed = max(now - windowStart, 0.001)
        let total = framesEncoded + framesSkipped
        if let encoder, total > 0 {
            let skipRatio = Double(framesSkipped) / Double(total)
            let target = targetBitrate()
            var next = currentBitrateKbps
            if skipRatio > 0.15 {
                next = max(200, Int(Double(currentBitrateKbps) * 0.7))
            } else if skipRatio < 0.03 {
                next = min(target, Int(Double(currentBitrateKbps) * 1.12) + 50)
            }
            next = min(next, target)
            if next != currentBitrateKbps {
                currentBitrateKbps = next
                encoder.setBitrate(kbps: next)
            }
        }
        let stats = Stats(
            framesPerSecond: Double(framesSentWindow) / elapsed,
            bitrateKbps: encoder == nil ? 0 : currentBitrateKbps,
            width: encoderWidth,
            height: encoderHeight
        )
        framesEncoded = 0
        framesSkipped = 0
        framesSentWindow = 0
        windowStart = now
        onStats?(stats)
    }
}
