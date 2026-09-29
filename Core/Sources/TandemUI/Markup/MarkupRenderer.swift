import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

// MARK: - Coordinate space

/// Maps normalized image coordinates (0…1, origin top-left) into a target
/// coordinate space with a top-left origin: image pixels for export, view
/// points for the on-screen canvas. Sharing this mapping (and `MarkupGeometry`)
/// is what keeps the editor preview identical to the exported image.
public struct MarkupSpace: Hashable, Sendable {
    /// Where the full, uncropped image lies in the target space.
    public var imageRect: CGRect
    /// The source image's size in pixels; relative stroke widths derive from it.
    public var imagePixelSize: CGSize

    public init(imageRect: CGRect, imagePixelSize: CGSize) {
        self.imageRect = imageRect
        self.imagePixelSize = imagePixelSize
    }

    /// The identity space: one unit per image pixel.
    public init(pixelSize: CGSize) {
        self.init(imageRect: CGRect(origin: .zero, size: pixelSize), imagePixelSize: pixelSize)
    }

    /// Target units per image pixel.
    public var scale: CGFloat {
        imagePixelSize.width > 0 ? imageRect.width / imagePixelSize.width : 1
    }

    /// Converts a normalized point into the target space.
    public func point(_ normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + normalized.x * imageRect.width,
            y: imageRect.minY + normalized.y * imageRect.height
        )
    }

    /// Converts a target-space point into normalized image coordinates (unclamped).
    public func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRect.width > 0 ? (point.x - imageRect.minX) / imageRect.width : 0,
            y: imageRect.height > 0 ? (point.y - imageRect.minY) / imageRect.height : 0
        )
    }

    /// Converts a normalized rect into the target space.
    public func rect(_ normalized: CGRect) -> CGRect {
        CGRect(corner: point(normalized.origin), opposite: point(CGPoint(x: normalized.maxX, y: normalized.maxY)))
    }

    /// Converts a target-space rect into normalized image coordinates.
    public func normalizedRect(_ rect: CGRect) -> CGRect {
        CGRect(corner: normalized(rect.origin), opposite: normalized(CGPoint(x: rect.maxX, y: rect.maxY)))
    }
}

// MARK: - Drawing primitives

/// One vector drawing operation produced by `MarkupGeometry`. The exporter
/// draws primitives into a `CGContext`; the editor draws the same primitives
/// into a SwiftUI `Canvas`.
public struct MarkupPrimitive {
    /// Fill or stroke. Strokes always use round caps and joins.
    public enum Style: Hashable, Sendable {
        case fill
        case stroke(width: CGFloat)
    }

    /// Path in the target space (top-left origin).
    public var path: CGPath
    public var style: Style
    public var color: MarkupRGBA

    public init(path: CGPath, style: Style, color: MarkupRGBA) {
        self.path = path
        self.style = style
        self.color = color
    }
}

/// A redacted region in the target space.
public struct MarkupRedaction: Hashable, Sendable {
    public var rect: CGRect
    public var style: RedactStyle
}

/// Everything needed to draw a document, grouped into passes in paint order:
/// 1. `redactions` (drawn over the source image),
/// 2. `multiplyPrimitives` (highlighter fills, multiply blend mode),
/// 3. `overlayPrimitives` (highlighter tints, then all other ink, normal blend mode).
public struct MarkupScene {
    public var redactions: [MarkupRedaction] = []
    public var multiplyPrimitives: [MarkupPrimitive] = []
    public var overlayPrimitives: [MarkupPrimitive] = []
}

/// Text laid out as glyph outlines, so the exporter and the canvas draw
/// exactly the same shapes.
public struct MarkupTextLayout {
    /// Glyph outlines in pixel units, origin at the layout box's top-left, y down.
    public let path: CGPath
    /// Typographic size of the layout box in pixel units.
    public let size: CGSize
    /// Font size in pixel units.
    public let fontSize: CGFloat
    /// Distance from the top of the box to the first baseline.
    public let ascent: CGFloat
    /// Distance between baselines.
    public let lineHeight: CGFloat
}

// MARK: - Geometry

/// Shared markup geometry: stroke metrics, shape paths, hit testing and paint
/// order. Used by both `MarkupRenderer` and the on-screen editor canvas.
public enum MarkupGeometry {
    /// Paint layers, bottom to top.
    public enum Layer: Int, Comparable, Sendable {
        case redaction, highlight, ink

