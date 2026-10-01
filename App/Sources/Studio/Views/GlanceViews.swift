import AppKit
import SwiftUI
import TandemCore
import TandemUI

/// Where the shared Mac's screen is on the live view, and how many stage points one of its
/// points takes. On a shared display the screen is the video itself; otherwise (a window or
/// camera is shared) it's drawn as a map of that screen.
struct GlanceStageGeometry {
    let screenRect: CGRect
    /// Stage points per Source point.
    let scale: CGFloat
    let screen: GlanceScreen
    let isOnVideo: Bool

    /// Until the Source reports its screen.
    static let fallbackScreen = GlanceScreen(width: 1512, height: 982, visibleFrame: .unit, isSharedDisplay: false)

    init(bounds: CGRect, screen: GlanceScreen?, videoSize: CGSize?) {
        let screen = screen ?? Self.fallbackScreen
        if screen.isSharedDisplay, let videoSize, videoSize.width > 0, videoSize.height > 0 {
            screenRect = MarkupSpace.aspectFitRect(for: videoSize, in: bounds)
            isOnVideo = true
        } else {
            screenRect = MarkupSpace.aspectFitRect(for: CGSize(width: screen.width, height: screen.height), in: bounds.insetBy(dx: 32, dy: 64))
            isOnVideo = false
        }
        scale = max(0.01, min(screenRect.width / max(screen.width, 1), screenRect.height / max(screen.height, 1)))
        self.screen = screen
    }

    /// The overlay on the stage. Its size is the Source's size in points at `scale`, so the
    /// stand-in wraps text exactly like the real overlay.
    func rect(for frame: GlanceFrame) -> CGRect {
        CGRect(
            x: screenRect.minX + frame.x * screenRect.width,
            y: screenRect.minY + frame.y * screenRect.height,
            width: frame.width * screen.width * scale,
            height: frame.height * screen.height * scale
        )
    }

    /// A drag on the stage as a change in fractions of the Source's screen.
    func fractions(of translation: CGSize) -> (dx: Double, dy: Double) {
        (Double(translation.width / max(screenRect.width, 1)), Double(translation.height / max(screenRect.height, 1)))
    }
}

extension GlanceOverlayView {
    /// The Source's footer line, so the stand-in's text area is the same height.
    static let standInHint = "⌃⌥G hides this · only you can see it"
}

