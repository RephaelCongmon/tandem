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
            ZStack(alignment: .topLeading) {
                Color.clear
                if let drag = studio.regionDrag {
                    if let preview = drag.preview {
                        // The Source's picture: its screen changed after the held frame.
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: video.width, height: video.height)
                            .offset(x: video.minX, y: video.minY)
                    }
                    let selection = selectionRect(in: video)
                    // Dim the held frame (it isn't live) except what's being selected.
                    Path { path in
                        path.addRect(video)
                        if let selection { path.addRect(selection) }
                    }
                    .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                    if let selection {
                        Path(selection).stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    }
                }
                ForEach(added) { mark in
                    Path(mark.rect).stroke(Theme.accent, lineWidth: 2)
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in
                    guard !rejected else { return }
                    if dragStart == nil {
                        guard video.contains(value.startLocation), studio.beginRegionDrag() else {
                            rejected = true
                            return
                        }
                        dragStart = value.startLocation
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

private struct AddedMark: Identifiable {
    let id = UUID()
    let rect: CGRect
}
