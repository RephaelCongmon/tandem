import SwiftUI
import TandemCore
import TandemUI

struct SourceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SourcePreviewPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if !model.source.hasScreenPermission && CaptureService.requiresScreenPermission(model.source.selectedSource) {
                        PermissionCard()
                    }
                    ViewersCard()
                    SendCard()
                    if model.settings.showRepliesOnSource, let reply = model.source.lastReply {
                        ReplyCard(reply: reply)
                    }
                    AutomationTransparencyCard()
                }
                .padding(Spacing.l)
            }
            .frame(width: 360)
            .background(Theme.surface)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { SourceStatusPill() }
            ToolbarItemGroup(placement: .primaryAction) {
                SourcePicker()
                Button {
                    model.source.toggleSharing()
                } label: {
                    Label(model.source.isSharingEnabled ? "Pause Sharing" : "Resume Sharing",
                          systemImage: model.source.isSharingEnabled ? "pause.fill" : "play.fill")
                }
                .help(model.source.isSharingEnabled ? "Pause sharing (⇧⌘P)" : "Resume sharing (⇧⌘P)")
            }
        }
        .task { await model.source.refreshCatalog() }
    }
}

private struct SourceStatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let source = model.source
        HStack(spacing: 7) {
            StatusDot(color, pulsing: source.isStreaming, size: 7)
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        let source = model.source
        if !source.isActive { return Theme.warning }
        if source.isStreaming { return Theme.live }
        if case .error = source.captureState { return Theme.danger }
        return source.viewers.isEmpty ? Theme.textTertiary : Theme.success
    }

    private var title: String {
        let source = model.source
        if !source.isSharingEnabled { return "Sharing paused" }
        if source.isLockPaused { return "Paused while locked" }
        if source.isStreaming {
            let names = ListFormatter.localizedString(byJoining: source.viewers.filter(\.isWatching).map(\.name))
            return "Live to \(names)"
        }
        if !source.viewers.isEmpty { return "Connected · idle" }
        return "Waiting for a Studio"
    }
}

/// Picks the display, window or camera to share.
struct SourcePicker: View {
    @Environment(AppModel.self) private var model

    private var pickerTitle: String {
        let source = model.source
        if let title = source.current?.title { return title }
        if let selected = source.selectedSource, let match = source.catalog.first(where: { $0.source == selected }) { return match.title }
        if !source.hasScreenPermission && CaptureService.requiresScreenPermission(source.selectedSource) { return "Screen Recording Needed" }
        return "Choose What to Share"
    }

