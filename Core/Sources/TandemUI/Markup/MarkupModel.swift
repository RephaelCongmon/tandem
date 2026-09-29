import CoreGraphics
import Foundation
import Observation

// MARK: - Palette & styles

/// An sRGB color with alpha, used by the markup geometry so the exporter and the
/// on-screen canvas resolve exactly the same color values.
public struct MarkupRGBA: Hashable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Creates an opaque color from a `0xRRGGBB` literal.
    public init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// The same color with a different alpha.
    public func withAlpha(_ alpha: CGFloat) -> MarkupRGBA {
        MarkupRGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The color as a `CGColor` in the sRGB color space.
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// The fixed markup palette. Colors are stored by name so saved documents stay
/// stable even if the exact tones are tuned later.
public enum MarkupColor: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case red, orange, yellow, green, blue, purple, white, black

    public var id: String { rawValue }

    /// The opaque sRGB value used for rendering.
    public var rgba: MarkupRGBA {
        switch self {
        case .red: return MarkupRGBA(hex: 0xFF3B30)
        case .orange: return MarkupRGBA(hex: 0xFF9500)
        case .yellow: return MarkupRGBA(hex: 0xFFCC00)
        case .green: return MarkupRGBA(hex: 0x34C759)
        case .blue: return MarkupRGBA(hex: 0x0A84FF)
        case .purple: return MarkupRGBA(hex: 0xAF52DE)
        case .white: return MarkupRGBA(hex: 0xFFFFFF)
        case .black: return MarkupRGBA(hex: 0x000000)
        }
    }

    /// Human-readable name for tooltips and accessibility.
    public var displayName: String { rawValue.capitalized }
}

/// Stroke weight (and text size) of an annotation. Widths are relative to the
/// image size, so a stroke looks the same on a 1× thumbnail and a 5K screenshot.
public enum MarkupLineWidth: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case thin, medium, thick

    public var id: String { rawValue }

    /// Stroke width as a fraction of the image's longest side.
    public var strokeFraction: CGFloat {
        switch self {
        case .thin: return 0.0016
        case .medium: return 0.0030
        case .thick: return 0.0055
        }
    }

    /// Text size as a fraction of the image height (see `MarkupGeometry.fontSize`).
    public var textFraction: CGFloat {
        switch self {
        case .thin: return 0.020
        case .medium: return 0.028
        case .thick: return 0.040
        }
    }

    /// Human-readable name for tooltips and accessibility.
    public var displayName: String { rawValue.capitalized }
}

/// How a redaction hides the pixels underneath it.
public enum RedactStyle: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    /// Coarse mosaic; keeps the layout recognizable but makes text unreadable.
    case pixelate
    /// Opaque black box.
    case solid

    public var id: String { rawValue }

    /// Human-readable name for tooltips and accessibility.
    public var displayName: String {
        switch self {
        case .pixelate: return "Pixelate"
        case .solid: return "Black Out"
        }
    }
}

// MARK: - Document

/// A single markup element. All coordinates are normalized to the full,
/// uncropped image (0…1, origin top-left), so annotations survive re-cropping
/// and render identically at any resolution.
public struct MarkupAnnotation: Codable, Hashable, Sendable, Identifiable {
    /// What an annotation draws.
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case rectangle, highlight, arrow, pen, text, redact

