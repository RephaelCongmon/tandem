import AppKit
import Observation
import SwiftUI
import TandemCore
import TandemUI

// MARK: - Toasts

/// Small transient HUD shown near the top of the screen, even when Tandem is in
/// the background (feedback for global shortcuts).
@MainActor
@Observable
final class ToastCenter {
    enum Style { case normal, success, warning }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var systemImage: String
        var style: Style
    }

    private(set) var current: Toast?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ text: String, systemImage: String, style: Style = .normal) {
        current = Toast(text: text, systemImage: systemImage, style: style)
        presentPanel()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func showPush(_ feedback: SourceEngine.PushFeedback) {
        if let error = feedback.error {
            show(error, systemImage: "exclamationmark.triangle.fill", style: .warning)
        } else {
            let names = ListFormatter.localizedString(byJoining: feedback.recipients)
            show("Sent to \(names)", systemImage: "paperplane.fill", style: .success)
        }
    }

    private func dismiss() {
        let dismissing = current?.id
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel?.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // A newer toast may have appeared during the fade.
                guard self.current?.id == dismissing else { return }
                self.panel?.orderOut(nil)
                self.current = nil
            }
        })
    }

    private func presentPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 420, height: 64)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 18)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: ToastView(center: self))
        return panel
    }
}

private struct ToastView: View {
    let center: ToastCenter

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint(toast.style))
                    Text(toast.text)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .tandemGlassCapsule()
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: center.current)
    }

    private func tint(_ style: ToastCenter.Style) -> Color {
        switch style {
        case .normal: return Theme.accent
        case .success: return Theme.success
        case .warning: return Theme.warning
        }
    }
}

// MARK: - Quick note panel

/// Spotlight-style panel for "Send snapshot with note…" on the Source Mac. The
/// screenshot is taken before the panel appears, so the panel is never in it.
@MainActor
final class QuickNotePanelController {
    static let shared = QuickNotePanelController()
    private var panel: NSPanel?

    func present(model: AppModel) {
        guard model.settings.role == .source else { return }
        guard model.source.canPush else {
            model.toasts.show(model.source.isActive ? "No Studio is connected" : "Sharing is paused", systemImage: "exclamationmark.triangle.fill", style: .warning)
            return
        }
        Task {
            await model.source.prepareNotePush()
            show(model: model)
        }
    }

    private func show(model: AppModel) {
        close()
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 172),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let view = QuickNoteView(
            source: model.source,
            onSend: { [weak self] note in
                self?.close()
                Task {
                    let feedback = await model.source.pushSnapshot(note: note)
                    model.toasts.showPush(feedback)
                }
            },
            onCancel: { [weak self] in
                model.source.discardPreparedPush()
                self?.close()
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 280, y: frame.maxY - frame.height * 0.28))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A borderless panel that can take keyboard focus without activating the app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct QuickNoteView: View {
    let source: SourceEngine
    let onSend: (String) -> Void
    let onCancel: () -> Void
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image = source.preparedPush {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Theme.surfaceSunken
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(width: 150, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accentGradient)
                    Text("Send to the Studio").font(TandemFont.headline)
                    Spacer()
                    KeyCaps(["esc"]).opacity(0.8)
                }
                TextField("Add context for the AI (optional)…", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...3)
                    .focused($focused)
                    .onSubmit { onSend(note) }
                HStack {
                    Text("↩ to send · the screenshot was taken when this opened")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Send") { onSend(note) }
                        .buttonStyle(TandemButtonStyle(.primary, size: .small))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 150)
        .tandemGlass(cornerRadius: Radius.xl)
        .padding(11)
        .onAppear { focused = true }
        .onExitCommand(perform: onCancel)
    }
}
