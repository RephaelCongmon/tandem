import CoreGraphics
import Foundation

// MARK: - Aspect fit & view-space conversion

public extension MarkupSpace {
    /// The rectangle an image of `imageSize` occupies when aspect-fit and
    /// centered in `bounds`. Returns a zero-size rect at the center of `bounds`
    /// when either size is empty.
    static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        let bounds = bounds.standardized
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// A space that shows an image of `imagePixelSize` aspect-fit and centered
    /// in `bounds` (for example view points with a top-left origin).
    static func aspectFit(imagePixelSize: CGSize, in bounds: CGRect) -> MarkupSpace {
        MarkupSpace(imageRect: aspectFitRect(for: imagePixelSize, in: bounds), imagePixelSize: imagePixelSize)
    }

    /// Converts a target-space point into normalized image coordinates,
    /// clamped to the image (0…1).
    func clampedNormalized(_ point: CGPoint) -> CGPoint {
        let normalized = normalized(point)
        return CGPoint(x: min(max(normalized.x, 0), 1), y: min(max(normalized.y, 0), 1))
    }

    /// Clamps a target-space point to the image rectangle.
    func clampedToImage(_ point: CGPoint) -> CGPoint {
        point.clamped(to: imageRect)
    }

    /// The target-space region of a normalized redaction rectangle, snapped
    /// outward to whole image pixels exactly like `MarkupRenderer` does, so the
    /// preview never covers less than the export.
    func pixelSnappedRect(_ normalized: CGRect) -> CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return rect(normalized) }
        let pixelBounds = CGRect(origin: .zero, size: imagePixelSize)
        let pixels = MarkupSpace(pixelSize: imagePixelSize).rect(normalized).integral.intersection(pixelBounds)
        guard !pixels.isNull else { return .null }
        let snapped = CGRect(
            x: pixels.minX / imagePixelSize.width,
            y: pixels.minY / imagePixelSize.height,
            width: pixels.width / imagePixelSize.width,
            height: pixels.height / imagePixelSize.height
        )
        return rect(snapped)
    }

    /// The target-space region the renderer keeps for `crop` (rounded to whole
    /// pixels, see `MarkupRenderer.pixelCropRect(for:imageSize:)`).
    func exportedCropRect(_ crop: CGRect) -> CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return rect(crop) }
        let pixels = MarkupRenderer.pixelCropRect(for: crop, imageSize: imagePixelSize)
        guard !pixels.isEmpty else { return rect(crop) }
        return rect(CGRect(
            x: pixels.minX / imagePixelSize.width,
            y: pixels.minY / imagePixelSize.height,
            width: pixels.width / imagePixelSize.width,
            height: pixels.height / imagePixelSize.height
        ))
    }

    /// Redactions of `annotations` in paint order, pixel-snapped like the export.
    func snappedRedactions(for annotations: [MarkupAnnotation]) -> [MarkupRedaction] {
        MarkupGeometry.renderOrder(annotations).compactMap { annotation in
            guard annotation.kind == .redact, let normalized = annotation.normalizedRect else { return nil }
            let rect = pixelSnappedRect(normalized)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            return MarkupRedaction(rect: rect, style: annotation.effectiveRedactStyle)
        }
    }
}

extension CGPoint {
    /// The point moved into `rect` (unchanged if already inside).
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }

    /// Euclidean distance to `other`.
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}

// MARK: - Editor layout

/// Fixed layout of the snapshot editor's canvas.
enum SnapshotEditorLayout {
    /// Room kept free around the image: the top leaves space for the floating toolbar.
    static let insetTop: CGFloat = 72
    static let insetSide: CGFloat = 28
    static let insetBottom: CGFloat = 28

    /// The area the image is fit into, for a canvas of `size`.
    static func imageBounds(in size: CGSize) -> CGRect {
        CGRect(
            x: insetSide,
            y: insetTop,
            width: max(0, size.width - insetSide * 2),
            height: max(0, size.height - insetTop - insetBottom)
        )
    }

    /// The view space of the canvas: the image aspect-fit and centered inside `imageBounds(in:)`.
    static func space(imagePixelSize: CGSize, canvasSize: CGSize) -> MarkupSpace {
        MarkupSpace.aspectFit(imagePixelSize: imagePixelSize, in: imageBounds(in: canvasSize))
    }
}

// MARK: - Drag constraints

