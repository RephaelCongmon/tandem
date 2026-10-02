import AppKit
import SwiftUI
import TandemCore
import TandemUI

/// The region tool on the live view: each drag holds the frame under the pointer and adds
/// the dragged part of the shared screen to the composer.
struct RegionToolOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    /// The drag couldn't start (no live frame yet, say): ignore it until the pointer lifts.
    @State private var rejected = false
    /// Where recent pictures came from, outlined for a moment.
    @State private var added: [AddedMark] = []

    var body: some View {
        let studio = model.studio
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let frame = studio.regionDrag?.frameSize ?? CGSize(width: studio.liveStats.width, height: studio.liveStats.height)
            // Same aspect-fit placement as the live view's display layer.
            let video = MarkupSpace.aspectFitRect(for: frame, in: bounds)
            // The overlay's own drag state, so it redraws with every move of the first drag too.
            let isDragging = dragStart != nil
            let selection = isDragging ? selectionRect(in: video) : nil
            let marks = added.map(\.rect)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let preview = studio.regionDrag?.preview {
                    // The Source's picture: its screen changed after the held frame.
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: video.width, height: video.height)
                        .offset(x: video.minX, y: video.minY)
                }
                // Always there (drawing nothing between drags), so the very first drag's outline
                // shows too: inserting the shapes when that drag began left them undrawn.
                Canvas { context, _ in
                    if isDragging {
                        // Dim the held frame (it isn't live) except what's being selected.
                        var dim = Path()
                        dim.addRect(video)
                        if let selection { dim.addRect(selection) }
                        context.fill(dim, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
                        if let selection {
                            context.stroke(Path(selection), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        }
                    }
                    for mark in marks {
                        context.stroke(Path(mark), with: .color(Theme.accent), lineWidth: 2)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in
                    guard !rejected else { return }
                    if dragStart == nil {
                        guard video.contains(value.startLocation), studio.canBeginRegionDrag else {
                            rejected = true
                            return
                        }
                        dragStart = value.startLocation
                        // Hold the frame right after this event, not inside it: starting the drag
                        // from the gesture's first update kept the first drag's outline from
                        // being drawn until the pointer came up.
                        DispatchQueue.main.async {
                            guard dragStart != nil, !studio.beginRegionDrag() else { return }
                            rejected = true
                            dragStart = nil
                            dragEnd = nil
                        }
                    }
                    dragEnd = value.location
                }
                .onEnded { value in
                    defer {
                        dragStart = nil
                        dragEnd = nil
                        rejected = false
                    }
                    guard let start = dragStart else { return }
                    let region = SnapshotRegion.selection(from: start, to: value.location, imageRect: video)
                    studio.endRegionDrag(region)
                    if let region { flash(rect(for: region, in: video)) }
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): (video.contains(point) ? NSCursor.crosshair : NSCursor.arrow).set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
        // The first drag counts even when the window wasn't active (the tool was turned on from
        // the menu bar, say): otherwise macOS spends that click activating the window.
        .handlesWindowActivationClicks()
        .onDisappear { NSCursor.arrow.set() }
    }

    private func selectionRect(in video: CGRect) -> CGRect? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(video)
        return rect.isNull ? nil : rect
    }

    private func rect(for region: SnapshotRegion, in video: CGRect) -> CGRect {
        CGRect(x: video.minX + region.x * video.width, y: video.minY + region.y * video.height,
               width: region.width * video.width, height: region.height * video.height)
    }

    private func flash(_ rect: CGRect) {
        let mark = AddedMark(rect: rect)
        added.append(mark)
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.easeOut(duration: 0.3)) { added.removeAll { $0.id == mark.id } }
        }
    }
}

extension View {
    /// Gestures here also get the click that activates the window (macOS 15 and later).
    @ViewBuilder
    func handlesWindowActivationClicks() -> some View {
        if #available(macOS 15.0, *) {
            allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}

private struct AddedMark: Identifiable {
    let id = UUID()
    let rect: CGRect
}
