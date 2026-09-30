import AppKit
import SwiftUI
import TandemCore
import TandemUI

/// The frozen live view: drag out regions, each one goes to the composer.
struct RegionSelectionOverlay: View {
    @Environment(AppModel.self) private var model
    let selection: RegionSelection
    @State private var dragRect: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            // Same aspect-fit placement as the live view's display layer.
            let video = SnapshotRegion.aspectFit(selection.frameSize, in: bounds)
            ZStack(alignment: .topLeading) {
                if selection.canSelect {
                    if let image = selection.image {
                        // The Source's picture (the screen changed after the held frame).
                        Color.black
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: video.width, height: video.height)
                            .offset(x: video.minX, y: video.minY)
                    }
                    // Dim the frame (it isn't live) except what's being selected.
                    Path { path in
                        path.addRect(video)
                        if let dragRect { path.addRect(dragRect) }
                    }
                    .fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))
                    ForEach(Array(selection.picked.enumerated()), id: \.offset) { index, region in
                        PickedRegionMark(rect: rect(for: region, in: video), number: index + 1)
                    }
                    if let dragRect {
                        Path(dragRect).stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    }
                } else {
                    Color.black.opacity(0.35)
                    ProgressView().controlSize(.large)
                        .frame(width: bounds.width, height: bounds.height)
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in
                    guard selection.canSelect else { return }
                    let rect = CGRect(origin: value.startLocation, size: .zero)
                        .union(CGRect(origin: value.location, size: .zero))
                        .intersection(video)
                    dragRect = rect.isNull ? nil : rect
                }
                .onEnded { _ in
                    if let dragRect, let region = SnapshotRegion(selection: dragRect, in: video) {
                        model.studio.addRegion(region)
                    }
                    dragRect = nil
                })
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.crosshair.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
        .overlay(alignment: .top) {
            RegionSelectionBar(selection: selection)
                .padding(Spacing.m)
        }
        .onDisappear { NSCursor.arrow.set() }
    }

    private func rect(for region: SnapshotRegion, in video: CGRect) -> CGRect {
        CGRect(x: video.minX + region.x * video.width, y: video.minY + region.y * video.height,
               width: region.width * video.width, height: region.height * video.height)
    }
}

private struct PickedRegionMark: View {
    let rect: CGRect
    let number: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path(rect).stroke(Theme.accent, lineWidth: 2)
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent))
                .offset(x: rect.minX + 4, y: rect.minY + 4)
        }
        .allowsHitTesting(false)
    }
}

private struct RegionSelectionBar: View {
    @Environment(AppModel.self) private var model
    let selection: RegionSelection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .leading)
            if selection.cropsInFlight > 0 {
                ProgressView().controlSize(.small)
            }
            Hairline(vertical: true).frame(height: 16)
            if case .failed = selection.phase {
                Button("Try Again") {
                    model.studio.endRegionSelection()
                    model.studio.beginRegionSelection()
                }
                .buttonStyle(TandemButtonStyle(.secondary, size: .small))
            } else {
                Button("Whole Screen") { model.studio.addRegion(.full) }
                    .buttonStyle(TandemButtonStyle(.secondary, size: .small))
                    .disabled(!selection.canSelect)
                    .help("Add the whole frozen frame (⇧⌘S)")
            }
            Button("Done") { model.studio.endRegionSelection() }
                .buttonStyle(TandemButtonStyle(.primary, size: .small))
                .keyboardShortcut(.cancelAction)
                .help("Back to the live view (esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .tandemGlassCapsule(interactive: true)
    }

    private var message: String {
        if case .failed(let reason) = selection.phase { return reason }
        if !selection.canSelect { return "Freezing the shared screen…" }
        let count = selection.picked.count
        if count == 0 { return "Drag over what you want to ask about" }
        return count == 1 ? "1 picture added · drag to add another" : "\(count) pictures added · drag to add another"
    }
}