    var body: some View {
        let source = model.source
        Menu {
            ForEach(CaptureKind.allCases, id: \.self) { kind in
                let items = source.catalog.filter { $0.source.kind == kind }
                if !items.isEmpty {
                    Section(kind.displayName + "s") {
                        ForEach(items) { item in
                            Button {
                                source.select(item.source)
                            } label: {
                                if source.selectedSource == item.source {
                                    Label(item.title, systemImage: "checkmark")
                                } else {
                                    Text(item.title)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Refresh") { Task { await source.refreshCatalog() } }
        } label: {
            Label(pickerTitle, systemImage: source.selectedSource?.kind.systemImage ?? "display")
        }
        .help("Choose what to share")
    }
}

private struct SourcePreviewPanel: View {
    @Environment(AppModel.self) private var model
    @State private var thumbnail: CGImage?

    var body: some View {
        let source = model.source
        ZStack {
            Theme.surfaceSunken
            if source.isStreaming {
                VideoLayerView(layer: source.previewLayer)
            } else if let thumbnail, source.isActive {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.6)
                    .blur(radius: 6)
            }
            if !source.isStreaming {
                idleOverlay
                    .padding(Spacing.m)
                    .tandemGlass(cornerRadius: Radius.xl)
                    .padding(Spacing.xl)
            }
        }
        .overlay(alignment: .topLeading) {
            if source.isStreaming {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        StatusDot(Theme.live, pulsing: true, size: 7)
                        Text("SHARING").font(.system(size: 10, weight: .heavy)).tracking(0.8)
                    }
                    if let title = source.current?.title {
                        Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    }
                    Hairline(vertical: true).frame(height: 12)
                    StatChip(systemImage: "speedometer", value: "\(Int(source.streamStats.framesPerSecond.rounded())) fps")
                    if source.streamStats.width > 0 {
                        StatChip(systemImage: "rectangle.dashed", value: "\(source.streamStats.width)×\(source.streamStats.height)")
                    }
                    StatChip(systemImage: "arrow.up", value: Formatters.bitrate(kbps: Double(source.streamStats.bitrateKbps)))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .tandemGlassCapsule()
                .padding(Spacing.m)
            }
        }
        .clipped()
        .onAppear { source.setPreviewVisible(true) }
        .onDisappear { source.setPreviewVisible(false) }
        .task(id: "\(source.selectedSource?.id ?? "")-\(source.isActive)-\(source.hasScreenPermission)") {
            thumbnail = await source.thumbnail()
        }
    }

    @ViewBuilder
    private var idleOverlay: some View {
        let source = model.source
        if !source.isSharingEnabled {
            EmptyStateView(systemImage: "pause.circle", title: "Sharing is paused", message: "Nothing is captured or sent while paused. Resume to let your Studio see this Mac again.") {
                Button("Resume Sharing") { source.setSharing(true) }.buttonStyle(TandemButtonStyle(.primary))
            }
        } else if source.isLockPaused {
            EmptyStateView(systemImage: "lock", title: "Paused while locked", message: "Sharing resumes automatically when you unlock this Mac.")
        } else if case .error(let message) = source.captureState {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't capture", message: message) {
                Button("Try Again") { Task { await source.refreshCatalog() } }.buttonStyle(TandemButtonStyle(.secondary))
            }
        } else if source.viewers.isEmpty {
            EmptyStateView(
                systemImage: "dot.radiowaves.left.and.right",
                title: "Ready to share",
                message: "On your other Mac, open Tandem in Studio mode and connect to “\(model.identity.name)”. Nothing is captured until it's viewing."
            )
        } else {
            EmptyStateView(systemImage: "eye.slash", title: "Connected — live view off", message: "The Studio isn't watching the live view right now. Snapshots still work.")
        }
    }
}

private struct PermissionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Screen Recording is off", systemImage: "rectangle.dashed.badge.record")
                .font(TandemFont.headline)
                .foregroundStyle(Theme.warning)
            Text("Allow Tandem in System Settings › Privacy & Security › Screen & System Audio Recording so your Studio can see this Mac.")
                .font(TandemFont.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow…") { model.source.requestPermission() }.buttonStyle(TandemButtonStyle(.primary, size: .small))
                Button("Open Settings") { CaptureService.openScreenRecordingSettings() }.buttonStyle(TandemButtonStyle(.secondary, size: .small))
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.warning.opacity(0.1)))
    }
}

private struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                SectionLabel(title)
                Spacer()
                trailing
            }
            content
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tandemPanel(cornerRadius: Radius.l, fill: Theme.surfaceRaised.opacity(0.6))
    }
}

private struct ViewersCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Viewers") {
            if model.source.viewers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Studio connected")
                        .font(TandemFont.callout.weight(.medium))
                    Text(discoverability)
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Accept new pairing requests", isOn: Binding(
                        get: { model.settings.acceptPairingRequests },
                        set: { model.settings.acceptPairingRequests = $0 }
                    ))
                    .font(TandemFont.caption)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            } else {
                VStack(spacing: Spacing.s) {
                    ForEach(model.source.viewers) { viewer in
                        ViewerRow(viewer: viewer)
                    }
                }
            }
        }
    }

    private var discoverability: String {
        switch model.connections.listenerState {
        case .ready(let port):
            let addresses = model.connections.localAddresses.prefix(2).map { "\($0):\(port)" }.joined(separator: ", ")
            return "“\(model.identity.name)” is discoverable nearby\(addresses.isEmpty ? "." : " (\(addresses)).")"
        case .waitingForPermission:
            return "Allow Local Network access for Tandem in System Settings so your Studio can find this Mac."
        case .failed(let message):
            return "Not discoverable: \(message)"
        default:
            return "Starting…"
        }
    }
}

