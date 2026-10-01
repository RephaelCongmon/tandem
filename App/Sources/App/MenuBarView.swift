import SwiftUI
import TandemCore
import TandemUI

/// Menu bar icon: shows at a glance whether this Mac is sharing or connected.
struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Tandem — \(accessibilityState)")
            // The icon exists even when Tandem starts without a window (e.g. at login).
            .onAppear {
                model.registerSceneActions(openMainWindow: { openWindow(id: "main") }, openSettings: { openSettings() })
            }
    }

    private var symbol: String {
        switch model.settings.role {
        case .source:
            if !model.source.isActive { return "pause.rectangle" }
            return model.source.isStreaming ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle"
        case .studio:
            return model.studio.isConnected ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack"
        case nil:
            return "rectangle.on.rectangle"
        }
    }

    private var accessibilityState: String {
        switch model.settings.role {
        case .source: return model.source.isStreaming ? "sharing live" : (model.source.isActive ? "ready" : "paused")
        case .studio: return model.studio.isConnected ? "connected" : "not connected"
        case nil: return "not set up"
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            Hairline()
            switch model.settings.role {
            case .source: SourceMenuSection()
            case .studio: StudioMenuSection()
            case nil:
                Text("Finish setting up Tandem to start.")
                    .font(TandemFont.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let release = model.updates.latest {
                Hairline()
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                    Text(model.updates.installPhase ?? "Tandem \(release.version.description) is available")
                        .font(TandemFont.callout)
                        .lineLimit(1)
                    Spacer()
                    Button("Update Now") { Task { await model.updates.updateNow() } }
                        .buttonStyle(TandemButtonStyle(.primary, size: .small))
                        .disabled(model.updates.isUpdating)
                }
            }
            Hairline()
            HStack {
                Button("Open Tandem") { model.showMainWindow() }
                    .buttonStyle(TandemButtonStyle(.secondary, size: .small))
                Button("Settings…") {
                    model.showMainWindow()
                    model.openSettingsAction?()
                }
                .buttonStyle(TandemButtonStyle(.ghost, size: .small))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(TandemButtonStyle(.ghost, size: .small))
            }
        }
        .padding(Spacing.m)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tandem").font(TandemFont.headline)
                Text(model.identity.name).font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let role = model.settings.role {
                Pill(role.shortTitle, systemImage: role.systemImage, tint: Theme.accent)
            }
        }
    }
}

private struct SourceMenuSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let source = model.source
        VStack(alignment: .leading, spacing: Spacing.s) {
            Toggle(isOn: Binding(get: { source.isSharingEnabled }, set: { source.setSharing($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sharing").font(TandemFont.headline)
                    Text(statusText).font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 8) {
                Button {
                    Task { model.toasts.showPush(await source.pushSnapshot(note: nil)) }
                } label: {
                    Label("Send Snapshot", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(TandemButtonStyle(.primary, size: .small))
                .disabled(source.viewers.isEmpty || !source.isActive)
                Button {
                    QuickNotePanelController.shared.present(model: model)
                } label: {
                    Label("With Note…", systemImage: "text.bubble").frame(maxWidth: .infinity)
                }
                .buttonStyle(TandemButtonStyle(.secondary, size: .small))
                .disabled(source.viewers.isEmpty || !source.isActive)
            }

            if model.settings.showRepliesOnSource, let reply = source.lastReply {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Latest answer")
                    ScrollView {
                        MarkdownView(reply.text.isEmpty ? "…" : reply.text, style: .compact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    private var statusText: String {
        let source = model.source
        if !source.isSharingEnabled { return "Paused — nothing is captured" }
        if source.isLockPaused { return "Paused while locked" }
        if source.isStreaming { return "Live to \(source.watchingCount) viewer\(source.watchingCount == 1 ? "" : "s")" }
        if source.viewers.isEmpty { return "Waiting for a Studio" }
        return "Connected, idle"
    }
}

private struct StudioMenuSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let studio = model.studio
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: 8) {
                StatusDot(studio.isConnected ? Theme.success : Theme.textTertiary, pulsing: studio.hasVideo, size: 8)
                Text(studio.sourceName.map { "Connected to \($0)" } ?? "Not connected")
                    .font(TandemFont.headline)
                Spacer()
                if let connection = studio.connection, connection.isConnected {
                    LinkBadge(link: connection.linkKind)
                }
            }
            HStack(spacing: 8) {
                Button {
                    studio.captureAndAsk()
                } label: {
                    Label("Ask", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(TandemButtonStyle(.primary, size: .small))
                .disabled(!model.chat.canSendFromComposer)
                Button {
                    studio.setRegionTool(true)
                    model.showMainWindow()
                } label: {
                    Label("Select region", systemImage: "rectangle.dashed").frame(maxWidth: .infinity)
                }
                .buttonStyle(TandemButtonStyle(.secondary, size: .small))
                .disabled(!studio.canCapture || studio.isCapturing)
            }
            Toggle(isOn: Binding(get: { model.settings.autoCaptureEnabled }, set: { _ in studio.toggleAutoCapture() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-capture every \(Formatters.interval(model.settings.autoCaptureInterval))")
                    if let result = studio.lastAutoResult, model.settings.autoCaptureEnabled {
                        Text(result).font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(!studio.isConnected)

            if let reply = model.chat.streaming {
                LatestReplyPreview(text: reply.text, isStreaming: true)
            } else if let last = model.chat.selectedThread?.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                LatestReplyPreview(text: last.text, isStreaming: false)
            }
        }
    }
}

private struct LatestReplyPreview: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(isStreaming ? "Answering…" : "Latest answer")
                if isStreaming { ProgressView().controlSize(.mini) }
            }
            ScrollView {
                MarkdownView(text.isEmpty ? "…" : text, style: .compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }
}
