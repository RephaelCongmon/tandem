import AppKit
import SwiftUI

/// Markup editor for a screenshot: crop, boxes, arrows, pen strokes,
/// highlights, text labels and redactions, applied non-destructively as a
/// `MarkupDocument` and baked into a full-resolution image on Done.
///
/// ```swift
/// .sheet(item: $pendingSnapshot) { snapshot in
///     SnapshotEditorView(image: snapshot.image, document: snapshot.markup) {
///         pendingSnapshot = nil
///     } onDone: { document, rendered in
///         attach(rendered, markup: document)
///         pendingSnapshot = nil
///     }
///     .frame(minWidth: 900, minHeight: 640)
/// }
/// ```
///
/// While editing, the source image is drawn once and markup is drawn on top as
/// vector paths built by `MarkupGeometry`, the same geometry `MarkupRenderer`
/// uses for export, so what you see is what gets sent. Pixelate redactions
/// preview through a pixelated copy of the image that is computed once.
///
/// Keyboard: V R A P H T X C pick tools; Shift constrains shapes to squares
/// and arrows to 45°; Delete removes the selection; arrow keys nudge it;
/// ⌘Z / ⇧⌘Z undo and redo; Esc clears the selection, then cancels; ⌘↩ (or ↩
/// when not typing) is Done. Shortcuts never fire while a text field has focus.
///
/// The editor keeps its own state for the lifetime of the view; give it a new
/// identity (e.g. `.id(snapshotID)`) to edit a different image.
public struct SnapshotEditorView: View {
    private let onCancel: () -> Void
    private let onDone: (_ document: MarkupDocument, _ rendered: CGImage) -> Void
    @State private var model: SnapshotEditorModel

    /// Creates an editor.
    /// - Parameters:
    ///   - image: The screenshot to mark up. It is never modified.
    ///   - document: Existing markup to continue editing.
    ///   - onCancel: Called when the user cancels (Esc or the Cancel button).
    ///   - onDone: Called with the final document and the image rendered at full
    ///     resolution (cropped, redactions baked in). With an empty document the
    ///     untouched source image is passed through.
    public init(
        image: CGImage,
        document: MarkupDocument = MarkupDocument(),
        onCancel: @escaping () -> Void,
        onDone: @escaping (_ document: MarkupDocument, _ rendered: CGImage) -> Void
    ) {
        self.init(model: SnapshotEditorModel(image: image, document: document), onCancel: onCancel, onDone: onDone)
    }

    /// Creates an editor around an existing controller (tests and previews).
    init(model: SnapshotEditorModel, onCancel: @escaping () -> Void, onDone: @escaping (_ document: MarkupDocument, _ rendered: CGImage) -> Void) {
        self.onCancel = onCancel
        self.onDone = onDone
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                EditorCanvas(model: model)
                EditorToolbar(model: model)
                    .padding(.top, Spacing.m)
                    .padding(.horizontal, Spacing.m)
            }
            .disabled(model.isExporting)
            EditorBottomBar(model: model, onCancel: cancel, onDone: finish)
        }
        .frame(minWidth: 700, minHeight: 440)
        .background(Theme.surfaceSunken)
        .background(EditorEventMonitor(onKeyDown: handleKeyDown, onFlagsChanged: handleFlagsChanged))
        .environment(\.colorScheme, .dark)
        .onAppear { model.editorDidAppear() }
    }

    private func cancel() {
        guard !model.isExporting else { return }
        onCancel()
    }

    private func finish() {
        let onDone = onDone
        model.finish { document, rendered in onDone(document, rendered) }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !model.isExporting else { return false }
        let responder = event.window?.firstResponder
        let input = SnapshotEditorKeyEvent(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers ?? "",
            modifiers: event.modifierFlags,
            isTextInputActive: responder is NSText,
            hasMarkedText: (responder as? NSTextInputClient)?.hasMarkedText() ?? false
        )
        switch model.handleKey(input) {
        case .ignored:
            return false
        case .handled:
            return true
        case .cancel:
            cancel()
            return true
        case .done:
            finish()
            return true
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        model.updateConstraint(event.modifierFlags.contains(.shift))
    }
}

// MARK: - Canvas