/// The Glance tool on the live view: a stand-in for the overlay on the shared Mac, drawn
/// where it sits there. Drag it to move it, drag its corner to resize it, and scroll over
/// it to scroll the text. The real overlay follows within a frame or two.
struct GlanceStageOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var moveStart: GlanceFrame?
    @State private var resizeStart: GlanceFrame?
    @State private var hovering = false
    @State private var wheel = ScrollWheelMonitor()

    var body: some View {
        let studio = model.studio
        let glance = studio.glance
        GeometryReader { proxy in
            let video = studio.liveState == .live && studio.liveStats.width > 0
                ? CGSize(width: studio.liveStats.width, height: studio.liveStats.height) : nil
            let geometry = GlanceStageGeometry(bounds: CGRect(origin: .zero, size: proxy.size), screen: glance.remote?.screen, videoSize: video)
            let rect = geometry.rect(for: glance.layout.frame)
            ZStack(alignment: .topLeading) {
                Color.clear
                if !geometry.isOnVideo {
                    screenMap(geometry)
                }
                standIn(rect: rect, geometry: geometry)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear { wheel.scale = geometry.scale }
            .onChange(of: geometry.scale) { _, scale in wheel.scale = scale }
        }
        .onAppear {
            wheel.onScroll = { [weak glance] delta in glance?.scroll(by: delta) }
            wheel.start()
        }
        .onDisappear {
            wheel.stop()
            NSCursor.arrow.set()
        }
    }

    /// The Source's screen when it isn't what's shared (a window or camera is).
    private func screenMap(_ geometry: GlanceStageGeometry) -> some View {
        let rect = geometry.screenRect
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.55))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            Label("\(model.studio.sourceName ?? "The shared Mac")'s screen (the Glance is on it, not on what's shared)", systemImage: "display")
                .font(TandemFont.caption)
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(10)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }

    private func standIn(rect: CGRect, geometry: GlanceStageGeometry) -> some View {
        let glance = model.studio.glance
        let active = hovering || moveStart != nil || resizeStart != nil
        return GlanceOverlayView(
            content: glance.content,
            scrollOffset: glance.layout.scrollOffset,
            backgroundOpacity: glance.layout.backgroundOpacity,
            textScale: glance.layout.textScale,
            hint: GlanceOverlayView.standInHint
        )
        .frame(width: rect.width / geometry.scale, height: rect.height / geometry.scale)
        .scaleEffect(geometry.scale, anchor: .topLeading)
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .opacity(glance.layout.isVisible && glance.hasContent ? 1 : 0.55)
        .overlay {
            RoundedRectangle(cornerRadius: GlanceOverlayView.cornerRadius * geometry.scale, style: .continuous)
                .strokeBorder(Theme.accent.opacity(active ? 1 : 0.65), lineWidth: active ? 2 : 1.5)
        }
        .overlay(alignment: .top) {
            if !glance.layout.isVisible || !glance.hasContent {
                Text(glance.hasContent ? "Hidden" : "Type or pick an answer to show")
                    .font(TandemFont.micro)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .foregroundStyle(.white)
                    .offset(y: -22)
            }
        }
        .overlay(alignment: .bottomTrailing) { resizeHandle(geometry) }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            wheel.isHovering = inside
            if moveStart == nil { (inside ? NSCursor.openHand : NSCursor.arrow).set() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = moveStart ?? glance.layout.frame
                    if moveStart == nil {
                        moveStart = start
                        NSCursor.closedHand.set()
                    }
                    let delta = geometry.fractions(of: value.translation)
                    glance.setFrame(start.offsetBy(dx: delta.dx, dy: delta.dy), animated: false)
                }
                .onEnded { _ in
                    moveStart = nil
                    (hovering ? NSCursor.openHand : NSCursor.arrow).set()
                }
        )
        .help("Drag to move the Glance on \(model.studio.sourceName ?? "the shared Mac"); scroll over it to scroll its text")
        .offset(x: rect.minX, y: rect.minY)
    }

    private func resizeHandle(_ geometry: GlanceStageGeometry) -> some View {
        let glance = model.studio.glance
        return ZStack {
            Circle().fill(Theme.accent)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 16, height: 16)
        .offset(x: 6, y: 6)
        .contentShape(Rectangle().inset(by: -6))
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = resizeStart ?? glance.layout.frame
                    if resizeStart == nil { resizeStart = start }
                    let delta = geometry.fractions(of: value.translation)
                    glance.resize(from: start, dx: delta.dx, dy: delta.dy)
                }
                .onEnded { _ in resizeStart = nil }
        )
        .help("Drag to resize")
    }
}