        /// Rectangle-like kinds are defined by two corner points and can be resized.
        public var isRectLike: Bool {
            switch self {
            case .rectangle, .highlight, .redact: return true
            case .arrow, .pen, .text: return false
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Normalized points (0…1, origin top-left).
    /// - rectangle / highlight / redact: two opposite corners (any order)
    /// - arrow: start, end
    /// - pen: path points in drawing order
    /// - text: the top-left corner of the text's layout box
    public var points: [CGPoint]
    public var color: MarkupColor
    public var lineWidth: MarkupLineWidth
    /// The label for `.text` annotations.
    public var text: String?
    /// The redaction style for `.redact` annotations (defaults to pixelate when nil).
    public var redactStyle: RedactStyle?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        points: [CGPoint],
        color: MarkupColor = .red,
        lineWidth: MarkupLineWidth = .medium,
        text: String? = nil,
        redactStyle: RedactStyle? = nil
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.redactStyle = redactStyle
    }

    /// The normalized rectangle spanned by the first two points (rect-like kinds).
    public var normalizedRect: CGRect? {
        guard points.count >= 2 else { return nil }
        return CGRect(corner: points[0], opposite: points[1])
    }

    /// The effective redaction style (pixelate unless set otherwise).
    public var effectiveRedactStyle: RedactStyle { redactStyle ?? .pixelate }

    /// Returns a copy with every point offset by a normalized delta.
    public func translated(dx: CGFloat, dy: CGFloat) -> MarkupAnnotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    /// The normalized bounding box of the annotation's points (ignores stroke width and text extent).
    public var normalizedPointBounds: CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Non-destructive markup for one screenshot: a list of annotations plus an
/// optional crop. The source image is never modified; `MarkupRenderer` bakes
/// the document into a new image on export.
public struct MarkupDocument: Codable, Hashable, Sendable {
    /// Annotations in creation order. Redactions always render first, then
    /// highlights, then everything else (see `MarkupGeometry.renderOrder`).
    public var annotations: [MarkupAnnotation]
    /// Normalized crop rectangle (0…1, origin top-left) in full-image space;
    /// `nil` exports the whole image.
    public var crop: CGRect?

    public init(annotations: [MarkupAnnotation] = [], crop: CGRect? = nil) {
        self.annotations = annotations
        self.crop = crop
    }

    /// `true` when the document has no annotations and no crop, i.e. exporting
    /// it would reproduce the source image.
    public var isEmpty: Bool { annotations.isEmpty && crop == nil }

    /// `true` when at least one redaction is present.
    public var containsRedactions: Bool { annotations.contains { $0.kind == .redact } }

    /// Looks up an annotation by id.
    public func annotation(id: UUID) -> MarkupAnnotation? {
        annotations.first { $0.id == id }
    }
}

extension CGRect {
    /// The standardized rectangle spanned by two opposite corners.
    init(corner a: CGPoint, opposite b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The unit square used for normalized coordinates.
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
}

// MARK: - Tools

/// Editor tools, in toolbar order.
public enum MarkupTool: String, CaseIterable, Hashable, Sendable, Identifiable {
    case select, rectangle, arrow, pen, highlight, text, redact, crop

    public var id: String { rawValue }

    /// The single-key shortcut that activates the tool.
    public var shortcut: Character {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .arrow: return "a"
        case .pen: return "p"
        case .highlight: return "h"
        case .text: return "t"
        case .redact: return "x"
        case .crop: return "c"
        }
    }

    /// Human-readable name for tooltips and accessibility.
    public var displayName: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .arrow: return "Arrow"
        case .pen: return "Pen"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .redact: return "Redact"
        case .crop: return "Crop"
        }
    }

    /// SF Symbol shown in the toolbar.
    public var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .redact: return "eye.slash"
        case .crop: return "crop"
        }
    }

    /// The annotation kind this tool creates, if any.
    public var annotationKind: MarkupAnnotation.Kind? {
        switch self {
        case .rectangle: return .rectangle
        case .arrow: return .arrow
        case .pen: return .pen
        case .highlight: return .highlight
        case .text: return .text
        case .redact: return .redact
        case .select, .crop: return nil
        }
    }

    /// The tool that creates annotations of `kind`.
    public static func tool(for kind: MarkupAnnotation.Kind) -> MarkupTool {
        switch kind {
        case .rectangle: return .rectangle
        case .arrow: return .arrow
        case .pen: return .pen
        case .highlight: return .highlight
        case .text: return .text
        case .redact: return .redact
        }
    }

    /// Whether the tool's annotations use the color palette.
    public var usesColor: Bool {
        switch self {
        case .rectangle, .arrow, .pen, .highlight, .text: return true
        case .select, .redact, .crop: return false
        }
    }

    /// Whether the tool's annotations use the line-width picker.
    public var usesLineWidth: Bool {
        switch self {
        case .rectangle, .arrow, .pen, .text: return true
        case .select, .highlight, .redact, .crop: return false
        }
    }
}

// MARK: - Editor state

/// The in-place text editing session of the text tool.
public struct MarkupTextSession: Hashable, Sendable {
    /// The id the committed annotation will use (an existing annotation's id when editing).
    public var id: UUID
    /// Normalized top-left anchor of the text box.
    public var anchor: CGPoint
    public var text: String
    public var color: MarkupColor
    public var lineWidth: MarkupLineWidth
    /// `true` when editing an annotation that already exists in the document.
    public var isEditingExisting: Bool
}

