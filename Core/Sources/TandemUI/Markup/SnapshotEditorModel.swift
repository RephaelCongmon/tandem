import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Observation

/// A key press as seen by the snapshot editor.
struct SnapshotEditorKeyEvent: Sendable {
    /// Hardware key code (`kVK_*`).
    var keyCode: UInt16
    /// `charactersIgnoringModifiers`.
    var characters: String
    var modifiers: NSEvent.ModifierFlags
    /// `true` when the window's first responder is a text view (e.g. a field editor).
    var isTextInputActive: Bool = false
    /// `true` while an input method is composing (marked text).
    var hasMarkedText: Bool = false

    init(keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [], isTextInputActive: Bool = false, hasMarkedText: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.isTextInputActive = isTextInputActive
        self.hasMarkedText = hasMarkedText
    }
}

/// What the editor did with a key press.
enum SnapshotEditorKeyResult: Equatable, Sendable {
    /// Not an editor shortcut; let the event continue.
    case ignored
    /// Consumed by the editor.
    case handled
    /// The user asked to close the editor without changes.
    case cancel
    /// The user asked to finish editing.
    case done
}

/// The pointer shape for a location on the canvas.
enum SnapshotEditorCursor: Equatable, Sendable {
    case arrow, crosshair, iBeam, openHand, resizeLeftRight, resizeUpDown

    var nsCursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .crosshair: return .crosshair
        case .iBeam: return .iBeam
        case .openHand: return .openHand
        case .resizeLeftRight: return .resizeLeftRight
        case .resizeUpDown: return .resizeUpDown
        }
    }
}

/// Interaction controller behind `SnapshotEditorView`: turns drags, clicks and
/// key presses (in view space) into edits of a `MarkupEditorState`, owns the
/// cached pixelated preview, and runs the full-resolution export.
///
/// The view stays a thin shell over this type, so the gesture logic is testable
/// without a window.
@MainActor
@Observable
final class SnapshotEditorModel {
    /// Status of the pixelated copy used to preview pixelate redactions.
    enum PixelationStatus: Equatable, Sendable {
        case idle, loading, ready, failed
    }

    /// Drags shorter than this (in points) are clicks and don't create shapes.
    static let minimumDragDistance: CGFloat = 3
    /// Hit-test tolerance around strokes, in points.
    static let hitTolerance: CGFloat = 6
    /// Grab radius of selection handles, in points.
    static let handleHitRadius: CGFloat = 9
    /// Smallest crop side, in points.
    static let minimumCropSide: CGFloat = 24
    /// Minimum spacing between recorded pen samples, in points.
    static let penSampleSpacing: CGFloat = 1.5
    /// Two presses within this distance (points) and the double-click interval form a double click.
    static let doubleClickDistance: CGFloat = 5
    /// Arrow-key nudge in points (×10 with Shift).
    static let nudgeDistance: CGFloat = 1

    /// The source image, drawn once and never re-rendered while editing.
    let image: CGImage
    let imagePixelSize: CGSize
    /// The undoable document state.
    let state: MarkupEditorState

    /// `image` fully pixelated (computed once, off the main thread, on first need).
    private(set) var pixelatedPreview: CGImage?
    private(set) var pixelationStatus: PixelationStatus = .idle
    /// `true` while a crop drag is in progress (shows rule-of-thirds guides).
    private(set) var isCropDragging = false
    /// `true` while the full-resolution export renders.
    private(set) var isExporting = false
    /// A user-facing export failure message, if the last export failed.
    var exportError: String?

    /// The canvas's current view space (kept up to date by the view; used for keyboard nudges).
    @ObservationIgnored var viewSpace: MarkupSpace?
    /// Double-click interval; `NSEvent.doubleClickInterval` by default.
    @ObservationIgnored var doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval

    private enum Operation {
        /// Drawing a two-point shape (rectangle, highlight, redaction, arrow).
        case draw(kind: MarkupAnnotation.Kind, id: UUID, start: CGPoint)
        /// Drawing a freehand stroke; `points` are normalized, `last` is in view space.
        case pen(id: UUID, points: [CGPoint], last: CGPoint)
        /// Moving an existing annotation. `editOnClick` turns a click into text editing (text tool).
        case move(original: MarkupAnnotation, editOnClick: Bool)
        /// Dragging a selection handle (rect corner or arrow endpoint) from `handleStart`.
        case resize(original: MarkupAnnotation, handle: Int, handleStart: CGPoint)
        /// Text tool press on empty canvas: places a label on release.
        case placeText(at: CGPoint)
        case cropNew(start: CGPoint)
        case cropMove(original: CGRect)
        case cropResize(original: CGRect, handle: MarkupCropHandle)
        /// A press that does nothing further (or a cancelled drag).
        case inert
    }

    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private var dragStart: CGPoint = .zero
    @ObservationIgnored private var dragMaxDistance: CGFloat = 0
    @ObservationIgnored private var lastDragPoint: CGPoint = .zero
    @ObservationIgnored private var lastDragSpace: MarkupSpace?
    @ObservationIgnored private var lastPress: (time: TimeInterval, location: CGPoint)?
    @ObservationIgnored private var pixelationTask: Task<Void, Never>?

    init(image: CGImage, document: MarkupDocument = MarkupDocument()) {
        self.image = image
        self.imagePixelSize = CGSize(width: image.width, height: image.height)
        self.state = MarkupEditorState(document: document)
    }

    // MARK: Derived UI state

    /// The tool whose style controls (color, width, redaction style) the toolbar shows.
    var styleTool: MarkupTool? {
        if state.textSession != nil { return .text }
        if state.tool == .select { return state.selectedAnnotation.map { MarkupTool.tool(for: $0.kind) } }
        return state.tool
    }

    /// The color the palette shows as selected.
    var displayedColor: MarkupColor {
        if let session = state.textSession { return session.color }
        if state.tool == .select, let annotation = state.selectedAnnotation { return annotation.color }
        return state.color
    }

    /// The stroke weight the width picker shows as selected.
    var displayedLineWidth: MarkupLineWidth {
        if let session = state.textSession { return session.lineWidth }
        if state.tool == .select, let annotation = state.selectedAnnotation { return annotation.lineWidth }
        return state.lineWidth
    }

    /// The redaction style the picker shows as selected.
    var displayedRedactStyle: RedactStyle {
        if state.tool == .select, let annotation = state.selectedAnnotation, annotation.kind == .redact {
            return annotation.effectiveRedactStyle
        }
        return state.redactStyle
    }

    /// The id of the annotation hidden from the canvas because it's being edited in place.
    var hiddenAnnotationID: UUID? {
        guard let session = state.textSession, session.isEditingExisting else { return nil }
        return session.id
    }

    /// Annotations to draw: the document plus the in-progress draft.
    var displayedAnnotations: [MarkupAnnotation] {
        guard let draft = state.draft else { return state.document.annotations }
        return state.document.annotations + [draft]
    }

    /// Pixel size of the exported image (the crop, or the whole image).
    var outputPixelSize: CGSize {
        guard let crop = state.document.crop else { return imagePixelSize }
        return MarkupRenderer.pixelCropRect(for: crop, imageSize: imagePixelSize).size
    }

    // MARK: Commands

    /// Called when the editor appears.
    func editorDidAppear() {
        if state.document.containsRedactions || state.tool == .redact { preparePixelation() }
    }

    /// Activates `tool` (commits any open text label).
    func select(tool: MarkupTool) {
        guard !isDragging else { return }
        state.tool = tool
        if tool == .redact { preparePixelation() }
    }

    func applyColor(_ color: MarkupColor) { state.applyColor(color) }
    func applyLineWidth(_ width: MarkupLineWidth) { state.applyLineWidth(width) }
    func applyRedactStyle(_ style: RedactStyle) { state.applyRedactStyle(style) }

    func undo() {
        cancelDrag()
        state.undo()
    }

    func redo() {
        cancelDrag()
        state.redo()
    }

    func resetAll() {
        cancelDrag()
        state.resetAll()
    }

    func resetCrop() {
        cancelDrag()
        state.resetCrop()
    }

    func deleteSelection() {
        cancelDrag()
        state.deleteSelection()
    }

    // MARK: Pixelated preview

    /// Starts computing the pixelated preview once (no-op if already started).
    func preparePixelation() {
        guard pixelationStatus == .idle else { return }
        pixelationStatus = .loading
        let image = image
        pixelationTask = Task { [weak self] in
            let pixelated = await Task.detached(priority: .userInitiated) {
                MarkupRenderer.pixelatedImage(for: image)
            }.value
            guard let self else { return }
            self.pixelatedPreview = pixelated
            // If Core Image fails, the preview shows black, which is also what the export falls back to.
            self.pixelationStatus = pixelated == nil ? .failed : .ready
        }
    }