/// The image plus all markup layers, in one top-left coordinate space.
/// Each layer reads only the state it draws, so a drag re-renders the vector
/// layers but never the image.
private struct EditorCanvas: View {
    let model: SnapshotEditorModel

    var body: some View {
        GeometryReader { proxy in
            let space = SnapshotEditorLayout.space(imagePixelSize: model.imagePixelSize, canvasSize: proxy.size)
            ZStack(alignment: .topLeading) {
                ImageLayer(image: model.image, rect: space.imageRect)
                MarkupLayers(model: model, space: space)
                CropDimLayer(model: model, space: space)
                SelectionLayer(model: model, space: space)
                CropChromeLayer(model: model, space: space)
                InteractionLayer(model: model, space: space)
                TextEditingLayer(model: model, space: space)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear { model.viewSpace = space }
            .onChange(of: space) { _, newSpace in model.viewSpace = newSpace }
        }
        .clipped()
    }
}

/// The source image, aspect-fit. Its inputs never change during editing, so it's drawn once.
private struct ImageLayer: View {
    let image: CGImage
    let rect: CGRect

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width, height: rect.height)
            .background(
                Rectangle()
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
            )
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}

/// Redactions, highlights and ink, built from the shared `MarkupGeometry` scene.
private struct MarkupLayers: View {
    let model: SnapshotEditorModel
    let space: MarkupSpace