        public static func < (lhs: Layer, rhs: Layer) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Alpha of the highlighter's multiply pass (keeps dark text dark on light backgrounds).
    public static let highlightMultiplyAlpha: CGFloat = 0.35
    /// Alpha of the highlighter's normal-blend tint (keeps it visible on dark backgrounds).
    public static let highlightTintAlpha: CGFloat = 0.15

    /// The layer an annotation kind paints into.
    public static func layer(for kind: MarkupAnnotation.Kind) -> Layer {
        switch kind {
        case .redact: return .redaction
        case .highlight: return .highlight
        case .rectangle, .arrow, .pen, .text: return .ink
        }
    }

    /// Annotations in paint order: redactions, then highlights, then ink, each
    /// group keeping document order. The last element is the topmost.
    public static func renderOrder(_ annotations: [MarkupAnnotation]) -> [MarkupAnnotation] {
        annotations.enumerated()
            .sorted { lhs, rhs in
                let l = layer(for: lhs.element.kind), r = layer(for: rhs.element.kind)
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    // MARK: Metrics

    /// The image dimension stroke widths are relative to (its longest side).
    public static func referenceLength(for imageSize: CGSize) -> CGFloat {
        max(imageSize.width, imageSize.height, 1)
    }

    /// Stroke width in image pixels.
    public static func strokeWidth(_ width: MarkupLineWidth, imageSize: CGSize) -> CGFloat {
        max(2, width.strokeFraction * referenceLength(for: imageSize))
    }

    /// Text size in image pixels: relative to the image height, capped for very
    /// tall images so long scrolling captures don't get giant labels.
    public static func fontSize(_ width: MarkupLineWidth, imageSize: CGSize) -> CGFloat {
        max(10, width.textFraction * min(imageSize.height, imageSize.width * 1.6))
    }

    // MARK: Scene

    /// Builds all drawing passes for `annotations` in `space`.
    /// - Parameter hiddenID: an annotation to leave out (e.g. text being edited in place).
    public static func scene(for annotations: [MarkupAnnotation], in space: MarkupSpace, hiddenID: UUID? = nil) -> MarkupScene {
        var scene = MarkupScene()
        var highlightTints: [MarkupPrimitive] = []
        var ink: [MarkupPrimitive] = []
        for annotation in renderOrder(annotations) where annotation.id != hiddenID {
            switch layer(for: annotation.kind) {
            case .redaction:
                if let redaction = redaction(for: annotation, in: space) { scene.redactions.append(redaction) }
            case .highlight:
                guard let rect = annotation.normalizedRect.map(space.rect) else { continue }
                let path = CGPath(rect: rect, transform: nil)
                scene.multiplyPrimitives.append(
                    MarkupPrimitive(path: path, style: .fill, color: annotation.color.rgba.withAlpha(highlightMultiplyAlpha))
                )
                highlightTints.append(
                    MarkupPrimitive(path: path, style: .fill, color: annotation.color.rgba.withAlpha(highlightTintAlpha))
                )
            case .ink:
                ink.append(contentsOf: primitives(for: annotation, in: space))
            }
        }
        scene.overlayPrimitives = highlightTints + ink
        return scene
    }

    /// The redacted region of a `.redact` annotation.
    public static func redaction(for annotation: MarkupAnnotation, in space: MarkupSpace) -> MarkupRedaction? {
        guard annotation.kind == .redact, let rect = annotation.normalizedRect else { return nil }
        return MarkupRedaction(rect: space.rect(rect), style: annotation.effectiveRedactStyle)
    }

    /// Vector primitives for a single ink annotation (rectangle, arrow, pen, text).
    /// Highlights and redactions are produced by `scene(for:in:hiddenID:)`.
    public static func primitives(for annotation: MarkupAnnotation, in space: MarkupSpace) -> [MarkupPrimitive] {
        let width = strokeWidth(annotation.lineWidth, imageSize: space.imagePixelSize) * space.scale
        let color = annotation.color.rgba
        switch annotation.kind {
        case .rectangle:
            guard let normalized = annotation.normalizedRect else { return [] }
            let rect = space.rect(normalized)
            let radius = max(0, min(width * 1.2, rect.width / 2, rect.height / 2))
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            return [MarkupPrimitive(path: path, style: .stroke(width: width), color: color)]

        case .arrow:
            guard annotation.points.count >= 2 else { return [] }
            return arrowPrimitives(from: space.point(annotation.points[0]), to: space.point(annotation.points[1]), width: width, color: color)

        case .pen:
            let points = annotation.points.map(space.point)
            guard let first = points.first else { return [] }
            if points.count == 1 {
                let dot = CGPath(ellipseIn: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width), transform: nil)
                return [MarkupPrimitive(path: dot, style: .fill, color: color)]
            }
            return [MarkupPrimitive(path: smoothedPath(through: points), style: .stroke(width: width), color: color)]

        case .text:
            guard let text = annotation.text, !text.isEmpty, let anchor = annotation.points.first else { return [] }
            let fontSize = fontSize(annotation.lineWidth, imageSize: space.imagePixelSize)
            let layout = textLayout(text, fontSize: fontSize)
            let origin = space.point(anchor)
            var transform = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: space.scale, y: space.scale)
            guard let path = layout.path.copy(using: &transform) else { return [] }
            let outline = annotation.color == .black ? MarkupRGBA(hex: 0xFFFFFF, alpha: 0.8) : MarkupRGBA(hex: 0x000000, alpha: 0.4)
            return [
                MarkupPrimitive(path: path, style: .stroke(width: fontSize * 0.1 * space.scale), color: outline),
                MarkupPrimitive(path: path, style: .fill, color: color)
            ]

        case .highlight, .redact:
            return []
        }
    }

