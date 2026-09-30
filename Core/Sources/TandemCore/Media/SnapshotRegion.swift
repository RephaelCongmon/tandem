import CoreGraphics
import Foundation

/// Part of a picture, in top-left coordinates normalized to 0…1.
public struct SnapshotRegion: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = SnapshotRegion(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// A drag on the stage (view coordinates, top-left origin) over the video drawn in
    /// `video`. Clamped to the video; nil for a click, a sliver, or a drag beside it.
    public init?(selection: CGRect, in video: CGRect, minimumPoints: CGFloat = 6) {
        let clipped = selection.standardized.intersection(video)
        guard !clipped.isNull, video.width > 0, video.height > 0,
              clipped.width >= minimumPoints, clipped.height >= minimumPoints else { return nil }
        self.init(
            x: Double((clipped.minX - video.minX) / video.width),
            y: Double((clipped.minY - video.minY) / video.height),
            width: Double(clipped.width / video.width),
            height: Double(clipped.height / video.height)
        )
    }

    /// Whole pixels covering the region, or nil for invalid geometry: a bad region
    /// must never quietly become the full screen.
    public func pixelRect(width pixelWidth: Int, height pixelHeight: Int) -> CGRect? {
        let tolerance = 1e-9
        guard [x, y, width, height].allSatisfy(\.isFinite), pixelWidth > 0, pixelHeight > 0,
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1 + tolerance, y + height <= 1 + tolerance else { return nil }
        let w = Double(pixelWidth), h = Double(pixelHeight)
        let left = (x * w + tolerance).rounded(.down)
        let top = (y * h + tolerance).rounded(.down)
        let right = min(w, ((x + width) * w - tolerance).rounded(.up))
        let bottom = min(h, ((y + height) * h - tolerance).rounded(.up))
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Crops without copying pixels (the result shares the image's backing store).
    public func cropped(from image: CGImage) -> CGImage? {
        guard let rect = pixelRect(width: image.width, height: image.height) else { return nil }
        return image.cropping(to: rect)
    }

    /// Where content of `size` is drawn inside `bounds` with aspect-fit gravity.
    public static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}

/// Asks the Source to hold a native-resolution still for region crops.
public struct SnapshotFreeze: Codable, Sendable, Hashable {
    /// Capture time (Source clock) of the live frame the Studio froze on screen. When
    /// nothing newer was captured, the still matches it and the Source replies
    /// `snapshotUnchanged` instead of sending a preview.
    public var displayedFrameNanos: UInt64?

    public init(displayedFrameNanos: UInt64?) {
        self.displayedFrameNanos = displayedFrameNanos
    }

    /// The Studio's frozen frame still shows the screen: no newer frame was captured.
    public static func displayedFrameIsCurrent(displayed: UInt64?, latestCaptured: UInt64?) -> Bool {
        guard let displayed, let latestCaptured else { return false }
        return latestCaptured <= displayed
    }
}

/// Asks for a region of a still held after a `SnapshotFreeze` request.
public struct SnapshotCrop: Codable, Sendable, Hashable {
    /// The id of the freeze request.
    public var frozenID: UUID
    public var region: SnapshotRegion

    public init(frozenID: UUID, region: SnapshotRegion) {
        self.frozenID = frozenID
        self.region = region
    }
}