/// Undoable editing model behind `SnapshotEditorView`.
///
/// Every mutating call is one undo step, except changes made between
/// `beginInteractiveChange()` and `endInteractiveChange()`, which coalesce into
/// a single step (one drag = one undo). Undo snapshots whole documents; they
/// are small value types, so this stays cheap and exact.
@MainActor
@Observable
public final class MarkupEditorState {
    /// The document being edited.
    public private(set) var document: MarkupDocument

    /// The active tool. Switching tools commits any in-progress text.
    public var tool: MarkupTool = .rectangle {
        didSet {
            guard tool != oldValue else { return }
            commitTextEditing()
            draft = nil
            if tool != .select { selection = nil }
        }
    }

    /// Default stroke weight for new annotations.
    public var lineWidth: MarkupLineWidth = .medium
    /// Default style for new redactions.
    public var redactStyle: RedactStyle = .pixelate
    /// The selected annotation (select tool).
    public var selection: UUID?
    /// The shape currently being drawn; rendered live but not yet part of the document.
    public var draft: MarkupAnnotation?
    /// The active text editing session, if any.
    public var textSession: MarkupTextSession?

    /// Remembered color per tool, so the highlighter can stay yellow while arrows stay red.
    private var toolColors: [MarkupTool: MarkupColor] = [.highlight: .yellow]
    private var undoStack: [MarkupDocument] = []
    private var redoStack: [MarkupDocument] = []
    @ObservationIgnored private var interactionSnapshot: MarkupDocument?

    /// Maximum number of undo steps kept.
    public static let undoLimit = 200

    public init(document: MarkupDocument = MarkupDocument()) {
        self.document = document
    }

    // MARK: Styling

    /// The color used for new annotations with the current tool.
    public var color: MarkupColor {
        get { color(for: tool) }
        set { toolColors[tool] = newValue }
    }

    /// The remembered color for `tool` (red unless changed; yellow for the highlighter).
    public func color(for tool: MarkupTool) -> MarkupColor {
        toolColors[tool] ?? .red
    }

    /// The selected annotation, if it still exists.
    public var selectedAnnotation: MarkupAnnotation? {
        selection.flatMap { document.annotation(id: $0) }
    }

    /// Sets the color for the current tool and, when an annotation is selected,
    /// recolors it (one undo step).
    public func applyColor(_ newColor: MarkupColor) {
        if tool == .select, var annotation = selectedAnnotation {
            toolColors[MarkupTool.tool(for: annotation.kind)] = newColor
            guard annotation.color != newColor else { return }
            annotation.color = newColor
            update(annotation)
        } else {
            color = newColor
        }
        if var session = textSession { session.color = newColor; textSession = session }
    }

    /// Sets the default stroke weight and, when an annotation is selected, applies it (one undo step).
    public func applyLineWidth(_ width: MarkupLineWidth) {
        lineWidth = width
        if var session = textSession { session.lineWidth = width; textSession = session }
        if tool == .select, var annotation = selectedAnnotation, annotation.lineWidth != width {
            annotation.lineWidth = width
            update(annotation)
        }
    }

    /// Sets the default redaction style and, when a redaction is selected, applies it (one undo step).
    public func applyRedactStyle(_ style: RedactStyle) {
        redactStyle = style
        if tool == .select, var annotation = selectedAnnotation, annotation.kind == .redact,
           annotation.effectiveRedactStyle != style {
            annotation.redactStyle = style
            update(annotation)
        }
    }

    // MARK: Editing

    /// Appends an annotation (one undo step).
    public func add(_ annotation: MarkupAnnotation) {
        mutate { $0.annotations.append(annotation) }
    }

    /// Replaces the annotation with the same id. Inside an interactive change
    /// the update coalesces with the rest of the gesture; otherwise it is one undo step.
    public func update(_ annotation: MarkupAnnotation) {
        guard let index = document.annotations.firstIndex(where: { $0.id == annotation.id }),
              document.annotations[index] != annotation else { return }
        mutate { $0.annotations[index] = annotation }
    }

    /// Removes an annotation (one undo step).
    public func delete(id: UUID) {
        guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        mutate { $0.annotations.remove(at: index) }
        if selection == id { selection = nil }
    }

    /// Removes the selected annotation, if any. Returns whether something was deleted.
    @discardableResult
    public func deleteSelection() -> Bool {
        guard let id = selection, document.annotation(id: id) != nil else { return false }
        delete(id: id)
        return true
    }

