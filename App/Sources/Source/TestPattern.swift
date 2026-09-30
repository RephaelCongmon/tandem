#if DEBUG
import AppKit
import CoreMedia
import CoreVideo
import TandemCore

/// Debug-only synthetic capture source: an animated pattern with a millisecond
/// clock, so the full pipeline (encode → network → decode → display → snapshot →
/// AI) can be exercised without Screen Recording permission.
final class TestPatternGenerator: @unchecked Sendable {
    static let sourceID = CaptureSourceID(kind: .display, id: "tandem-test-pattern")
    static let descriptor = CaptureSourceDescriptor(source: sourceID, title: "Test Pattern (Debug)", subtitle: "Synthetic", pixelWidth: 1920, pixelHeight: 1080)
    /// `TANDEM_TEST_PATTERN_STATIC=1`: one unchanging frame, like an idle screen.
    static let isStatic = ProcessInfo.processInfo.environment["TANDEM_TEST_PATTERN_STATIC"] == "1"

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameIndex = 0
    private let width: Int
    private let height: Int
    private let handler: (CMSampleBuffer, CVPixelBuffer, UInt64) -> Void

    init(queue: DispatchQueue, maxDimension: Int, handler: @escaping (CMSampleBuffer, CVPixelBuffer, UInt64) -> Void) {
        self.queue = queue
        let scale = maxDimension > 0 && maxDimension < 1920 ? Double(maxDimension) / 1920 : 1
        width = Int(1920 * scale) & ~1
        height = Int(1080 * scale) & ~1
        self.handler = handler
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }

    func start(fps: Int) {
        if Self.isStatic {
            queue.async { [weak self] in self?.emit() }
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, fps)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func emit() {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return }
        frameIndex += 1
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer),
           let context = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: ImageCodec.srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
           ) {
            Self.draw(in: context, width: width, height: height, frame: Self.isStatic ? 0 : frameIndex)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        handler(sample, buffer, wallClockNanos())
    }

    static func snapshot(maxDimension: Int) -> CGImage? {
        let width = 1920
        let height = 1080
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: ImageCodec.srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(in: context, width: width, height: height, frame: isStatic ? 0 : Int(Date().timeIntervalSince1970 * 60))
        return context.makeImage().map { ImageCodec.scaled($0, maxDimension: maxDimension) }
    }

    private static func draw(in context: CGContext, width: Int, height: Int, frame: Int) {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let colors = [CGColor(srgbRed: 0.10, green: 0.08, blue: 0.22, alpha: 1), CGColor(srgbRed: 0.03, green: 0.05, blue: 0.09, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: ImageCodec.srgb, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }
        // Color bars
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(0.49, 0.36, 1), (0.2, 0.81, 0.95), (0.18, 0.83, 0.58), (0.97, 0.7, 0.17), (1, 0.3, 0.37)]
        for (index, color) in bars.enumerated() {
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(CGRect(x: w * 0.08 + CGFloat(index) * w * 0.17, y: h * 0.1, width: w * 0.15, height: h * 0.08))
        }
        // Moving marker
        let t = CGFloat(frame % 240) / 240
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: w * 0.08 + t * w * 0.8, y: h * 0.26, width: h * 0.05, height: h * 0.05))

        // Text: clock with milliseconds + frame counter.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let lines = [
            ("Tandem test pattern", h * 0.05, NSColor.white.withAlphaComponent(0.7)),
            (isStatic ? "static screen" : formatter.string(from: Date()), h * 0.14, NSColor.white),
            ("frame \(frame)", h * 0.04, NSColor.white.withAlphaComponent(0.6))
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var y = h * 0.78
        for (text, size, color) in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
                .foregroundColor: color
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let bounds = string.size()
            string.draw(at: CGPoint(x: (w - bounds.width) / 2, y: y - bounds.height))
            y -= bounds.height + h * 0.03
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
