import CoreGraphics
import Foundation

/// A rectangle in top-left image coordinates, normalized to 0…1.
public struct SnapshotRegion: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Reject invalid geometry rather than accidentally returning the full screen.
    public func pixelRect(width pixelWidth: Int, height pixelHeight: Int) -> CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.000000001, y + height <= 1.000000001,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let left = floor(x * Double(pixelWidth))
        let top = floor(y * Double(pixelHeight))
        let right = min(Double(pixelWidth), ceil((x + width) * Double(pixelWidth)))
        let bottom = min(Double(pixelHeight), ceil((y + height) * Double(pixelHeight)))
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public func cropped(from image: CGImage) -> CGImage? {
        guard let rect = pixelRect(width: image.width, height: image.height) else { return nil }
        return image.cropping(to: rect)
    }

    /// Convert a drag in an aspect-fit preview into image coordinates.
    public static func selection(from start: CGPoint, to end: CGPoint, imageRect: CGRect) -> SnapshotRegion? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(start),
              [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite) else { return nil }
        let end = CGPoint(x: min(max(end.x, imageRect.minX), imageRect.maxX),
                          y: min(max(end.y, imageRect.minY), imageRect.maxY))
        let width = abs(end.x - start.x), height = abs(end.y - start.y)
        guard width >= 4, height >= 4 else { return nil }
        return SnapshotRegion(x: (min(start.x, end.x) - imageRect.minX) / imageRect.width,
                              y: (min(start.y, end.y) - imageRect.minY) / imageRect.height,
                              width: width / imageRect.width, height: height / imageRect.height)
    }
}