    /// Moves the selected annotation by a normalized delta, keeping it on the image (one undo step).
    public func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let annotation = selectedAnnotation else { return }
        let bounds = annotation.normalizedPointBounds
        let clampedDX = min(max(dx, -bounds.minX), 1 - bounds.maxX)
        let clampedDY = min(max(dy, -bounds.minY), 1 - bounds.maxY)
        update(annotation.translated(dx: clampedDX, dy: clampedDY))
    }

    /// Sets (or clears) the normalized crop rectangle. The rect is clamped to
    /// the image; a crop covering the whole image is stored as `nil`.
    public func setCrop(_ crop: CGRect?) {
        let normalized = Self.normalizedCrop(crop)
        guard normalized != document.crop else { return }
        mutate { $0.crop = normalized }
    }

    /// Removes the crop (one undo step).
    public func resetCrop() { setCrop(nil) }

    /// Removes all annotations and the crop (one undo step).
    public func resetAll() {
        cancelTextEditing()
        draft = nil
        selection = nil
        guard !document.isEmpty else { return }
        mutate { $0 = MarkupDocument() }
    }

    /// Clamps a crop to the unit square; returns `nil` for crops that cover
    /// (practically) the whole image or have no area.
    public static func normalizedCrop(_ crop: CGRect?) -> CGRect? {
        guard let crop else { return nil }
        let clamped = crop.standardized.intersection(.unit)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        let epsilon: CGFloat = 0.0005
        if clamped.minX <= epsilon, clamped.minY <= epsilon,
           clamped.maxX >= 1 - epsilon, clamped.maxY >= 1 - epsilon {
            return nil
        }
        return clamped
    }

    // MARK: Coalescing

    /// `true` between `beginInteractiveChange()` and `endInteractiveChange()`.
    public var isInteracting: Bool { interactionSnapshot != nil }

    /// Starts coalescing: all mutations until `endInteractiveChange()` become one undo step.
    public func beginInteractiveChange() {
        guard interactionSnapshot == nil else { return }
        interactionSnapshot = document
    }

    /// Ends coalescing, recording one undo step if the document changed.
    public func endInteractiveChange() {
        guard let snapshot = interactionSnapshot else { return }
        interactionSnapshot = nil
        if snapshot != document { pushUndo(snapshot) }
    }

    /// Ends coalescing and reverts everything changed since `beginInteractiveChange()`.
    public func cancelInteractiveChange() {
        guard let snapshot = interactionSnapshot else { return }
        interactionSnapshot = nil
        document = snapshot
        pruneSelection()
    }

    // MARK: Undo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Reverts the last undo step.
    public func undo() {
        endInteractiveChange()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        pruneSelection()
    }

    /// Re-applies the last undone step.
    public func redo() {
        endInteractiveChange()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        pruneSelection()
    }

    private func mutate(_ change: (inout MarkupDocument) -> Void) {
        let before = document
        change(&document)
        guard document != before, interactionSnapshot == nil else { return }
        pushUndo(before)
    }

    private func pushUndo(_ snapshot: MarkupDocument) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
    }

    private func pruneSelection() {
        if let id = selection, document.annotation(id: id) == nil { selection = nil }
    }

    // MARK: Text editing

    /// Starts editing a new text annotation at a normalized anchor (top-left of the text box).
    public func beginTextEditing(at anchor: CGPoint) {
        commitTextEditing()
        textSession = MarkupTextSession(
            id: UUID(),
            anchor: anchor,
            text: "",
            color: color(for: .text),
            lineWidth: lineWidth,
            isEditingExisting: false
        )
    }

    /// Starts editing an existing text annotation in place.
    public func beginTextEditing(existing id: UUID) {
        commitTextEditing()
        guard let annotation = document.annotation(id: id), annotation.kind == .text,
              let anchor = annotation.points.first else { return }
        selection = nil
        textSession = MarkupTextSession(
            id: id,
            anchor: anchor,
            text: annotation.text ?? "",
            color: annotation.color,
            lineWidth: annotation.lineWidth,
            isEditingExisting: true
        )
    }

    /// Commits the text session: adds or updates the annotation, or removes it
    /// when the text is empty (one undo step). No-op without a session.
    public func commitTextEditing() {
        guard let session = textSession else { return }
        textSession = nil
        let text = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if session.isEditingExisting { delete(id: session.id) }
            return
        }
        let annotation = MarkupAnnotation(
            id: session.id,
            kind: .text,
            points: [session.anchor],
            color: session.color,
            lineWidth: session.lineWidth,
            text: text
        )
        if session.isEditingExisting {
            update(annotation)
        } else {
            add(annotation)
        }
    }

    /// Discards the text session without touching the document.
    public func cancelTextEditing() {
        textSession = nil
    }
}