/// Where the Glance is on the shared display while the tool is off: an outline only, since
/// the overlay itself never appears in the shared video.
struct GlanceStageOutline: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let studio = model.studio
        let glance = studio.glance
        if glance.isShowingOnSource, glance.remote?.screen.isSharedDisplay == true, studio.liveState == .live, studio.liveStats.width > 0 {
            GeometryReader { proxy in
                let geometry = GlanceStageGeometry(
                    bounds: CGRect(origin: .zero, size: proxy.size),
                    screen: glance.remote?.screen,
                    videoSize: CGSize(width: studio.liveStats.width, height: studio.liveStats.height)
                )
                let rect = geometry.rect(for: glance.remote?.frame ?? glance.layout.frame)
                RoundedRectangle(cornerRadius: GlanceOverlayView.cornerRadius * geometry.scale, style: .continuous)
                    .strokeBorder(GlanceOverlayView.mint.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .overlay(alignment: .topLeading) {
                        Label("Glance", systemImage: "sparkles")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(GlanceOverlayView.mint))
                            .offset(x: 6, y: -9)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The Glance controls at the bottom of the live view while the tool is on.
struct GlanceControlBar: View {
    @Environment(AppModel.self) private var model
    @State private var editorHeight = GlanceDraftEditor.minHeight

    var body: some View {
        @Bindable var glance = model.studio.glance
        let name = model.studio.sourceName ?? "the shared Mac"
        VStack(alignment: .leading, spacing: 6) {
            if let problem = glance.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 6) {
                GlanceDraftEditor(text: $glance.draft, height: $editorHeight, placeholder: "Type or paste text to show on \(name)…")
                    .frame(height: editorHeight)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.surfaceSunken.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Theme.stroke))
                    .help("Pasting from Notion, Google Docs, a web page, Word or Pages keeps the formatting. ⌥⇧⌘V pastes plain text.")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        showButton(titled: true)
                        latestAnswerButton(titled: true)
                    }
                    HStack(spacing: 6) {
                        showButton(titled: true)
                        latestAnswerButton(titled: false)
                    }
                    HStack(spacing: 6) {
                        showButton(titled: false)
                        latestAnswerButton(titled: false)
                    }
                }
                .fixedSize()
            }
            // Everything when there's room; the essentials and a menu on a narrow live view.
            ViewThatFits(in: .horizontal) {
                controls(.full)
                controls(.compact)
                controls(.minimal)
            }
        }
        .padding(8)
        .frame(maxWidth: 760)
        .tandemGlass(cornerRadius: Radius.l, interactive: true)
    }

    private enum Density { case full, compact, minimal }

    private func showButton(titled: Bool) -> some View {
        let glance = model.studio.glance
        let name = model.studio.sourceName ?? "the shared Mac"
        return Button {
            glance.showDraft()
        } label: {
            if titled {
                Label("Show", systemImage: "rectangle.portrait.and.arrow.forward")
                    .font(.system(size: 12.5, weight: .semibold))
            } else {
                Image(systemName: "rectangle.portrait.and.arrow.forward")
                    .font(.system(size: 12.5, weight: .semibold))
            }
        }
        .buttonStyle(TandemButtonStyle(.primary, size: .regular))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(glance.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(glance.liveTyping ? "Live typing is on: \(name) sees what you type" : "Show this text on \(name) (⌘↩)")
    }

    private func latestAnswerButton(titled: Bool) -> some View {
        let glance = model.studio.glance
        return Button {
            glance.showLatestAnswer()
        } label: {
            if titled {
                Label("Latest Answer", systemImage: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
            }
        }
        .buttonStyle(TandemButtonStyle(.secondary, size: .regular))
        .help("Show the newest AI answer on \(model.studio.sourceName ?? "the shared Mac") (it streams if it's still being written)")
    }

    private func controls(_ density: Density) -> some View {
        let glance = model.studio.glance
        let name = model.studio.sourceName ?? "the shared Mac"
        return HStack(spacing: 2) {
            if density == .full {
                liveTypingButton
                followButton
                divider
            }
            if density != .minimal {
                IconButton("arrow.up.to.line", help: "Scroll to the top") { glance.scroll(.top) }
                IconButton("chevron.up.2", help: "Page up") { glance.scroll(.pageUp) }
            }
            IconButton("chevron.up", help: "Scroll up (⌃⌥↑ from any app)") { glance.scroll(.lineUp) }
            IconButton("chevron.down", help: "Scroll down (⌃⌥↓ from any app)") { glance.scroll(.lineDown) }
            if density != .minimal {
                IconButton("chevron.down.2", help: "Page down") { glance.scroll(.pageDown) }
                IconButton("arrow.down.to.line", help: "Scroll to the end") { glance.scroll(.bottom) }
            }
            if density == .full {
                Text("\(Int((glance.scrollFraction * 100).rounded()))%")
                    .font(TandemFont.stat)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34)
                    .help("How far down the text the Glance is")
                divider
                placementMenu
                IconButton("textformat.size.smaller", help: "Smaller text") { glance.stepTextScale(-1) }
                IconButton("textformat.size.larger", help: "Larger text") { glance.stepTextScale(1) }
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 4)
                Slider(value: Binding(get: { glance.layout.backgroundOpacity }, set: { glance.setOpacity($0) }), in: GlanceLayout.opacityRange)
                    .controlSize(.mini)
                    .frame(width: 64)
                    .help("Backdrop opacity (the text stays opaque)")
            }
            divider
            IconButton(glance.layout.isVisible ? "eye" : "eye.slash", help: glance.layout.isVisible ? "Hide the Glance on \(name) (⌃⌥G)" : "Show the Glance on \(name) (⌃⌥G)", isActive: glance.layout.isVisible) {
                glance.toggleVisible()
            }
            if density == .full {
                IconButton("xmark.circle", help: "Clear the Glance") { glance.clear() }
                    .disabled(!glance.hasContent)
            } else {
                moreMenu
            }
            Spacer(minLength: 6)
            status(showsLabel: density != .minimal)
            Button("Done") { model.studio.toggleGlanceTool() }
                .buttonStyle(TandemButtonStyle(.secondary, size: .small))
                .keyboardShortcut(.escape, modifiers: [])
                .fixedSize()
        }
    }

    private var liveTypingButton: some View {
        let glance = model.studio.glance
        let name = model.studio.sourceName ?? "the shared Mac"
        return IconButton("character.cursor.ibeam", help: glance.liveTyping ? "Live typing is on: \(name) sees each keystroke" : "Live typing: show the text field as you type", isActive: glance.liveTyping, tint: GlanceOverlayView.mint) {
            glance.liveTyping.toggle()
        }
    }

    private var followButton: some View {
        let glance = model.studio.glance
        let name = model.studio.sourceName ?? "the shared Mac"
        return IconButton("text.line.first.and.arrowtriangle.forward", help: glance.followAnswers ? "Following answers: each new answer appears on \(name) as it's written" : "Follow answers: show each new answer as it's written", isActive: glance.followAnswers, tint: GlanceOverlayView.mint) {
            glance.followAnswers.toggle()
        }
    }

    /// The controls that don't fit on a narrow live view.
    private var moreMenu: some View {
        @Bindable var glance = model.studio.glance
        return Menu {
            Toggle("Live Typing", isOn: $glance.liveTyping)
            Toggle("Follow Answers", isOn: $glance.followAnswers)
            Divider()
            Menu("Position") {
                ForEach(GlancePlacement.allCases) { placement in
                    Button(placement.title) { glance.place(placement) }
                }
            }
            sizeMenu
            displayMenu
            Menu("Text Size") {
                Button("Larger") { glance.stepTextScale(1) }
                Button("Smaller") { glance.stepTextScale(-1) }
                Button("Standard") { glance.setTextScale(1) }
            }
            Menu("Backdrop") {
                ForEach([0.35, 0.55, 0.72, 0.9], id: \.self) { value in
                    Button("\(Int(value * 100))%") { glance.setOpacity(value) }
                }
            }
            Divider()
            Button("Clear Glance") { glance.clear() }
                .disabled(!glance.hasContent)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Live typing, following answers, position, size, text and backdrop")
    }

    /// Which of the shared Mac's displays it's on (only when it has several).
    @ViewBuilder
    private var displayMenu: some View {
        let glance = model.studio.glance
        if !glance.displays.isEmpty {
            Menu("Display") {
                Toggle("Whichever Is Shared", isOn: Binding(get: { glance.layout.displayID == nil }, set: { if $0 { glance.setDisplay(nil) } }))
                Divider()
                ForEach(glance.displays) { display in
                    Toggle(display.isShared ? "\(display.name) (shared)" : display.name, isOn: Binding(
                        get: { glance.layout.displayID == display.id },
                        set: { if $0 { glance.setDisplay(display.id) } }
                    ))
                }
            }
        }
    }

    @ViewBuilder
    private var sizeMenu: some View {
        let glance = model.studio.glance
        Menu("Size") {
            Button("Small") { glance.resize(widthFraction: 0.26, heightFraction: 0.3) }
            Button("Medium") { glance.resize(widthFraction: 0.36, heightFraction: 0.45) }
            Button("Large") { glance.resize(widthFraction: 0.5, heightFraction: 0.7) }
            Button("Tall Column") { glance.resize(widthFraction: 0.3, heightFraction: 0.92) }
        }
    }

    private var divider: some View {
        Hairline(vertical: true).frame(height: 18).padding(.horizontal, 4)
    }

    private var placementMenu: some View {
        let glance = model.studio.glance
        return Menu {
            Section("Position") {
                ForEach(GlancePlacement.allCases) { placement in
                    Button(placement.title) { glance.place(placement) }
                }
            }
            sizeMenu
            displayMenu
        } label: {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Snap the Glance to a corner or edge, pick a size, or choose the shared Mac's display")
    }

    private func status(showsLabel: Bool) -> some View {
        let glance = model.studio.glance
        return HStack(spacing: 5) {
            StatusDot(glance.isShowingOnSource ? Theme.success : Theme.textTertiary, pulsing: false, size: 6)
                .help(glance.isShowingOnSource ? "Showing on \(model.studio.sourceName ?? "the shared Mac")" : "Not showing")
            if showsLabel {
                Text(glance.isShowingOnSource ? "Showing" : "Not showing")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
            if let rtt = glance.roundTripMillis, glance.isShowingOnSource {
                Text("\(Int(rtt.rounded())) ms")
                    .font(TandemFont.stat)
                    .foregroundStyle(rtt < 50 ? Theme.success : rtt < 150 ? Theme.warning : Theme.danger)
                    .fixedSize()
                    .help("Round trip: from a change here to the shared Mac confirming it's on screen")
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Scroll-wheel and trackpad scrolls over the stand-in, in the Source's points.
@MainActor
final class ScrollWheelMonitor {
    var isHovering = false
    /// Stage points per Source point.
    var scale: CGFloat = 1
    var onScroll: ((Double) -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isHovering else { return event }
            // Precise (trackpad) deltas are points; a wheel's are lines.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
            guard delta != 0 else { return nil }
            // Content follows the fingers on the stand-in, so the Source moves by delta / scale.
            self.onScroll?(-Double(delta / max(self.scale, 0.01)))
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isHovering = false
    }
}