private struct ViewerRow: View {
    @Environment(AppModel.self) private var model
    let viewer: SourceEngine.Viewer

    var body: some View {
        HStack(spacing: 10) {
            DeviceIcon(model: viewer.connection.peer?.model ?? "Mac", size: 32, tint: viewer.isWatching ? Theme.live : Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewer.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    LinkBadge(link: viewer.connection.linkKind)
                    if let rtt = viewer.connection.stats.rttMillis {
                        StatChip(systemImage: "timer", value: "\(Int(rtt.rounded())) ms")
                    }
                    Text(viewer.approved ? (viewer.isWatching ? "Watching" : "Idle") : "Awaiting approval")
                        .font(TandemFont.caption)
                        .foregroundStyle(viewer.isWatching ? Theme.live : Theme.textSecondary)
                }
            }
            Spacer()
            Menu {
                Button("Disconnect") { model.connections.disconnect(viewer.connection) }
                if let id = viewer.connection.peer?.id {
                    Button("Unpair", role: .destructive) { model.connections.forget(id) }
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct SendCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let source = model.source
        Card(title: "Send to Studio") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Button {
                    Task { model.toasts.showPush(await source.pushSnapshot(note: nil)) }
                } label: {
                    HStack {
                        Label("Send Snapshot", systemImage: "paperplane.fill")
                        Spacer()
                        if let combo = model.settings.combo(for: .sendSnapshot) { KeyCaps(combo.displayKeys) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TandemButtonStyle(.primary))
                .disabled(source.viewers.isEmpty || !source.isActive || source.isPushing)

                Button {
                    QuickNotePanelController.shared.present(model: model)
                } label: {
                    HStack {
                        Label("Send with Note…", systemImage: "text.bubble")
                        Spacer()
                        if let combo = model.settings.combo(for: .sendSnapshotWithNote) { KeyCaps(combo.displayKeys) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TandemButtonStyle(.secondary))
                .disabled(source.viewers.isEmpty || !source.isActive)

                if let push = source.lastPush {
                    HStack(spacing: 6) {
                        Image(systemName: push.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(push.error == nil ? Theme.success : Theme.warning)
                        Text(push.error ?? "Sent \(Formatters.relative(push.date))\(push.note.map { " · “\($0)”" } ?? "")")
                            .font(TandemFont.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Text("Use the shortcuts from any app — the AI's answer appears on your Studio\(model.settings.showRepliesOnSource ? " and here" : "").")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReplyCard: View {
    let reply: ReplyMirror

    static func displayName(for model: String) -> String {
        let presets = AIProviderKind.allCases.flatMap { ModelCatalog.presets(for: $0) }
        return presets.first { $0.id == model }?.displayName ?? model
    }

    var body: some View {
        Card(title: "Latest answer", trailing: reply.isFinal ? nil : AnyView(ProgressView().controlSize(.mini))) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let prompt = reply.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(TandemFont.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                if reply.text.isEmpty {
                    TypingDots()
                } else {
                    MarkdownView(reply.text, style: .compact)
                }
                if let model = reply.model {
                    Text(Self.displayName(for: model)).font(TandemFont.micro).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

private struct AutomationTransparencyCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let automated = model.source.viewers.compactMap { viewer -> (String, AutomationStatus)? in
            guard let status = viewer.automation, status.autoCaptureEnabled else { return nil }
            return (viewer.name, status)
        }
        if !automated.isEmpty {
            Card(title: "Automatic captures") {
                ForEach(automated, id: \.0) { name, status in
                    Label("\(name) captures every \(Formatters.interval(status.intervalSeconds))\(status.asksAutomatically ? " and asks the AI" : "")", systemImage: "timer")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
