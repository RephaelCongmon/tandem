import SwiftUI
import TandemCore
import TandemUI

/// The live view of the shared Mac, with HUD and capture controls.
struct StageView: View {
    @Environment(AppModel.self) private var model
    @Binding var focus: Bool
    /// Chrome is visible unless the pointer rests over the video for a moment.
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.surfaceSunken
            VideoLayerView(layer: model.studio.renderer.displayLayer)
                .opacity(model.studio.liveState == .live ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: model.studio.liveState == .live)
            overlayContent
        }
        .overlay(alignment: .topLeading) {
            if model.studio.isConnected {
                StageHUD()
                    .padding(Spacing.m)
                    .opacity(chromeVisible || model.studio.liveState != .live ? 1 : 0)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.studio.isConnected {
                HStack(spacing: 6) {
                    RemoteSourceMenu()
                    IconButton(focus ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: focus ? "Exit focus mode" : "Focus on the live view") {
                        withAnimation(.spring(response: 0.35)) { focus.toggle() }
                    }
                    .tandemGlassCapsule(interactive: true)
                }
                .padding(Spacing.m)
                .opacity(chromeVisible || model.studio.liveState != .live ? 1 : 0)
            }
        }
        .overlay(alignment: .bottom) {
            if model.studio.isConnected {
                StageToolbar()
                    .padding(.bottom, Spacing.l)
                    .opacity(chromeVisible || model.studio.liveState != .live ? 1 : 0)
            }
        }
        .overlay(alignment: .center) {
            if let progress = model.studio.connection?.snapshotProgress, progress.totalBytes > 0 {
                SnapshotProgressBadge(progress: progress)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                chromeVisible = true
                scheduleHide()
            case .ended:
                hideTask?.cancel()
                chromeVisible = true
            }
        }
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.35)) { focus.toggle() }
        }
        .clipped()
        .onAppear { model.studio.stageAppeared() }
        .onDisappear { model.studio.stageDisappeared() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            chromeVisible = false
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch model.studio.liveState {
        case .live:
            EmptyView()
        case .noSource:
            ScrollView {
                VStack(spacing: Spacing.l) {
                    EmptyStateView(
                        systemImage: "rectangle.on.rectangle.angled",
                        title: "Connect your other Mac",
                        message: "Open Tandem on the Mac you want to see and choose Share this Mac. It connects over Wi-Fi, a Thunderbolt or Ethernet cable, or Bluetooth."
                    )
                    NearbyDeviceList(compact: false)
                        .frame(maxWidth: 420)
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        case .connecting, .waitingForVideo:
            VStack(spacing: Spacing.m) {
                ProgressView().controlSize(.large)
                Text(model.studio.liveState == .connecting ? "Connecting…" : "Starting live view…")
                    .font(TandemFont.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .sourcePaused(let message):
            EmptyStateView(systemImage: "pause.circle", title: "Sharing is paused", message: message)
        case .sourceProblem(let message):
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "The other Mac needs attention", message: message)
        case .previewOff:
            EmptyStateView(systemImage: "eye.slash", title: "Live view is off", message: "Snapshots still work. Turn the live view back on to watch in real time.") {
                Button("Show Live View") { model.studio.livePreviewEnabled = true }
                    .buttonStyle(TandemButtonStyle(.primary))
            }
        }
    }
}

private struct StageHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.studio.liveStats
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                StatusDot(model.studio.liveState == .live ? Theme.live : Theme.textTertiary, pulsing: model.studio.liveState == .live, size: 7)
                Text(model.studio.liveState == .live ? "LIVE" : "IDLE")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.8)
            }
            if let capture = model.studio.sourceStatus?.capture {
                Text(capture.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            if model.studio.liveState == .live {
                Hairline(vertical: true).frame(height: 12)
                if let latency = stats.latencyMillis {
                    StatChip(systemImage: "bolt.fill", value: "\(Int(latency.rounded())) ms", tint: latencyTint(latency))
                        .help("Glass-to-glass latency estimate")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // The Source only sends frames when pixels change.
                    if let last = stats.lastFrameAt, context.date.timeIntervalSince(last) > 1.5 {
                        StatChip(systemImage: "pause.circle", value: "No motion")
                            .help("The shared screen hasn't changed; frames resume as soon as it does.")
                    } else {
                        StatChip(systemImage: "speedometer", value: "\(Int(stats.framesPerSecond.rounded())) fps")
                    }
                }
                if stats.width > 0 {
                    StatChip(systemImage: "rectangle.dashed", value: "\(stats.width)×\(stats.height)")
                }
                StatChip(systemImage: "arrow.down", value: Formatters.bitrate(kbps: stats.bitrateKbps))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .tandemGlassCapsule()
    }

    private func latencyTint(_ latency: Double) -> Color {
        latency < 80 ? Theme.success : latency < 200 ? Theme.warning : Theme.danger
    }
}

private struct StageToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let studio = model.studio
        let settings = model.settings
        HStack(spacing: 4) {
            Button {
                studio.captureAndAsk()
            } label: {
                Label("Ask", systemImage: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(TandemButtonStyle(.primary, size: .regular))
            .disabled(!model.chat.canSendFromComposer)
            .help("Ask using your text and selected pictures (⇧⌘↩)")

            Button { studio.captureToComposer() } label: {
                Label("Select region", systemImage: "rectangle.dashed")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(TandemButtonStyle(.secondary, size: .regular))
            .disabled(!studio.canCapture || studio.isCapturing)
            .help("Freeze a frame and drag to select a picture (⇧⌘S)")

            Hairline(vertical: true).frame(height: 18).padding(.horizontal, 4)

            AutoCaptureControl()

            Hairline(vertical: true).frame(height: 18).padding(.horizontal, 4)

            IconButton(studio.livePreviewEnabled ? "eye" : "eye.slash",
                       help: studio.livePreviewEnabled ? "Turn off the live view (snapshots keep working)" : "Turn on the live view",
                       isActive: studio.livePreviewEnabled) {
                studio.livePreviewEnabled.toggle()
            }
            Menu {
                Picker("Live quality", selection: Binding(get: { settings.liveQuality }, set: {
                    settings.liveQuality = $0
                    studio.sendStreamRequest()
                })) {
                    ForEach(LiveQualityPreset.allCases) { preset in
                        Text("\(preset.title) — \(preset.detail)").tag(preset)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "dial.medium")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Live view quality")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .tandemGlassCapsule(interactive: true)
    }
}

/// Toggle + interval + countdown for automatic captures.
struct AutoCaptureControl: View {
    @Environment(AppModel.self) private var model
    static let presets: [Double] = [5, 10, 15, 30, 60, 120, 300, 600]

    var body: some View {
        let settings = model.settings
        let studio = model.studio
        HStack(spacing: 2) {
            IconButton("timer", help: settings.autoCaptureEnabled ? "Turn off auto-capture (⇧⌘T)" : "Turn on auto-capture (⇧⌘T)",
                       isActive: settings.autoCaptureEnabled, tint: Theme.accentSecondary) {
                studio.toggleAutoCapture()
            }
            Menu {
                Picker("Every", selection: Binding(get: { settings.autoCaptureInterval }, set: {
                    settings.autoCaptureInterval = $0
                    studio.restartAutomation()
                })) {
                    ForEach(Self.presets, id: \.self) { Text("Every \(Formatters.interval($0))").tag($0) }
                    if !Self.presets.contains(settings.autoCaptureInterval) {
                        Text("Every \(Formatters.interval(settings.autoCaptureInterval))").tag(settings.autoCaptureInterval)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Ask the AI automatically", isOn: Binding(get: { settings.autoAsk }, set: {
                    settings.autoAsk = $0
                    studio.sendAutomationStatus()
                }))
                Toggle("Only when the screen changes", isOn: Binding(get: { settings.onlyWhenChanged }, set: { settings.onlyWhenChanged = $0 }))
                Divider()
                Button("Automation Settings…") { model.openSettingsAction?() }
            } label: {
                HStack(spacing: 3) {
                    Text(Formatters.interval(settings.autoCaptureInterval))
                        .font(TandemFont.stat)
                    if settings.autoCaptureEnabled, let next = studio.nextAutoCaptureAt {
                        Text(timerInterval: Date()...max(Date(), next), countsDown: true)
                            .font(TandemFont.stat)
                            .foregroundStyle(Theme.accentSecondary)
                            .frame(width: 34)
                    }
                }
                .foregroundStyle(settings.autoCaptureEnabled ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 4)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(studio.lastAutoResult ?? "Auto-capture interval")
        }
    }
}

/// Lets the Studio choose which display/window/camera the Source shares.
private struct RemoteSourceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let studio = model.studio
        if studio.sourceStatus?.allowsRemoteSourceSelection == true, !studio.remoteCatalog.isEmpty {
            Menu {
                ForEach(CaptureKind.allCases, id: \.self) { kind in
                    let items = studio.remoteCatalog.filter { $0.source.kind == kind }
                    if !items.isEmpty {
                        Section(kind.displayName + "s") {
                            ForEach(items) { item in
                                Button {
                                    studio.selectRemoteSource(item.source)
                                } label: {
                                    if studio.sourceStatus?.capture?.source == item.source {
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
                Button("Refresh List") { studio.refreshRemoteCatalog() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: studio.sourceStatus?.capture?.source.kind.systemImage ?? "display")
                    Text("Source")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.visible)
            .fixedSize()
            .tandemGlassCapsule(interactive: true)
            .help("Choose what the other Mac shares")
        }
    }
}

private struct SnapshotProgressBadge: View {
    let progress: SnapshotAssembler.Progress

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text("Receiving screenshot · \(Formatters.bytes(progress.totalBytes))")
                .font(TandemFont.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Spacing.m)
        .tandemGlass(cornerRadius: Radius.m)
    }
}
