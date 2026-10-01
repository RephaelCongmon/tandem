import AppKit
import SwiftUI
import TandemCore
import TandemUI

struct GlanceInjectToolbarButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var glance = model.studio.glance
        Button { glance.isPresented.toggle() } label: {
            Label("Glance Inject", systemImage: "rectangle.on.rectangle")
        }
        .help("Send text to a translucent overlay on the shared Mac")
        .popover(isPresented: $glance.isPresented, arrowEdge: .bottom) { GlanceInjectView() }
    }
}

struct GlanceInjectView: View {
    @Environment(AppModel.self) private var model
    private var glance: GlanceInjectController { model.studio.glance }
    var body: some View {
        @Bindable var glance = model.studio.glance
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Glance Inject", systemImage: "rectangle.on.rectangle").font(TandemFont.title)
                    Spacer()
                    if let status = glance.status, status.hasContent {
                        Text(status.visible ? "Visible" : "Hidden").font(TandemFont.caption)
                            .foregroundStyle(status.visible ? Theme.success : Theme.textSecondary)
                    }
                }
                Text("Put text on \(model.studio.sourceName ?? "the shared Mac") without interrupting its keyboard or mouse.")
                    .font(TandemFont.callout).foregroundStyle(Theme.textSecondary)
                if let message = glance.availabilityMessage ?? glance.error {
                    Label(message, systemImage: "info.circle").font(TandemFont.callout).foregroundStyle(Theme.warning)
                }
                TextEditor(text: $glance.draft)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 100)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Text to inject")
                HStack {
                    Button("Paste") { if let text = NSPasteboard.general.string(forType: .string) { glance.draft = text } }
                    Spacer()
                    Button("Inject Text") { glance.inject(glance.draft) }
                        .buttonStyle(TandemButtonStyle(.primary, size: .small))
                        .disabled(!glance.canInject || glance.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Hairline()
                VStack(alignment: .leading, spacing: 12) {
                    if let displays = glance.status?.displays, !displays.isEmpty {
                        Picker("Display", selection: Binding(get: { glance.layout.displayID ?? displays[0].id }, set: { id in
                            var layout = glance.layout; layout.displayID = id; glance.updateLayout(layout)
                        })) { ForEach(displays) { Text($0.name).tag($0.id) } }
                    }
                    GlancePlacementPad(controller: glance)
                        .frame(height: 135)
                    HStack {
                        Button("Top Left") { position(x: 0.04, y: 0.04) }
                        Button("Center") { position(x: 0.5, y: 0.5) }
                        Button("Top Right") { position(x: 0.96, y: 0.04) }
                        Spacer()
                    }.font(TandemFont.caption)
                    layoutSlider("Width", keyPath: \.width, range: 0.2...0.85)
                    layoutSlider("Height", keyPath: \.height, range: 0.18...0.85)
                    layoutSlider("Background", keyPath: \.opacity, range: 0.15...0.95)
                    layoutSlider("Text size", keyPath: \.fontSize, range: 12...28)
                    HStack {
                        Text("Scroll").frame(width: 85, alignment: .leading)
                        Button { glance.scrollBy(-80) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Scroll Glance up")
                        Slider(value: Binding(get: { glance.scrollFraction }, set: { glance.setScroll($0) }), in: 0...1)
                            .accessibilityLabel("Glance scroll position")
                        Button { glance.scrollBy(80) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Scroll Glance down")
                    }
                    HStack {
                        Button(glance.status?.visible == true ? "Hide Overlay" : "Show Overlay") { glance.setVisible(glance.status?.visible != true) }
                        Button("Clear") { glance.clear() }
                        Spacer()
                        Text("Drag the panel above to move it.").foregroundStyle(Theme.textSecondary)
                    }.font(TandemFont.caption)
                }
                .disabled(!glance.canManage)
                if let status = glance.status, status.hasContent, !status.isOwner {
                    Text("\(status.ownerName ?? "Another Studio") controls this overlay. Inject your text to take control.")
                        .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .font(TandemFont.callout).padding(20)
        }
        .frame(width: 460, height: 680)
        .background(Theme.surface)
    }
    private func position(x: Double, y: Double) {
        var layout = glance.layout; layout.x = x; layout.y = y; glance.updateLayout(layout)
    }
    private func layoutSlider(_ title: String, keyPath: WritableKeyPath<GlanceLayout, Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 85, alignment: .leading)
            Slider(value: Binding(get: { glance.layout[keyPath: keyPath] }, set: { value in
                var layout = glance.layout; layout[keyPath: keyPath] = value; glance.updateLayout(layout)
            }), in: range).accessibilityLabel("Glance \(title.lowercased())")
            Text(keyPath == \.fontSize ? "\(Int(glance.layout.fontSize)) pt" : "\(Int(glance.layout[keyPath: keyPath] * 100))%")
                .monospacedDigit().frame(width: 46, alignment: .trailing)
        }
    }
}

private struct GlancePlacementPad: View {
    let controller: GlanceInjectController
    @State private var start: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            let layout = controller.layout
            let display = controller.status?.displays.first { $0.id == layout.displayID } ?? controller.status?.displays.first
            let width = geometry.size.width * min(1, max(layout.width, 320 / (display?.width ?? 1440)))
            let height = geometry.size.height * min(1, max(layout.height, 160 / (display?.height ?? 900)))
            let remaining = CGSize(width: max(1, geometry.size.width - width), height: max(1, geometry.size.height - height))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSunken)
                Text("Shared display").font(TandemFont.caption).foregroundStyle(Theme.textTertiary).padding(10)
                RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.25))
                    .overlay(Text("Glance").font(TandemFont.caption).foregroundStyle(Theme.accent))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1))
                    .frame(width: width, height: height)
                    .offset(x: remaining.width * layout.x, y: remaining.height * layout.y)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if start == nil { start = CGPoint(x: remaining.width * layout.x, y: remaining.height * layout.y) }
                        guard let start else { return }
                        var updated = layout
                        updated.x = (start.x + value.translation.width) / remaining.width
                        updated.y = (start.y + value.translation.height) / remaining.height
                        controller.updateLayout(updated)
                    }.onEnded { _ in start = nil })
            }
            .accessibilityLabel("Glance overlay position")
        }
    }
}

struct GlanceSourceCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 10) {
            Label("Glance Inject", systemImage: "rectangle.on.rectangle").font(TandemFont.headline)
            Toggle("Allow text overlays", isOn: $settings.allowGlanceInject)
                .onChange(of: settings.allowGlanceInject) { _, _ in model.source.glanceSettingChanged() }
            if model.source.glance.session.content != nil {
                Text("From \(model.source.glance.ownerName ?? "the paired Mac") · \(model.source.glance.session.visible ? "visible" : "hidden")")
                    .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                if model.source.glance.session.visible {
                    Button("Hide Glance Inject") { model.source.glance.hide() }
                }
            } else {
                Text("Your paired Mac can show a passive text panel. Pausing sharing clears it.")
                    .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 12))
    }
}