    var body: some View {
        let annotations = model.displayedAnnotations
        let scene = MarkupGeometry.scene(for: annotations, in: space, hiddenID: model.hiddenAnnotationID)
        let redactions = space.snappedRedactions(for: annotations)
        ZStack(alignment: .topLeading) {
            if !redactions.isEmpty {
                RedactionLayer(
                    redactions: redactions,
                    pixelated: model.pixelatedPreview,
                    isPixelationFailed: model.pixelationStatus == .failed,
                    imageRect: space.imageRect
                )
            }
            if !scene.multiplyPrimitives.isEmpty {
                PrimitiveCanvas(primitives: scene.multiplyPrimitives, blendMode: .multiply)
                    .blendMode(.multiply)
            }
            if !scene.overlayPrimitives.isEmpty {
                PrimitiveCanvas(primitives: scene.overlayPrimitives, blendMode: .normal)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Redaction preview: the pre-pixelated copy clipped to pixelate regions, and
/// black boxes for solid ones. Later redactions win where they overlap, like the export.
private struct RedactionLayer: View {
    let redactions: [MarkupRedaction]
    let pixelated: CGImage?
    let isPixelationFailed: Bool
    let imageRect: CGRect

    /// Shown in pixelate regions until the pixelated copy is ready.
    private static let placeholder = Color(white: 0.3)

    var body: some View {
        let hasPixelated = pixelated != nil
        ZStack(alignment: .topLeading) {
            if let pixelated {
                Image(decorative: pixelated, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .mask {
                        Canvas { context, _ in
                            for redaction in redactions {
                                context.blendMode = redaction.style == .pixelate ? .normal : .destinationOut
                                context.fill(Path(redaction.rect), with: .color(.white))
                            }
                        }
                    }
            }
            Canvas { context, _ in
                for redaction in redactions {
                    switch redaction.style {
                    case .solid:
                        context.blendMode = .normal
                        context.fill(Path(redaction.rect), with: .color(.black))
                    case .pixelate where hasPixelated:
                        context.blendMode = .destinationOut
                        context.fill(Path(redaction.rect), with: .color(.white))
                    case .pixelate:
                        // Core Image failure exports black, so preview black too.
                        context.blendMode = .normal
                        context.fill(Path(redaction.rect), with: .color(isPixelationFailed ? .black : Self.placeholder))
                    }
                }
            }
        }
    }
}

/// Draws `MarkupPrimitive`s exactly as `MarkupRenderer` does (round caps and joins, nonzero fills).
private struct PrimitiveCanvas: View {
    let primitives: [MarkupPrimitive]
    let blendMode: GraphicsContext.BlendMode

    var body: some View {
        Canvas { context, _ in
            context.blendMode = blendMode
            for primitive in primitives {
                let path = Path(primitive.path)
                let shading = GraphicsContext.Shading.color(Color(markup: primitive.color))
                switch primitive.style {
                case .fill:
                    context.fill(path, with: shading)
                case .stroke(let width):
                    context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: Crop

private struct CropDimLayer: View {
    let model: SnapshotEditorModel
    let space: MarkupSpace

    var body: some View {
        CropDim(
            cropRect: model.state.document.crop.map(space.exportedCropRect),
            imageRect: space.imageRect,
            opacity: model.state.tool == .crop ? 0.55 : 0.65
        )
    }
}

/// Darkens the part of the image the crop removes.
private struct CropDim: View {
    let cropRect: CGRect?
    let imageRect: CGRect
    let opacity: Double

    var body: some View {
        if let cropRect {
            Canvas { context, _ in
                var outside = Path(imageRect)
                outside.addRect(cropRect)
                context.fill(outside, with: .color(.black.opacity(opacity)), style: FillStyle(eoFill: true))
                context.stroke(Path(cropRect), with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct CropChromeLayer: View {
    let model: SnapshotEditorModel
    let space: MarkupSpace

    var body: some View {
        if model.state.tool == .crop {
            CropChrome(rect: space.exportedCropRect(model.state.document.crop ?? .unit), showsGuides: model.isCropDragging)
        }
    }
}

/// Crop frame with corner brackets, edge handles and (while dragging) rule-of-thirds guides.
private struct CropChrome: View {
    let rect: CGRect
    let showsGuides: Bool

    var body: some View {
        Canvas { context, _ in
            if showsGuides {
                var guides = Path()
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    let x = rect.minX + rect.width * fraction, y = rect.minY + rect.height * fraction
                    guides.move(to: CGPoint(x: x, y: rect.minY))
                    guides.addLine(to: CGPoint(x: x, y: rect.maxY))
                    guides.move(to: CGPoint(x: rect.minX, y: y))
                    guides.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                context.stroke(guides, with: .color(.black.opacity(0.3)), lineWidth: 2)
                context.stroke(guides, with: .color(.white.opacity(0.7)), lineWidth: 0.75)
            }
            context.stroke(Path(rect), with: .color(.black.opacity(0.35)), lineWidth: 2.5)
            context.stroke(Path(rect), with: .color(.white.opacity(0.9)), lineWidth: 1)

            var handles = Path()
            let arm = max(6, min(18, rect.width / 3, rect.height / 3))
            let bar = max(6, min(22, rect.width / 4, rect.height / 4))
            for handle in MarkupCropHandle.allCases {
                let point = handle.position(in: rect)
                if handle.isCorner {
                    handles.move(to: CGPoint(x: point.x, y: point.y - CGFloat(handle.vertical) * arm))
                    handles.addLine(to: point)
                    handles.addLine(to: CGPoint(x: point.x - CGFloat(handle.horizontal) * arm, y: point.y))
                } else if handle.horizontal != 0 {
                    handles.move(to: CGPoint(x: point.x, y: point.y - bar / 2))
                    handles.addLine(to: CGPoint(x: point.x, y: point.y + bar / 2))
                } else {
                    handles.move(to: CGPoint(x: point.x - bar / 2, y: point.y))
                    handles.addLine(to: CGPoint(x: point.x + bar / 2, y: point.y))
                }
            }
            context.stroke(handles, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
            context.stroke(handles, with: .color(.white), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

// MARK: Selection

private struct SelectionLayer: View {
    let model: SnapshotEditorModel
    let space: MarkupSpace

    var body: some View {
        let state = model.state
        if state.tool == .select, state.textSession == nil, let annotation = state.selectedAnnotation {
            SelectionChrome(annotation: annotation, space: space)
        }
    }
}

/// Dashed outline plus handles (rect corners, arrow endpoints) around the selection.
private struct SelectionChrome: View {
    let annotation: MarkupAnnotation
    let space: MarkupSpace

    var body: some View {
        Canvas { context, _ in
            let outline: CGRect
            if annotation.kind.isRectLike, let normalized = annotation.normalizedRect {
                outline = space.rect(normalized)
            } else if annotation.kind == .arrow {
                outline = .null
            } else {
                outline = MarkupGeometry.bounds(of: annotation, in: space).insetBy(dx: -4, dy: -4)
            }
            if !outline.isNull {
                context.stroke(Path(outline), with: .color(.black.opacity(0.45)), lineWidth: 2.5)
                context.stroke(Path(outline), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
            }
            for handle in MarkupGeometry.handles(for: annotation, in: space) {
                let dot = Path(ellipseIn: CGRect(x: handle.x - 4.5, y: handle.y - 4.5, width: 9, height: 9))
                context.fill(dot, with: .color(.white))
                context.stroke(dot, with: .color(Theme.accent), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Interaction

/// Transparent layer receiving drags, clicks and hover over the whole canvas.
private struct InteractionLayer: View {
    let model: SnapshotEditorModel
    let space: MarkupSpace
    @GestureState private var isGestureActive = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onChange(of: isGestureActive) { _, isActive in
                // A gesture the system cancels never calls onEnded; finish the drag anyway.
                if !isActive { model.endDragIfNeeded() }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    model.cursor(at: location, in: space).nsCursor.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Screenshot canvas")
            .accessibilityValue("\(model.state.tool.displayName) tool")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                let constrain = NSEvent.modifierFlags.contains(.shift)
                if !model.isDragging {
                    Self.endTextFocus()
                    model.beginDrag(at: value.startLocation, in: space, constrain: constrain)
                }
                model.updateDrag(to: value.location, in: space, constrain: constrain)
            }
            .onEnded { value in
                model.endDrag(at: value.location, in: space, constrain: NSEvent.modifierFlags.contains(.shift))
            }
    }

    /// A press on the canvas ends typing anywhere in the window (the label
    /// field's text is already in the model), so tool shortcuts work again.
    private static func endTextFocus() {
        guard let window = NSApp.currentEvent?.window, window.firstResponder is NSText else { return }
        window.makeFirstResponder(nil)
    }
}

// MARK: Text editing

private struct TextEditingLayer: View {
    let model: SnapshotEditorModel
    let space: MarkupSpace

    var body: some View {
        if let session = model.state.textSession {
            TextSessionField(model: model, session: session, space: space)
                .id(session.id)
        }
    }
}

/// The in-place, auto-focused field of a text session, sized and styled like the rendered label.
private struct TextSessionField: View {
    let model: SnapshotEditorModel
    let session: MarkupTextSession
    let space: MarkupSpace
    @FocusState private var isFocused: Bool

    private static let inset: CGFloat = 4
    private static let placeholder = "Label"

    var body: some View {
        let pixelFontSize = MarkupGeometry.fontSize(session.lineWidth, imageSize: space.imagePixelSize)
        let fontSize = max(1, pixelFontSize * space.scale)
        let measured = MarkupGeometry.textLayout(session.text.isEmpty ? Self.placeholder : session.text, fontSize: pixelFontSize)
        let width = measured.size.width * space.scale + fontSize * 0.75
        let origin = space.point(session.anchor)
        TextField(Self.placeholder, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Font(MarkupGeometry.textFont(size: fontSize)))
            .foregroundStyle(Color(markup: session.color.rgba))
            .lineLimit(1...40)
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .focused($isFocused)
            .onSubmit { model.state.commitTextEditing() }
            .padding(Self.inset)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.black.opacity(0.18)))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .offset(x: origin.x - Self.inset, y: origin.y - Self.inset)
            .accessibilityLabel("Text label")
            .onAppear {
                isFocused = true
                // The field may not be in the window yet on the first pass.
                DispatchQueue.main.async { isFocused = true }
            }
    }

    private var text: Binding<String> {
        Binding(
            get: { model.state.textSession?.text ?? "" },
            set: { model.state.textSession?.text = $0 }
        )
    }
}

// MARK: - Toolbar

/// Floating glass toolbar: tools, contextual style controls, history.
private struct EditorToolbar: View {
    let model: SnapshotEditorModel

    var body: some View {
        HStack(spacing: Spacing.s) {
            ToolPicker(model: model, selected: model.state.tool)
            StyleControls(model: model)
            Hairline(vertical: true).frame(height: 18)
            HistoryControlsReader(model: model)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs + 2)
        .tandemGlass(cornerRadius: Radius.l)
    }
}

private struct ToolPicker: View {
    let model: SnapshotEditorModel
    let selected: MarkupTool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(MarkupTool.allCases) { tool in
                IconButton(
                    tool.systemImage,
                    help: "\(tool.displayName) (\(String(tool.shortcut).uppercased()))",
                    isActive: tool == selected
                ) {
                    model.select(tool: tool)
                }
                .accessibilityAddTraits(tool == selected ? .isSelected : [])
            }
        }
    }
}

/// Controls for the active tool or selection. Emits several views into the toolbar's stack.
private struct StyleControls: View {
    let model: SnapshotEditorModel

    var body: some View {
        let state = model.state
        let styleTool = model.styleTool
        let isSelecting = state.tool == .select && state.textSession == nil
        if styleTool != nil || state.tool == .crop || isSelecting {
            Hairline(vertical: true).frame(height: 18)
        }
        if let styleTool, styleTool.usesColor {
            ColorPalette(model: model, selected: model.displayedColor)
        }
        if let styleTool, styleTool.usesLineWidth {
            LineWidthPicker(model: model, selected: model.displayedLineWidth, isText: styleTool == .text)
        }
        if styleTool == .redact {
            RedactStylePicker(model: model, selected: model.displayedRedactStyle)
        }
        if state.tool == .crop {
            CropControls(model: model, hasCrop: state.document.crop != nil)
        }
        if isSelecting {
            if state.selection != nil {
                IconButton("trash", help: "Delete (⌫)") { model.deleteSelection() }
            } else {
                Text("Click a mark to edit it")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Spacing.xs)
            }
        }
    }
}

private struct ColorPalette: View {
    let model: SnapshotEditorModel
    let selected: MarkupColor

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MarkupColor.allCases) { color in
                ColorSwatch(color: color, isSelected: color == selected) { model.applyColor(color) }
            }
        }
    }
}

private struct ColorSwatch: View {
    let color: MarkupColor
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(markup: color.rgba))
                .overlay(Circle().strokeBorder(Color.white.opacity(color == .black ? 0.45 : 0.2), lineWidth: 1))
                .frame(width: 14, height: 14)
                .padding(3)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(isSelected ? 0.95 : (hovering ? 0.35 : 0)), lineWidth: 1.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(color.displayName)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LineWidthPicker: View {
    let model: SnapshotEditorModel
    let selected: MarkupLineWidth
    let isText: Bool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(MarkupLineWidth.allCases) { width in
                if isText {
                    IconButton(Self.textSymbol(width), help: "\(Self.textSizeName(width)) Text", isActive: width == selected) {
                        model.applyLineWidth(width)
                    }
                    .accessibilityAddTraits(width == selected ? .isSelected : [])
                } else {
                    LineWidthButton(width: width, isSelected: width == selected) { model.applyLineWidth(width) }
                }
            }
        }
    }

    private static func textSymbol(_ width: MarkupLineWidth) -> String {
        switch width {
        case .thin: return "textformat.size.smaller"
        case .medium: return "textformat.size"
        case .thick: return "textformat.size.larger"
        }
    }

    private static func textSizeName(_ width: MarkupLineWidth) -> String {
        switch width {
        case .thin: return "Small"
        case .medium: return "Medium"
        case .thick: return "Large"
        }
    }
}

/// A stroke-weight button drawn as a line of that weight, styled like `IconButton`.
private struct LineWidthButton: View {
    let width: MarkupLineWidth
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var thickness: CGFloat {
        switch width {
        case .thin: return 1.5
        case .medium: return 3
        case .thick: return 5
        }
    }

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isSelected ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 14, height: thickness)
                .frame(width: 26, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 28 * 0.3, style: .continuous)
                        .fill(isSelected ? Theme.accent.opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(width.displayName) Line")
        .accessibilityLabel("\(width.displayName) Line")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RedactStylePicker: View {
    let model: SnapshotEditorModel
    let selected: RedactStyle

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(RedactStyle.allCases) { style in
                IconButton(style == .pixelate ? "checkerboard.rectangle" : "rectangle.fill", help: style.displayName, isActive: style == selected) {
                    model.applyRedactStyle(style)
                }
                .accessibilityAddTraits(style == selected ? .isSelected : [])
            }
        }
    }
}

private struct CropControls: View {
    let model: SnapshotEditorModel
    let hasCrop: Bool

    var body: some View {
        Button("Reset Crop") { model.resetCrop() }
            .buttonStyle(TandemButtonStyle(.ghost, size: .small))
            .disabled(!hasCrop)
            .help("Reset crop to the full image")
    }
}

private struct HistoryControlsReader: View {
    let model: SnapshotEditorModel

    var body: some View {
        HistoryControls(
            model: model,
            canUndo: model.state.canUndo,
            canRedo: model.state.canRedo,
            canReset: !model.state.document.isEmpty
        )
    }
}

private struct HistoryControls: View {
    let model: SnapshotEditorModel
    let canUndo: Bool
    let canRedo: Bool
    let canReset: Bool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            IconButton("arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }
                .disabled(!canUndo)
            IconButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)") { model.redo() }
                .disabled(!canRedo)
            IconButton("arrow.counterclockwise", help: "Reset All Markup") { model.resetAll() }
                .disabled(!canReset)
        }
    }
}

// MARK: - Bottom bar

private struct EditorBottomBar: View {
    let model: SnapshotEditorModel
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            ImageInfoReader(model: model)
            ToolHint(tool: model.state.tool)
            if let error = model.exportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.m)
            Button(action: onCancel) {
                HStack(spacing: 6) {
                    Text("Cancel")
                    Text("esc").foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.tandemSecondary)
            .disabled(model.isExporting)
            .help("Cancel (Esc)")
            Button(action: onDone) {
                HStack(spacing: 6) {
                    if model.isExporting {
                        ProgressView().controlSize(.small)
                    }
                    Text("Done")
                    Text("⌘↩").opacity(0.7)
                }
            }
            .buttonStyle(.tandemPrimary)
            .disabled(model.isExporting)
            .help("Done (⌘↩)")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s + 2)
        .background(Theme.surface)
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct ImageInfoReader: View {
    let model: SnapshotEditorModel

    var body: some View {
        let document = model.state.document
        ImageInfo(
            pixelSize: model.imagePixelSize,
            croppedSize: document.crop == nil ? nil : model.outputPixelSize,
            redactionCount: document.annotations.lazy.filter { $0.kind == .redact }.count
        )
    }
}

/// Pixel size, crop size and redaction count.
private struct ImageInfo: View {
    let pixelSize: CGSize
    let croppedSize: CGSize?
    let redactionCount: Int

    var body: some View {
        HStack(spacing: Spacing.m) {
            Label(Self.format(pixelSize), systemImage: "photo")
                .help("Image size")
            if let croppedSize {
                Label("Crop \(Self.format(croppedSize))", systemImage: "crop")
                    .help("Size of the image that will be sent")
            }
            if redactionCount > 0 {
                Pill(redactionCount == 1 ? "1 redaction" : "\(redactionCount) redactions", systemImage: "eye.slash", tint: Theme.success)
                    .help("Redacted areas are permanently removed from the image that's sent")
            }
        }
        .font(TandemFont.stat)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
    }

    static func format(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px"
    }
}

/// A modifier hint for tools that support Shift constraints.
private struct ToolHint: View {
    let tool: MarkupTool

    var body: some View {
        switch tool {
        case .rectangle, .highlight, .redact, .crop:
            hint("Square")
        case .arrow:
            hint("45°")
        case .select, .pen, .text:
            EmptyView()
        }
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            KeyCaps(["⇧"])
            Text(text)
                .font(TandemFont.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold Shift for \(text)")
    }
}

// MARK: - Keyboard

/// Installs a local key monitor while the editor is in a window. Only events
/// for that window reach the editor, and consumed events stop there.
private struct EditorEventMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool
    let onFlagsChanged: (NSEvent) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onKeyDown = onKeyDown
        view.onFlagsChanged = onFlagsChanged
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onFlagsChanged = onFlagsChanged
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?
        var onFlagsChanged: ((NSEvent) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMonitoring() } else { startMonitoring() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            switch event.type {
            case .keyDown:
                return onKeyDown?(event) ?? false
            case .flagsChanged:
                onFlagsChanged?(event)
                return false
            default:
                return false
            }
        }
    }
}

// MARK: - Helpers

extension Color {
    /// The SwiftUI color for a markup color value (sRGB).
    init(markup rgba: MarkupRGBA) {
        self.init(.sRGB, red: Double(rgba.red), green: Double(rgba.green), blue: Double(rgba.blue), opacity: Double(rgba.alpha))
    }
}
