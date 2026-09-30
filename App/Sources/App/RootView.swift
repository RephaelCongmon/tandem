import SwiftUI
import TandemCore
import TandemUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView()
            } else if model.settings.role == .source {
                SourceView()
            } else {
                StudioView()
            }
        }
        .background(Theme.canvas)
        .background(MainWindowConfigurator(shouldHide: { model.consumeStartsHidden() }))
        .sheet(item: incomingPairing) { request in
            IncomingPairingSheet(request: request)
                .environment(model)
        }
        .sheet(item: outgoingPairing) { item in
            OutgoingPairingSheet(connectionID: item.id)
                .environment(model)
        }
        .sheet(item: sessionApproval) { item in
            SessionApprovalSheet(viewerID: item.id)
                .environment(model)
        }
        .onAppear {
            model.registerSceneActions(openMainWindow: { openWindow(id: "main") }, openSettings: { openSettings() })
        }
    }

    private struct IdentifiedID: Identifiable { let id: UUID }

    private var incomingPairing: Binding<PairingRequest?> {
        Binding(
            get: { model.connections.role == .source ? model.connections.pendingPairing : nil },
            set: { value in if value == nil, model.connections.pendingPairing != nil { model.connections.respondToPairing(accept: false) } }
        )
    }

    private var outgoingPairing: Binding<IdentifiedID?> {
        Binding(
            get: {
                guard model.connections.role == .studio else { return nil }
                let connection = model.connections.connections.first {
                    $0.direction == .outgoing && $0.isPairingAttempt && $0.phase.isLive && !$0.isConnected
                }
                return connection.map { IdentifiedID(id: $0.id) }
            },
            set: { value in if value == nil { model.connections.cancelPairing() } }
        )
    }

    private var sessionApproval: Binding<IdentifiedID?> {
        Binding(
            get: {
                guard model.connections.role == .source, model.connections.pendingPairing == nil else { return nil }
                return model.source.pendingApprovals.first.map { IdentifiedID(id: $0.id) }
            },
            set: { _ in }
        )
    }
}

/// The main window is left out of macOS state restoration, so a login launch in the
/// background has nothing to reopen, and it closes itself when a sharing Mac opened at
/// login (Tandem keeps listening from the menu bar).
private struct MainWindowConfigurator: NSViewRepresentable {
    let shouldHide: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.shouldHide = shouldHide
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfiguringView: NSView {
        var shouldHide: (() -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isRestorable = false
            if shouldHide?() == true {
                DispatchQueue.main.async { window.close() }
            }
        }
    }
}

// MARK: - Pairing sheets

/// Source side: someone wants to pair — compare codes, then allow or decline.
struct IncomingPairingSheet: View {
    @Environment(AppModel.self) private var model
    let request: PairingRequest

    var body: some View {
        VStack(spacing: Spacing.l) {
            DeviceIcon(model: request.peer.model, size: 56)
            VStack(spacing: 6) {
                Text("“\(request.peer.name)” wants to pair")
                    .font(TandemFont.title)
                    .multilineTextAlignment(.center)
                Text("Check that this code matches the one shown on \(request.peer.name).")
                    .font(TandemFont.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            PairingCodeView(code: request.code)
                .padding(.vertical, Spacing.xs)
            Label("Once paired, that Mac can view this Mac's screen while sharing is on. You can pause or unpair at any time.", systemImage: "lock.shield")
                .font(TandemFont.callout)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 380)
            HStack(spacing: Spacing.m) {
                Button("Decline") { model.connections.respondToPairing(accept: false) }
                    .buttonStyle(TandemButtonStyle(.secondary, size: .large))
                    .keyboardShortcut(.cancelAction)
                // Deliberately no Return shortcut: approving must be a conscious click.
                Button("Codes Match — Allow") { model.connections.respondToPairing(accept: true) }
                    .buttonStyle(TandemButtonStyle(.primary, size: .large))
            }
            .padding(.top, Spacing.xs)
        }
        .padding(Spacing.xxl)
        .frame(width: 480)
    }
}

/// Studio side: show the code while waiting for approval on the Source.
struct OutgoingPairingSheet: View {
    @Environment(AppModel.self) private var model
    let connectionID: UUID

    private var connection: PeerConnection? {
        model.connections.connections.first { $0.id == connectionID }
    }

    var body: some View {
        VStack(spacing: Spacing.l) {
            DeviceIcon(model: connection?.peer?.model ?? "Mac", size: 56)
            VStack(spacing: 6) {
                Text("Pair with “\(connection?.peer?.name ?? "the other Mac")”")
                    .font(TandemFont.title)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(TandemFont.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if case .pairing(let code) = connection?.phase {
                PairingCodeView(code: code)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval on \(connection?.peer?.name ?? "the other Mac")…")
                        .font(TandemFont.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if model.connections.localNetworkBlocked {
                LocalNetworkBlockedBanner()
                    .frame(maxWidth: 400)
            } else {
                ProgressView("Connecting securely…")
                    .controlSize(.regular)
                    .padding(.vertical, Spacing.l)
            }
            Button("Cancel") { model.connections.cancelPairing() }
                .buttonStyle(TandemButtonStyle(.secondary, size: .large))
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.xxl)
        .frame(width: 480)
    }

    private var subtitle: String {
        if case .pairing = connection?.phase {
            return "Make sure the same code appears on \(connection?.peer?.name ?? "the other Mac"), then approve it there."
        }
        return "Setting up an encrypted connection."
    }
}

/// Source side, when "Approve each session" is on.
struct SessionApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let viewerID: UUID

    private var viewer: SourceEngine.Viewer? {
        model.source.viewers.first { $0.id == viewerID }
    }

    var body: some View {
        VStack(spacing: Spacing.l) {
            DeviceIcon(model: viewer?.connection.peer?.model ?? "Mac", size: 52)
            Text("“\(viewer?.name ?? "A paired Mac")” wants to view this Mac")
                .font(TandemFont.title)
                .multilineTextAlignment(.center)
            Text("It's already paired. Allow it to see your screen for this session?")
                .font(TandemFont.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: Spacing.m) {
                Button("Don't Allow") { model.source.approve(viewerID, allow: false) }
                    .buttonStyle(TandemButtonStyle(.secondary, size: .large))
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { model.source.approve(viewerID, allow: true) }
                    .buttonStyle(TandemButtonStyle(.primary, size: .large))
            }
        }
        .padding(Spacing.xxl)
        .frame(width: 440)
    }
}