/// Pure drag math shared by the editor's gestures. All points are in view space.
enum MarkupDragGeometry {
    /// The end point of a rectangle-like drag from `start` toward `end`, kept
    /// inside `bounds`. With `square`, the spanned rectangle stays square (in view
    /// space, i.e. square on the image) and shrinks rather than leaving `bounds`.
    static func rectEnd(from start: CGPoint, to end: CGPoint, square: Bool, within bounds: CGRect) -> CGPoint {
        let start = start.clamped(to: bounds)
        guard square else { return end.clamped(to: bounds) }
        let squared = MarkupGeometry.squareConstrained(from: start, to: end)
        let dx = squared.x - start.x, dy = squared.y - start.y
        let roomX = dx < 0 ? start.x - bounds.minX : bounds.maxX - start.x
        let roomY = dy < 0 ? start.y - bounds.minY : bounds.maxY - start.y
        let side = min(abs(dx), roomX, roomY)
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    /// The end point of an arrow drag, kept inside `bounds`. With `snap`, the
    /// direction snaps to 45° steps and the arrow shortens along that direction
    /// rather than leaving `bounds`.
    static func arrowEnd(from start: CGPoint, to end: CGPoint, snap: Bool, within bounds: CGRect) -> CGPoint {
        let start = start.clamped(to: bounds)
        guard snap else { return end.clamped(to: bounds) }
        let snapped = MarkupGeometry.angleConstrained(from: start, to: end)
        let dx = snapped.x - start.x, dy = snapped.y - start.y
        var t: CGFloat = 1
        if snapped.x > bounds.maxX, dx > 0 { t = min(t, (bounds.maxX - start.x) / dx) }
        if snapped.x < bounds.minX, dx < 0 { t = min(t, (bounds.minX - start.x) / dx) }
        if snapped.y > bounds.maxY, dy > 0 { t = min(t, (bounds.maxY - start.y) / dy) }
        if snapped.y < bounds.minY, dy < 0 { t = min(t, (bounds.minY - start.y) / dy) }
        t = max(0, t)
        return CGPoint(x: start.x + dx * t, y: start.y + dy * t).clamped(to: bounds)
    }
}

// MARK: - Crop geometry

/// One of the eight handles of the crop rectangle.
enum MarkupCropHandle: CaseIterable, Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Which vertical edge the handle drags: -1 = left, 1 = right, 0 = neither.
    var horizontal: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: return -1
        case .topRight, .right, .bottomRight: return 1
        case .top, .bottom: return 0
        }
    }

    /// Which horizontal edge the handle drags: -1 = top, 1 = bottom, 0 = neither.
    var vertical: Int {
        switch self {
        case .topLeft, .top, .topRight: return -1
        case .bottomLeft, .bottom, .bottomRight: return 1
        case .left, .right: return 0
        }
    }

    var isCorner: Bool { horizontal != 0 && vertical != 0 }

    /// The handle's location on `rect` (top-left origin).
    func position(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: horizontal < 0 ? rect.minX : (horizontal > 0 ? rect.maxX : rect.midX),
            y: vertical < 0 ? rect.minY : (vertical > 0 ? rect.maxY : rect.midY)
        )
    }
}

/// Pure crop math. Rectangles passed to `resize`/`move`/`enforcingMinimumSize`
/// are normalized (0…1); hit testing works in view space.
enum MarkupCropGeometry {
    /// The handle under `point`: the nearest corner within `cornerRadius`,
    /// otherwise any edge within `edgeTolerance` of its line.
    static func handle(at point: CGPoint, in rect: CGRect, cornerRadius: CGFloat = 14, edgeTolerance: CGFloat = 8) -> MarkupCropHandle? {
        let corners: [MarkupCropHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        let nearestCorner = corners
            .map { ($0, $0.position(in: rect).distance(to: point)) }
            .min { $0.1 < $1.1 }
        if let nearestCorner, nearestCorner.1 <= cornerRadius { return nearestCorner.0 }

        let edges: [(MarkupCropHandle, CGPoint, CGPoint)] = [
            (.top, CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
        ]
        let nearestEdge = edges
            .map { ($0.0, MarkupGeometry.distance(from: point, toSegment: $0.1, $0.2)) }
            .min { $0.1 < $1.1 }
        if let nearestEdge, nearestEdge.1 <= edgeTolerance { return nearestEdge.0 }
        return nil
    }

    /// `rect` with the edges of `handle` moved by `delta`, staying inside the
    /// unit square and at least `minSize` large (or its current size, if smaller).
    static func resize(_ rect: CGRect, handle: MarkupCropHandle, by delta: CGVector, minSize: CGSize) -> CGRect {
        let rect = rect.standardized
        let minWidth = min(minSize.width, rect.width), minHeight = min(minSize.height, rect.height)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle.horizontal {
        case -1: minX = min(max(0, rect.minX + delta.dx), maxX - minWidth)
        case 1: maxX = max(min(1, rect.maxX + delta.dx), minX + minWidth)
        default: break
        }
        switch handle.vertical {
        case -1: minY = min(max(0, rect.minY + delta.dy), maxY - minHeight)
        case 1: maxY = max(min(1, rect.maxY + delta.dy), minY + minHeight)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `rect` moved by `delta`, kept inside the unit square.
    static func move(_ rect: CGRect, by delta: CGVector) -> CGRect {
        let rect = rect.standardized
        let x = min(max(0, rect.minX + delta.dx), max(0, 1 - rect.width))
        let y = min(max(0, rect.minY + delta.dy), max(0, 1 - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// `rect` grown to at least `minSize`, shifted back inside the unit square if needed.
    static func enforcingMinimumSize(_ rect: CGRect, minSize: CGSize) -> CGRect {
        let rect = rect.standardized
        let width = min(1, max(rect.width, minSize.width))
        let height = min(1, max(rect.height, minSize.height))
        let x = min(max(0, rect.minX), 1 - width)
        let y = min(max(0, rect.minY), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
