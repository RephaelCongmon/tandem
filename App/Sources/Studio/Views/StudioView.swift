import SwiftUI
import TandemCore
import TandemUI

struct StudioView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var focusStage = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            StudioSidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .background(WindowVisibilityReader { visible in model.studio.isStageVisible = visible || AppEnvironment.ignoreOcclusion })
    }

    @ViewBuilder
    private var detail: some View {
        let showStage = model.settings.showStage
        if focusStage {
            StageView(focus: $focusStage)
        } else if showStage {
            HSplitView {
                StageView(focus: $focusStage)
                    .frame(minWidth: 380, idealWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
                ThreadPanel()
                    .frame(minWidth: 400, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ThreadPanel()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ConnectionStatusPill()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            UpdateToolbarButton()

            GlanceInjectToolbarButton()

            Button {
                model.settings.showStage.toggle()
                if !model.settings.showStage { focusStage = false }
            } label: {
                Label(model.settings.showStage ? "Hide Live View Panel" : "Show Live View Panel", systemImage: "rectangle.split.2x1")
            }
            .help(model.settings.showStage ? "Hide the live view panel" : "Show the live view panel")

            ModelMenu()

            Button {
                model.chat.newThread()
            } label: {
                Label("New Thread", systemImage: "square.and.pencil")
            }
            .help("New thread (⌘N)")
        }
    }
}

/// Toolbar status: which Mac we're connected to and over what.
struct ConnectionStatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color, pulsing: model.studio.liveState == .live, size: 7)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let connection = model.studio.connection, connection.isConnected {
                LinkBadge(link: connection.linkKind)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch model.studio.liveState {
        case .live: return Theme.success
        case .noSource: return Theme.textTertiary
        case .sourcePaused, .previewOff: return Theme.warning
        case .sourceProblem: return Theme.danger
        case .connecting, .waitingForVideo: return Theme.accentSecondary
        }
    }

    private var title: String {
        guard let name = model.studio.sourceName, model.studio.isConnected else {
            if let target = model.connections.desiredSourceID, let peer = model.trust.peer(target) {
                return "Reconnecting to \(peer.name)…"
            }
            return "Not connected"
        }
        switch model.studio.liveState {
        case .live: return name
        case .sourcePaused: return "\(name) · paused"
        case .previewOff: return "\(name) · live view off"
        case .sourceProblem: return "\(name) · needs attention"
        default: return "\(name) · starting…"
        }
    }
}

/// Provider/model/effort picker shown in the toolbar.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        Menu {
            Section("Provider") {
                Picker("Provider", selection: Binding(get: { settings.provider }, set: { settings.provider = $0 })) {
                    ForEach(AIProviderKind.menuOrder) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if !ModelCatalog.presets(for: settings.provider).isEmpty {
                Section("Model") {
                    Picker("Model", selection: Binding(get: { settings.currentModel }, set: { settings.currentModel = $0 })) {
                        ForEach(ModelCatalog.presets(for: settings.provider)) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                        if !ModelCatalog.presets(for: settings.provider).contains(where: { $0.id == settings.currentModel }) {
                            Text(settings.currentModel).tag(settings.currentModel)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            let capabilities = ModelCatalog.capabilities(for: settings.currentModel, provider: settings.provider)
            if !capabilities.supportedEfforts.isEmpty {
                Section("Reasoning") {
                    Picker("Effort", selection: Binding(get: { settings.effort }, set: { settings.effort = $0 })) {
                        ForEach(capabilities.supportedEfforts) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Divider()
            Button("AI Settings…") { model.openSettingsAction?() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                Text(settings.currentModelDisplayName)
                    .lineLimit(1)
            }
        }
        .help("Choose the AI provider, model and reasoning effort")
    }
}
