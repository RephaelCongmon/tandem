import AVFoundation
import CoreMedia
import Foundation
import os
import TandemCore

/// Live-view health, published to the UI about twice a second.
struct LiveStats: Equatable {
    var framesPerSecond: Double = 0
    /// Capture-to-display latency estimate (includes network and decode).
    var latencyMillis: Double?
    var width = 0
    var height = 0
    var bitrateKbps: Double = 0
    var lastFrameAt: Date?
}

/// Decodes the Source's H.264 stream straight into an `AVSampleBufferDisplayLayer`.
/// Runs entirely on the link queue: no main-thread work per frame.
final class LiveVideoRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer

    /// Stats, delivered on the main actor.
    var onStats: (@MainActor (LiveStats) -> Void)?
    /// First frame after a (re)start was displayed.
    var onFirstFrame: (@MainActor () -> Void)?

    private let factory = VideoSampleBufferFactory()
    private let factoryLock = NSLock()
    private let lock = NSLock()
    private var frames = 0
    private var bytes = 0
    private var latencySamples: [Double] = []
    private var windowStart = monotonicSeconds()
    private var lastKeyframeRequest = 0.0
    private var hasShownFrame = false
    private var dimensions = (0, 0)
    private let log = Logger(subsystem: "com.rofel.tandem", category: "LiveVideo")

    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false
    }

    /// Handles one video message on `link.queue`.
    func handle(_ message: PeerMessage, link: PeerLink) {
        let renderer = displayLayer.sampleBufferRenderer
        switch message {
        case .videoFormat(let format):
            factoryLock.lock()
            defer { factoryLock.unlock() }
            do {
                if try factory.update(format: format) {
                    renderer.flush()
                    lock.lock()
                    dimensions = (format.width, format.height)
                    lock.unlock()
                }
            } catch {
                log.error("Bad video format: \(String(describing: error), privacy: .public)")
                requestKeyframe(link: link)
            }

        case .videoFrame(let frame):
            // Ack first so the Source can keep the pipeline full.
            link.send(.control(.videoAck(VideoAck(sequence: frame.sequence))))
            factoryLock.lock()
            defer { factoryLock.unlock() }
            guard factory.formatDescription != nil else {
                requestKeyframe(link: link)
                return
            }
            if renderer.status == .failed {
                log.info("Renderer failed; flushing and requesting a keyframe")
                renderer.flush()
                requestKeyframe(link: link)
                if !frame.isKeyframe { return }
            }
            do {
                let sample = try factory.makeSampleBuffer(for: frame)
                renderer.enqueue(sample)
            } catch {
                requestKeyframe(link: link)
                return
            }
            recordFrame(frame, link: link)

        default:
            break
        }
    }

    private func requestKeyframe(link: PeerLink) {
        let now = monotonicSeconds()
        guard now - lastKeyframeRequest > 0.5 else { return }
        lastKeyframeRequest = now
        link.send(.control(.keyframeRequest))
    }

    private func recordFrame(_ frame: VideoFrame, link: PeerLink) {
        let now = monotonicSeconds()
        let offset = link.stats.clockOffsetNanos
        lock.lock()
        frames += 1
        bytes += frame.data.count
        if let offset {
            // capturedAt is on the Source's clock; convert to ours.
            let capturedLocal = Int64(bitPattern: frame.capturedAtNanos) - offset
            let latency = Double(Int64(bitPattern: wallClockNanos()) - capturedLocal) / 1_000_000
            if latency > -50, latency < 10_000 { latencySamples.append(max(0, latency)) }
        }
        let first = !hasShownFrame
        hasShownFrame = true
        let elapsed = now - windowStart
        var stats: LiveStats?
        if elapsed >= 0.5 {
            let sorted = latencySamples.sorted()
            stats = LiveStats(
                framesPerSecond: Double(frames) / elapsed,
                latencyMillis: sorted.isEmpty ? nil : sorted[sorted.count / 2],
                width: dimensions.0,
                height: dimensions.1,
                bitrateKbps: Double(bytes * 8) / elapsed / 1000,
                lastFrameAt: Date()
            )
            frames = 0
            bytes = 0
            latencySamples.removeAll(keepingCapacity: true)
            windowStart = now
        }
        lock.unlock()
        if first, let onFirstFrame { onMain { onFirstFrame() } }
        if let stats, let onStats { onMain { onStats(stats) } }
    }

    /// Clears the picture (new connection or stream stopped).
    func reset() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        factoryLock.lock()
        factory.reset()
        factoryLock.unlock()
        lock.lock()
        hasShownFrame = false
        frames = 0
        bytes = 0
        latencySamples.removeAll()
        windowStart = monotonicSeconds()
        lock.unlock()
    }
}