    /// Waits for a pixelation started by `preparePixelation()`.
    func waitForPixelation() async {
        await pixelationTask?.value
    }

    // MARK: Export

    /// Commits pending edits and delivers the document with its full-resolution
    /// rendering. An empty document delivers the untouched source image. The
    /// render runs off the main thread; while it runs further calls are ignored.
    /// On failure `exportError` is set and `completion` isn't called, so an
    /// unredacted image can never be sent by accident.
    func finish(_ completion: @escaping @MainActor (MarkupDocument, CGImage) -> Void) {
        guard !isExporting else { return }
        cancelDrag()
        state.commitTextEditing()
        exportError = nil
        let document = state.document
        if document.isEmpty {
            completion(document, image)
            return
        }
        isExporting = true
        let image = image
        Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                MarkupRenderer.render(image, document: document)
            }.value
            guard let self else { return }
            self.isExporting = false
            if let rendered {
                completion(document, rendered)
            } else {
                self.exportError = "Couldn’t render the image. Try again."
            }
        }
    }

    // MARK: Keyboard

    /// Interprets a key press. Tool shortcuts never fire while a text field is
    /// being edited; Esc and Return then end the text session instead. Esc
    /// otherwise cancels the innermost thing: a drag, then the selection, then
    /// the editor.
    func handleKey(_ event: SnapshotEditorKeyEvent) -> SnapshotEditorKeyResult {
        let modifiers = event.modifiers.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)
        let isReturn = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter

        if isReturn && modifiers == .command { return .done }

        if state.textSession != nil || event.isTextInputActive {
            guard state.textSession != nil, !event.hasMarkedText, modifiers.isEmpty else { return .ignored }
            if keyCode == kVK_Escape {
                state.cancelTextEditing()
                return .handled
            }
            if isReturn {
                state.commitTextEditing()
                return .handled
            }
            return .ignored
        }

        if isDragging {
            guard keyCode == kVK_Escape else { return .ignored }
            cancelDrag()
            return .handled
        }

        switch keyCode {
        case kVK_Escape where modifiers.isEmpty:
            // Esc peels back one level: first the selection, then the editor.
            guard state.selection == nil else {
                state.selection = nil
                return .handled
            }
            return .cancel
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return modifiers.isEmpty ? .done : .ignored
        case kVK_Delete, kVK_ForwardDelete:
            guard modifiers.isEmpty || modifiers == .command, state.selection != nil else { return .ignored }
            deleteSelection()
            return .handled
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard state.selection != nil, modifiers.subtracting(.shift).isEmpty, let space = viewSpace,
                  space.imageRect.width > 0, space.imageRect.height > 0 else { return .ignored }
            let step = Self.nudgeDistance * (modifiers.contains(.shift) ? 10 : 1)
            let dx: CGFloat = keyCode == kVK_LeftArrow ? -step : (keyCode == kVK_RightArrow ? step : 0)
            let dy: CGFloat = keyCode == kVK_UpArrow ? -step : (keyCode == kVK_DownArrow ? step : 0)
            state.nudgeSelection(dx: dx / space.imageRect.width, dy: dy / space.imageRect.height)
            return .handled
        default:
            break
        }

        if modifiers == .command, event.characters.lowercased() == "z" {
            undo()
            return .handled
        }
        if modifiers == [.command, .shift], event.characters.lowercased() == "z" {
            redo()
            return .handled
        }
        if modifiers.isEmpty, let character = event.characters.lowercased().first,
           let tool = MarkupTool.allCases.first(where: { $0.shortcut == character }) {
            select(tool: tool)
            return .handled
        }
        return .ignored
    }

    // MARK: Pointer

    /// `true` between `beginDrag` and `endDrag`.
    var isDragging: Bool { operation != nil }

    /// Starts a drag (or click) at a view-space point.
    /// - Parameters:
    ///   - constrain: Shift is held (square rectangles, 45° arrows).
    ///   - time: The press time, used for double-click detection.
    func beginDrag(at point: CGPoint, in space: MarkupSpace, constrain: Bool = false, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if operation != nil { endDrag(at: nil, in: space, constrain: constrain) }
        dragStart = point
        dragMaxDistance = 0
        lastDragPoint = point
        lastDragSpace = space
        let isDoubleClick = registerPress(at: point, time: time)
        let hadTextSession = state.textSession != nil
        state.commitTextEditing()

        switch state.tool {
        case .select:
            operation = beginSelectDrag(at: point, in: space, isDoubleClick: isDoubleClick)
        case .text:
            if hadTextSession {
                // A click outside an open label just finishes it.
                operation = .inert
            } else if let hit = textAnnotation(at: point, in: space) {
                state.beginInteractiveChange()
                operation = .move(original: hit, editOnClick: true)
            } else {
                operation = .placeText(at: point)
            }
        case .crop:
            operation = beginCropDrag(at: point, in: space)
        case .pen:
            let start = space.clampedToImage(point)
            operation = .pen(id: UUID(), points: [space.clampedNormalized(start)], last: start)
        case .rectangle, .arrow, .highlight, .redact:
            guard let kind = state.tool.annotationKind else { operation = .inert; return }
            if kind == .redact { preparePixelation() }
            operation = .draw(kind: kind, id: UUID(), start: space.clampedToImage(point))
        }
    }

    /// Continues the current drag to a view-space point.
    func updateDrag(to point: CGPoint, in space: MarkupSpace, constrain: Bool = false) {
        guard let operation else { return }
        lastDragPoint = point
        lastDragSpace = space
        dragMaxDistance = max(dragMaxDistance, dragStart.distance(to: point))
        let exceededClick = dragMaxDistance >= Self.minimumDragDistance
        let bounds = space.imageRect
        let delta = CGVector(
            dx: bounds.width > 0 ? (point.x - dragStart.x) / bounds.width : 0,
            dy: bounds.height > 0 ? (point.y - dragStart.y) / bounds.height : 0
        )

        switch operation {
        case let .draw(kind, id, start):
            guard exceededClick else { state.draft = nil; return }
            let end = kind == .arrow
                ? MarkupDragGeometry.arrowEnd(from: start, to: point, snap: constrain, within: bounds)
                : MarkupDragGeometry.rectEnd(from: start, to: point, square: constrain, within: bounds)
            let tool = MarkupTool.tool(for: kind)
            state.draft = MarkupAnnotation(
                id: id,
                kind: kind,
                points: [space.clampedNormalized(start), space.clampedNormalized(end)],
                color: state.color(for: tool),
                lineWidth: state.lineWidth,
                redactStyle: kind == .redact ? state.redactStyle : nil
            )

        case let .pen(id, points, last):
            let clamped = space.clampedToImage(point)
            var points = points, last = last
            if clamped.distance(to: last) >= Self.penSampleSpacing {
                points.append(space.clampedNormalized(clamped))
                last = clamped
            }
            self.operation = .pen(id: id, points: points, last: last)
            guard exceededClick else { return }
            state.draft = MarkupAnnotation(id: id, kind: .pen, points: points, color: state.color(for: .pen), lineWidth: state.lineWidth)

        case let .move(original, _):
            guard exceededClick else { return }
            let bounds = Self.movableBounds(of: original, imagePixelSize: space.imagePixelSize)
            let clamped = MarkupEditorState.clampedTranslation(dx: delta.dx, dy: delta.dy, bounds: bounds)
            state.update(original.translated(dx: clamped.dx, dy: clamped.dy))

        case let .resize(original, handle, handleStart):
            let target = CGPoint(x: handleStart.x + point.x - dragStart.x, y: handleStart.y + point.y - dragStart.y)
            var resized = original
            if original.kind.isRectLike {
                let handles = MarkupGeometry.handles(for: original, in: space)
                guard handles.count == 4 else { return }
                let opposite = handles[(handle + 2) % 4]
                let corner = MarkupDragGeometry.rectEnd(from: opposite, to: target, square: constrain, within: bounds)
                resized.points = [space.clampedNormalized(opposite), space.clampedNormalized(corner)]
            } else if original.kind == .arrow, original.points.count >= 2, handle < 2 {
                let other = space.point(original.points[1 - handle])
                let end = MarkupDragGeometry.arrowEnd(from: other, to: target, snap: constrain, within: bounds)
                resized.points[handle] = space.clampedNormalized(end)
            }
            state.update(resized)

        case .placeText, .inert:
            break

        case let .cropNew(start):
            guard exceededClick else { return }
            isCropDragging = true
            let end = MarkupDragGeometry.rectEnd(from: start, to: point, square: constrain, within: bounds)
            let rect = space.normalizedRect(CGRect(corner: start, opposite: end))
            state.setCrop(MarkupCropGeometry.enforcingMinimumSize(rect, minSize: minimumCropSize(in: space)))

        case let .cropMove(original):
            state.setCrop(MarkupCropGeometry.move(original, by: delta))

        case let .cropResize(original, handle):
            state.setCrop(MarkupCropGeometry.resize(original, handle: handle, by: delta, minSize: minimumCropSize(in: space)))
        }
    }

    /// Ends the current drag, optionally at a final view-space point.
    func endDrag(at point: CGPoint?, in space: MarkupSpace, constrain: Bool = false) {
        if let point { updateDrag(to: point, in: space, constrain: constrain) }
        guard let operation else { return }
        self.operation = nil
        isCropDragging = false
        let wasClick = dragMaxDistance < Self.minimumDragDistance
        if !wasClick { lastPress = nil }

        switch operation {
        case .draw:
            guard let draft = state.draft else { return }
            state.draft = nil
            guard !wasClick, Self.hasVisibleExtent(draft, in: space) else { return }
            state.add(draft)

        case .pen:
            guard let draft = state.draft else { return }
            state.draft = nil
            guard !wasClick else { return }
            state.add(draft)

        case let .move(original, editOnClick):
            state.endInteractiveChange()
            if editOnClick && wasClick { state.beginTextEditing(existing: original.id) }

        case .resize, .cropNew, .cropMove, .cropResize:
            state.endInteractiveChange()

        case let .placeText(location):
            guard space.imageRect.contains(location) else { return }
            state.beginTextEditing(at: textAnchor(forClickAt: location, in: space))

        case .inert:
            break
        }
    }

    /// Ends a drag whose gesture was cancelled by the system (no final location).
    func endDragIfNeeded() {
        guard operation != nil, let space = lastDragSpace else { return }
        endDrag(at: nil, in: space)
    }

    /// Re-evaluates the current drag with a new Shift state (Shift pressed or released mid-drag).
    func updateConstraint(_ constrain: Bool) {
        guard operation != nil, let space = lastDragSpace else { return }
        updateDrag(to: lastDragPoint, in: space, constrain: constrain)
    }

    /// Abandons the current drag, reverting everything it changed. The gesture
    /// keeps running but has no further effect until it ends.
    func cancelDrag() {
        guard let operation else { return }
        switch operation {
        case .draw, .pen:
            state.draft = nil
        case .move, .resize, .cropNew, .cropMove, .cropResize:
            state.cancelInteractiveChange()
        case .placeText, .inert:
            break
        }
        self.operation = .inert
        isCropDragging = false
    }

    /// The pointer shape at a view-space location.
    func cursor(at point: CGPoint, in space: MarkupSpace) -> SnapshotEditorCursor {
        switch state.tool {
        case .select:
            if let selected = state.selectedAnnotation, handleIndex(at: point, for: selected, in: space) != nil { return .crosshair }
            return MarkupGeometry.hitTest(point, annotations: state.document.annotations, in: space, tolerance: Self.hitTolerance) == nil
                ? .arrow : .openHand
        case .text:
            return textAnnotation(at: point, in: space) == nil ? .iBeam : .openHand
        case .crop:
            let rect = space.rect(state.document.crop ?? .unit)
            if let handle = MarkupCropGeometry.handle(at: point, in: rect) {
                if handle.isCorner { return .crosshair }
                return handle.horizontal != 0 ? .resizeLeftRight : .resizeUpDown
            }
            return state.document.crop != nil && rect.contains(point) ? .openHand : .crosshair
        case .rectangle, .arrow, .pen, .highlight, .redact:
            return .crosshair
        }
    }

    // MARK: Helpers

    private func beginSelectDrag(at point: CGPoint, in space: MarkupSpace, isDoubleClick: Bool) -> Operation {
        if let selected = state.selectedAnnotation, let index = handleIndex(at: point, for: selected, in: space) {
            state.beginInteractiveChange()
            return .resize(original: selected, handle: index, handleStart: MarkupGeometry.handles(for: selected, in: space)[index])
        }
        guard let id = MarkupGeometry.hitTest(point, annotations: state.document.annotations, in: space, tolerance: Self.hitTolerance),
              let annotation = state.document.annotation(id: id) else {
            state.selection = nil
            return .inert
        }
        if isDoubleClick, annotation.kind == .text, state.selection == id {
            lastPress = nil
            state.beginTextEditing(existing: id)
            return .inert
        }
        state.selection = id
        state.beginInteractiveChange()
        return .move(original: annotation, editOnClick: false)
    }

    private func beginCropDrag(at point: CGPoint, in space: MarkupSpace) -> Operation {
        let current = state.document.crop ?? .unit
        let rect = space.rect(current)
        state.beginInteractiveChange()
        if let handle = MarkupCropGeometry.handle(at: point, in: rect) {
            isCropDragging = true
            return .cropResize(original: current, handle: handle)
        }
        if state.document.crop != nil, rect.contains(point) {
            isCropDragging = true
            return .cropMove(original: current)
        }
        return .cropNew(start: space.clampedToImage(point))
    }

    /// Index into `MarkupGeometry.handles(for:in:)` of the handle under `point`.
    private func handleIndex(at point: CGPoint, for annotation: MarkupAnnotation, in space: MarkupSpace) -> Int? {
        let handles = MarkupGeometry.handles(for: annotation, in: space)
        let nearest = handles.indices.min { handles[$0].distance(to: point) < handles[$1].distance(to: point) }
        guard let nearest, handles[nearest].distance(to: point) <= Self.handleHitRadius else { return nil }
        return nearest
    }

    private func textAnnotation(at point: CGPoint, in space: MarkupSpace) -> MarkupAnnotation? {
        let texts = state.document.annotations.filter { $0.kind == .text }
        guard let id = MarkupGeometry.hitTest(point, annotations: texts, in: space, tolerance: Self.hitTolerance) else { return nil }
        return state.document.annotation(id: id)
    }

    /// Records a press; returns whether it completes a double click.
    private func registerPress(at point: CGPoint, time: TimeInterval) -> Bool {
        defer { lastPress = (time, point) }
        guard let last = lastPress else { return false }
        return time - last.time <= doubleClickInterval && last.location.distance(to: point) <= Self.doubleClickDistance
    }

    private func minimumCropSize(in space: MarkupSpace) -> CGSize {
        let rect = space.imageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let pixelWidth = imagePixelSize.width > 0 ? 1 / imagePixelSize.width : 0
        let pixelHeight = imagePixelSize.height > 0 ? 1 / imagePixelSize.height : 0
        return CGSize(
            width: min(1, max(Self.minimumCropSide / rect.width, pixelWidth)),
            height: min(1, max(Self.minimumCropSide / rect.height, pixelHeight))
        )
    }

    /// The normalized anchor for a label placed by clicking at `point`: the
    /// first line is vertically centered on the click.
    func textAnchor(forClickAt point: CGPoint, in space: MarkupSpace) -> CGPoint {
        let fontSize = MarkupGeometry.fontSize(state.lineWidth, imageSize: space.imagePixelSize)
        let lineHeight = MarkupGeometry.textLayout("", fontSize: fontSize).lineHeight * space.scale
        return space.clampedNormalized(CGPoint(x: point.x, y: point.y - lineHeight / 2))
    }

    /// The normalized extent used to keep a moved annotation on the image:
    /// the text box for labels, the point bounds otherwise.
    static func movableBounds(of annotation: MarkupAnnotation, imagePixelSize: CGSize) -> CGRect {
        guard annotation.kind == .text, imagePixelSize.width > 0, imagePixelSize.height > 0,
              let frame = MarkupGeometry.textFrame(for: annotation, in: MarkupSpace(pixelSize: imagePixelSize)) else {
            return annotation.normalizedPointBounds
        }
        return CGRect(
            x: frame.minX / imagePixelSize.width,
            y: frame.minY / imagePixelSize.height,
            width: frame.width / imagePixelSize.width,
            height: frame.height / imagePixelSize.height
        )
    }

    /// Whether a freshly drawn two-point shape is big enough to keep.
    private static func hasVisibleExtent(_ annotation: MarkupAnnotation, in space: MarkupSpace) -> Bool {
        guard annotation.points.count >= 2 else { return false }
        let a = space.point(annotation.points[0]), b = space.point(annotation.points[1])
        if annotation.kind.isRectLike {
            return abs(b.x - a.x) >= 1 && abs(b.y - a.y) >= 1
        }
        return a.distance(to: b) >= minimumDragDistance
    }
}