    /// Arrow shaft plus a filled head whose size is proportional to the stroke width.
    static func arrowPrimitives(from start: CGPoint, to end: CGPoint, width: CGFloat, color: MarkupRGBA) -> [MarkupPrimitive] {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return [] }
        let ux = dx / length, uy = dy / length
        let headLength = min(width * 4.5, length)
        let halfWidth = max(headLength * 0.45, width * 0.75)
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
        head.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        head.closeSubpath()

        var primitives: [MarkupPrimitive] = []
        let shaftLength = length - headLength * 0.9
        if shaftLength > 0 {
            let shaft = CGMutablePath()
            shaft.move(to: start)
            shaft.addLine(to: CGPoint(x: start.x + ux * shaftLength, y: start.y + uy * shaftLength))
            primitives.append(MarkupPrimitive(path: shaft, style: .stroke(width: width), color: color))
        }
        primitives.append(MarkupPrimitive(path: head, style: .fill, color: color))
        // A thin stroke softens the head's corners to match the round-capped shaft.
        primitives.append(MarkupPrimitive(path: head, style: .stroke(width: width * 0.35), color: color))
        return primitives
    }

    /// A smooth path through `points`: quadratic curves between midpoints,
    /// using each point as the control point.
    public static func smoothedPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points[points.count - 1])
            return path
        }
        for index in 1..<(points.count - 1) {
            let control = points[index], next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: Text

    private final class TextLayoutBox {
        let layout: MarkupTextLayout
        init(_ layout: MarkupTextLayout) { self.layout = layout }
    }

    private static let textLayoutCache: NSCache<NSString, TextLayoutBox> = {
        let cache = NSCache<NSString, TextLayoutBox>()
        cache.countLimit = 256
        return cache
    }()

    /// The bold rounded system font used for text annotations.
    public static func textFont(size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        if let descriptor = base.fontDescriptor.withDesign(.rounded), let rounded = NSFont(descriptor: descriptor, size: size) {
            return rounded as CTFont
        }
        return base as CTFont
    }

    /// Lays out `text` (one line per newline) as glyph outlines at `fontSize`
    /// pixels. Results are cached, so calling this every frame is cheap.
    /// Glyphs without outlines (e.g. color emoji) are skipped.
    public static func textLayout(_ text: String, fontSize: CGFloat) -> MarkupTextLayout {
        let key = "\(fontSize)|\(text)" as NSString
        if let cached = textLayoutCache.object(forKey: key) { return cached.layout }

        let font = textFont(size: fontSize)
        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        let path = CGMutablePath()
        let lines = text.components(separatedBy: .newlines)
        var maxWidth: CGFloat = 0

        for (lineIndex, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            maxWidth = max(maxWidth, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
            let baseline = CGFloat(lineIndex) * lineHeight + ascent
            let runs = (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? []
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = (attributes[NSAttributedString.Key.font] as? NSFont).map { $0 as CTFont } ?? font
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for index in 0..<count {
                    // Flip glyph outlines (y up) into the layout's y-down space.
                    var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[index].x, ty: baseline - positions[index].y)
                    if let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[index], &transform) {
                        path.addPath(glyphPath)
                    }
                }
            }
        }

        let layout = MarkupTextLayout(
            path: path,
            size: CGSize(width: maxWidth, height: CGFloat(max(lines.count, 1)) * lineHeight),
            fontSize: fontSize,
            ascent: ascent,
            lineHeight: lineHeight
        )
        textLayoutCache.setObject(TextLayoutBox(layout), forKey: key)
        return layout
    }

    /// The text layout box of a `.text` annotation in `space`.
    public static func textFrame(for annotation: MarkupAnnotation, in space: MarkupSpace) -> CGRect? {
        guard annotation.kind == .text, let anchor = annotation.points.first else { return nil }
        let layout = textLayout(annotation.text ?? "", fontSize: fontSize(annotation.lineWidth, imageSize: space.imagePixelSize))
        let origin = space.point(anchor)
        return CGRect(x: origin.x, y: origin.y, width: layout.size.width * space.scale, height: layout.size.height * space.scale)
    }

    // MARK: Bounds, handles & hit testing

    /// Visual bounds of an annotation in `space`, including stroke width.
    public static func bounds(of annotation: MarkupAnnotation, in space: MarkupSpace) -> CGRect {
        let width = strokeWidth(annotation.lineWidth, imageSize: space.imagePixelSize) * space.scale
        switch annotation.kind {
        case .rectangle:
            return annotation.normalizedRect.map { space.rect($0).insetBy(dx: -width / 2, dy: -width / 2) } ?? .null
        case .highlight, .redact:
            return annotation.normalizedRect.map(space.rect) ?? .null
        case .arrow:
            let outset = max(width * 4.5 * 0.45, width)
            return space.rect(annotation.normalizedPointBounds).insetBy(dx: -outset, dy: -outset)
        case .pen:
            return space.rect(annotation.normalizedPointBounds).insetBy(dx: -width / 2, dy: -width / 2)
        case .text:
            return textFrame(for: annotation, in: space) ?? .null
        }
    }

    /// Draggable handles of an annotation in `space`: the four corners
    /// (top-left, top-right, bottom-right, bottom-left) for rect-like kinds,
    /// start and end for arrows, none otherwise.
    public static func handles(for annotation: MarkupAnnotation, in space: MarkupSpace) -> [CGPoint] {
        if annotation.kind.isRectLike, let normalized = annotation.normalizedRect {
            let rect = space.rect(normalized)
            return [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)
            ]
        }
        if annotation.kind == .arrow, annotation.points.count >= 2 {
            return annotation.points.prefix(2).map(space.point)
        }
        return []
    }

    /// The topmost annotation under `point` (target space), or `nil`.
    ///
    /// Strokes, text, highlights and redactions are hit first (within
    /// `tolerance`); the empty interior of a rectangle only counts when nothing
    /// else was hit, so a big box never blocks the marks inside it.
    public static func hitTest(_ point: CGPoint, annotations: [MarkupAnnotation], in space: MarkupSpace, tolerance: CGFloat = 6) -> UUID? {
        let topmostFirst = Array(renderOrder(annotations).reversed())
        if let hit = topmostFirst.first(where: { isPoint(point, onStrokeOf: $0, in: space, tolerance: tolerance) }) {
            return hit.id
        }
        return topmostFirst.first { annotation in
            annotation.kind == .rectangle && (annotation.normalizedRect.map(space.rect)?.contains(point) ?? false)
        }?.id
    }

    private static func isPoint(_ point: CGPoint, onStrokeOf annotation: MarkupAnnotation, in space: MarkupSpace, tolerance: CGFloat) -> Bool {
        let width = strokeWidth(annotation.lineWidth, imageSize: space.imagePixelSize) * space.scale
        switch annotation.kind {
        case .rectangle:
            guard let rect = annotation.normalizedRect.map(space.rect) else { return false }
            return distance(from: point, toBorderOf: rect) <= tolerance + width / 2
        case .highlight, .redact, .text:
            return bounds(of: annotation, in: space).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .arrow:
            guard annotation.points.count >= 2 else { return false }
            let start = space.point(annotation.points[0]), end = space.point(annotation.points[1])
            return distance(from: point, toSegment: start, end) <= tolerance + width
        case .pen:
            let points = annotation.points.map(space.point)
            guard let first = points.first else { return false }
            if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= tolerance + width / 2 }
            return zip(points, points.dropFirst()).contains { distance(from: point, toSegment: $0, $1) <= tolerance + width / 2 }
        }
    }

    /// Distance from `point` to the segment `a`–`b`.
    public static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Distance from `point` to the outline of `rect` (inside or outside).
    public static func distance(from point: CGPoint, toBorderOf rect: CGRect) -> CGFloat {
        if rect.contains(point) {
            return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
        }
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    // MARK: Constraints

    /// Constrains a drag so the spanned rectangle is square (Shift-drag).
    public static func squareConstrained(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    /// Snaps the direction from `start` to `end` to multiples of 45° (Shift-drag).
    public static func angleConstrained(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }
}

// MARK: - Renderer

/// Bakes a `MarkupDocument` into a new image at the source's full resolution.
public enum MarkupRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Renders `document` over `image`: redactions first, then highlights and
    /// other annotations, then the crop. The result is 8-bit, premultiplied
    /// sRGB; sRGB inputs come through pixel-identical outside of markup.
    ///
    /// Pixelated redactions fall back to solid black if Core Image fails, so a
    /// redacted region can never leak into the output.
    /// - Returns: The rendered image, or `nil` if a bitmap context can't be created.
    public static func render(_ image: CGImage, document: MarkupDocument) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let context = makeContext(width: width, height: height) else { return nil }
        let size = CGSize(width: width, height: height)
        let bounds = CGRect(origin: .zero, size: size)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)

        let scene = MarkupGeometry.scene(for: document.annotations, in: MarkupSpace(pixelSize: size))

        // Redactions, in Core Graphics' native bottom-left coordinates, snapped
        // outward to whole pixels so no partially covered pixel survives.
        if !scene.redactions.isEmpty {
            let needsPixelation = scene.redactions.contains { $0.style == .pixelate }
            let pixelated = needsPixelation ? pixelatedImage(for: image) : nil
            for redaction in scene.redactions {
                let rect = redaction.rect.integral.intersection(bounds)
                guard !rect.isNull, !rect.isEmpty else { continue }
                let deviceRect = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
                if redaction.style == .pixelate, let pixelated {
                    context.saveGState()
                    context.clip(to: deviceRect)
                    context.draw(pixelated, in: bounds)
                    context.restoreGState()
                } else {
                    context.setFillColor(MarkupRGBA(hex: 0x000000).cgColor)
                    context.fill(deviceRect)
                }
            }
        }

        // Vector markup, in the shared top-left geometry.
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.multiply)
        scene.multiplyPrimitives.forEach { draw($0, in: context) }
        context.setBlendMode(.normal)
        scene.overlayPrimitives.forEach { draw($0, in: context) }
        context.restoreGState()

        guard let rendered = context.makeImage() else { return nil }
        guard let crop = document.crop else { return rendered }
        let pixelRect = pixelCropRect(for: crop, imageSize: size)
        guard !pixelRect.isEmpty else { return rendered }
        return rendered.cropping(to: pixelRect)
    }

    /// The crop in whole pixels (origin top-left): `crop × imageSize`, rounded
    /// and clamped to the image. Returns `.zero` for an empty crop.
    public static func pixelCropRect(for crop: CGRect, imageSize: CGSize) -> CGRect {
        let clamped = crop.standardized.intersection(.unit)
        guard !clamped.isNull, imageSize.width >= 1, imageSize.height >= 1 else { return .zero }
        let width = min(max(1, (clamped.width * imageSize.width).rounded()), imageSize.width)
        let height = min(max(1, (clamped.height * imageSize.height).rounded()), imageSize.height)
        let x = min(max(0, (clamped.minX * imageSize.width).rounded()), imageSize.width - width)
        let y = min(max(0, (clamped.minY * imageSize.height).rounded()), imageSize.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Pixelation block size in pixels: 1/60 of the image width, at least 12 px,
    /// so text is unreadable at any resolution.
    public static func pixelationBlockSize(forImageWidth width: Int) -> CGFloat {
        max(12, (CGFloat(width) / 60).rounded())
    }

    /// A fully pixelated copy of `image` (same size, sRGB). Each block is the
    /// local average color: the image is blurred before `CIPixellate` samples it.
    /// The editor computes this once and clips it into redaction rects, so the
    /// preview matches the export exactly.
    public static func pixelatedImage(for image: CGImage) -> CGImage? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let block = pixelationBlockSize(forImageWidth: image.width)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent().applyingGaussianBlur(sigma: Double(block) / 2)
        filter.scale = Float(block)
        filter.center = CGPoint(x: extent.minX, y: extent.maxY)
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        return ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: sRGB)
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func draw(_ primitive: MarkupPrimitive, in context: CGContext) {
        context.addPath(primitive.path)
        switch primitive.style {
        case .fill:
            context.setFillColor(primitive.color.cgColor)
            context.fillPath()
        case .stroke(let width):
            context.setStrokeColor(primitive.color.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }
}
