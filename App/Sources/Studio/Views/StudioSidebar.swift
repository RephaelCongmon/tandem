import SwiftUI
import TandemCore
import TandemUI

struct StudioSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: ChatThread?
    @State private var renameText = ""
    @State private var showingAddress = false

    var body: some View {
        @Bindable var chat = model.chat
        List(selection: $chat.selectedThreadID) {
            Section {
                NearbyDeviceList(compact: true)
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            } header: {
                HStack {
                    Text("Shared Mac")
                    Spacer()
                    Button {
                        showingAddress = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Connect by address…")
                }
            }

            Section("Threads") {
                if chat.filteredThreads.isEmpty {
                    Text(chat.searchText.isEmpty ? "No threads yet" : "No matches")
                        .font(TandemFont.callout)
                        .foregroundStyle(Theme.textTertiary)
                        .selectionDisabled()
                }
                ForEach(chat.filteredThreads) { thread in
                    ThreadRow(thread: thread, isStreaming: chat.streaming?.threadID == thread.id)
                        .tag(thread.id)
                        .contextMenu {
                            Button("Rename…") {
                                renameText = thread.title
                                renaming = thread
                            }
                            Button(thread.isPinned ? "Unpin" : "Pin") { chat.togglePin(thread.id) }
                            Button("Export as Markdown…") { chat.export(thread) }
                            Button("Copy Transcript") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(chat.markdownExport(of: thread), forType: .string)
                            }
                            Divider()
                            Button("Delete", role: .destructive) { chat.deleteThread(thread.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $chat.searchText, placement: .sidebar, prompt: "Search threads")
        .safeAreaInset(edge: .bottom) {
            Button {
                chat.newThread()
            } label: {
                Label("New Thread", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TandemButtonStyle(.secondary))
            .padding(Spacing.m)
        }
        .alert("Rename Thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renaming { chat.rename(renaming.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(isPresented: $showingAddress) {
            ConnectByAddressSheet().environment(model)
        }
    }
}

private struct ThreadRow: View {
    let thread: ChatThread
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if thread.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                }
                Text(thread.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isStreaming {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(Formatters.relative(thread.updatedAt))
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text(thread.preview)
                .font(TandemFont.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }
}

/// Nearby and paired Macs with connect/disconnect/pair actions.
struct NearbyDeviceList: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    var body: some View {
        let devices = model.connections.nearby.filter { $0.role != .studio }
        VStack(alignment: .leading, spacing: compact ? 2 : Spacing.s) {
            if devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Looking for Macs…").font(TandemFont.callout.weight(.medium))
                        Text(emptyHint).font(TandemFont.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }
            ForEach(devices) { device in
                DeviceRow(device: device, compact: compact)
            }
            if let failure = model.connections.lastFailure {
                Text(failure.message)
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var emptyHint: String {
        switch model.connections.browserState {
        case .waitingForPermission:
            return "Allow Local Network access for Tandem in System Settings › Privacy & Security."
        case .failed(let message):
            return message
        default:
            return "Open Tandem on the other Mac and choose Share this Mac."
        }
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: NearbyDevice
    let compact: Bool
    @State private var hovering = false

    private var connection: PeerConnection? { model.connections.connection(for: device.id) }
    private var isConnected: Bool { connection?.isConnected ?? false }
    private var isConnecting: Bool { model.connections.isConnecting(to: device.id) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                DeviceIcon(model: device.model, size: compact ? 30 : 36, tint: isConnected ? Theme.success : Theme.accent)
                if isConnected {
                    StatusDot(Theme.success, pulsing: model.studio.hasVideo, size: 8)
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                statusLine
            }
            Spacer(minLength: 4)
            actionButton
        }
        .padding(.vertical, compact ? 4 : 8)
        .padding(.horizontal, compact ? 4 : 10)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(compact ? Color.primary.opacity(hovering ? 0.05 : 0) : Theme.surfaceRaised)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if isConnected {
                Button("Disconnect") { model.connections.disconnect() }
            } else if device.isTrusted {
                Button("Connect") { model.connections.connect(to: device.id) }
            }
            if !device.isTrusted || isConnected {
                Button("Pair Again…") { model.connections.connect(to: device.id, forcePairing: true) }
            }
            if device.isTrusted {
                Divider()
                Button("Forget This Mac", role: .destructive) { model.connections.forget(device.id) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            if let connection, isConnected {
                LinkBadge(link: connection.linkKind)
                if let rtt = connection.stats.rttMillis {
                    StatChip(systemImage: "timer", value: "\(Int(rtt.rounded())) ms")
                }
            } else if isConnecting {
                Text(connection.map(phaseText) ?? "Connecting…").font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
            } else if let reconnect = model.connections.reconnectAt, model.connections.desiredSourceID == device.id {
                Text("Reconnecting \(Formatters.relative(reconnect))").font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
            } else if model.connections.needsRepair(device.id) {
                Text("Pair again to reconnect").font(TandemFont.caption).foregroundStyle(Theme.warning)
            } else if !device.isReachable {
                Text("Offline").font(TandemFont.caption).foregroundStyle(Theme.textTertiary)
            } else if let link = device.primaryLink {
                if device.isTrusted {
                    Text("Available").font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Not paired").font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: link.systemImage).font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
                    .help(link.displayName)
            }
        }
    }

    private func phaseText(_ connection: PeerConnection) -> String {
        switch connection.phase {
        case .connecting: return "Connecting…"
        case .handshaking: return "Securing…"
        case .pairing: return "Confirm the code…"
        case .connected: return "Connected"
        case .closed: return "Disconnected"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isConnecting {
            ProgressView().controlSize(.small)
        } else if isConnected {
            if hovering || !compact {
                Button("Disconnect") { model.connections.disconnect() }
                    .buttonStyle(TandemButtonStyle(.ghost, size: .small))
            }
        } else if device.isReachable {
            let pair = !device.isTrusted || model.connections.needsRepair(device.id)
            Button(pair ? "Pair" : "Connect") {
                model.connections.connect(to: device.id, forcePairing: pair)
            }
            .buttonStyle(TandemButtonStyle(pair ? .primary : .secondary, size: .small))
        }
    }
}

struct ConnectByAddressSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = String(TandemNetwork.preferredPort)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Connect by Address").font(TandemFont.title)
            Text("Use this when the Macs can't discover each other (for example on guest or corporate Wi-Fi). The address is shown in Tandem on the shared Mac under Settings › Devices.")
                .font(TandemFont.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("192.168.1.20", text: $host).textFieldStyle(.roundedBorder)
                TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(width: 80)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(TandemButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button("Connect") {
                    if let value = UInt16(port) { model.connections.connect(host: host.trimmingCharacters(in: .whitespaces), port: value) }
                    dismiss()
                }
                .buttonStyle(TandemButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || UInt16(port) == nil)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 440)
    }
}
