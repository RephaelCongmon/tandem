import AppKit
import SwiftUI
import TandemCore
import TandemUI

/// The preview is never an attachment. Only an explicitly drawn region is added.
struct RegionCaptureSheet: View {
    @Environment(AppModel.self) private var model
    let selection: StudioEngine.RegionSelection
    @State private var image: CGImage?
    @State private var region: SnapshotRegion?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Select a picture").font(TandemFont.title)
                    Text("Drag over the frozen frame to choose a region. Nothing is attached until you add it.")
                        .font(TandemFont.callout).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(Spacing.l)
            GeometryReader { geometry in
                if let image {
                    let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 20, dy: 20)
                    let space = MarkupSpace.aspectFit(imagePixelSize: CGSize(width: image.width, height: image.height), in: bounds)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: space.imageRect.width, height: space.imageRect.height)
                            .position(x: space.imageRect.midX, y: space.imageRect.midY)
                        if let region {
                            let rect = space.rect(CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
                            Path { path in
                                path.addRect(space.imageRect)
                                path.addRect(rect)
                            }
                            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                            Rectangle().strokeBorder(Theme.accent, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    region = SnapshotRegion.selection(from: value.startLocation, to: value.location, imageRect: space.imageRect)
                                })
                    }
                    .onHover { inside in
                        if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                    }
                    .disabled(model.studio.isCapturing)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.surfaceSunken)
            HStack(spacing: 12) {
                Button("Retake", systemImage: "arrow.clockwise") { model.studio.captureToComposer() }
                    .disabled(model.studio.isCapturing || !model.studio.canCapture)
                if let error = model.studio.regionSelectionError {
                    Text(error).font(TandemFont.caption).foregroundStyle(Theme.danger)
                } else {
                    Text(region == nil ? "No region selected" : "Drag again to change the selection")
                        .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if model.studio.isCapturing { ProgressView().controlSize(.small) }
                Button("Cancel") { model.studio.cancelRegionSelection() }
                    .keyboardShortcut(.cancelAction)
                Button("Add region") {
                    if let region { model.studio.addSelectedRegion(region) }
                }
                .buttonStyle(TandemButtonStyle(.primary))
                .disabled(region == nil || model.studio.isCapturing || !model.studio.canCapture)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.l)
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 500, idealHeight: 680)
        .task(id: selection.preview.header.id) {
            region = nil
            image = nil
            let data = selection.preview.data
            let decoded = await Task.detached(priority: .userInitiated) { ImageCodec.decode(data) }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}
