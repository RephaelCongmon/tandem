import SwiftUI
import TandemCore
import TandemUI

/// Toolbar button shown while an update is available or installing; opens ``UpdatePanel``.
struct UpdateToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        if updates.showsBar {
            Button {
                updates.isPanelPresented = true
            } label: {
                HStack(spacing: 5) {
                    if updates.isUpdating {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: updates.installError != nil ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    }
                    Text(updates.isUpdating ? "Updating…" : (updates.installError != nil ? "Update Failed" : "Update"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(updates.installError != nil ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(Theme.accentGradient)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(updates.latest.map { "Tandem \($0.version.description) is available" } ?? "Updating Tandem")
            .popover(isPresented: $updates.isPanelPresented, arrowEdge: .bottom) {
                UpdatePanel().environment(model)
            }
        }
    }
}

/// What's new in the available release, with Later and Update Now.
struct UpdatePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(updates.latest.map { "Tandem \($0.version.description) is available" } ?? "Updating Tandem")
                        .font(TandemFont.headline)
                    Text("You have \(updates.currentVersion.description)")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let release = updates.latest, !release.notes.isEmpty {
                ScrollView {
                    MarkdownView(release.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            if let phase = updates.installPhase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase).font(TandemFont.callout).foregroundStyle(Theme.textSecondary)
                }
            } else if let error = updates.installError {
                InlineBanner(text: error)
            }
            Text("Tandem restarts to finish. The other Mac reconnects by itself.")
                .font(TandemFont.caption)
                .foregroundStyle(Theme.textTertiary)
            HStack {
                Spacer()
                Button("Later") {
                    updates.postpone()
                    updates.isPanelPresented = false
                }
                .buttonStyle(TandemButtonStyle(.secondary))
                .disabled(updates.isUpdating)
                Button(updates.installError != nil ? "Try Again" : "Update Now") {
                    Task { await updates.updateNow() }
                }
                .buttonStyle(TandemButtonStyle(.primary))
                .disabled(updates.isUpdating || updates.latest == nil)
            }
        }
        .padding(Spacing.l)
        .frame(width: 400)
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var tokenDraft = ""
    @State private var tokenStatus: String?

    var body: some View {
        @Bindable var settings = model.settings
        let updates = model.updates
        Section("Updates") {
            LabeledContent("Version", value: updates.versionDescription)
            Toggle("Check for updates automatically", isOn: $settings.autoCheckUpdates)
                .onChange(of: settings.autoCheckUpdates) { _, enabled in
                    if enabled { updates.startAutomaticChecks() } else { updates.stopAutomaticChecks() }
                }
            HStack(spacing: 8) {
                statusIcon
                Text(statusText)
                    .font(TandemFont.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if updates.latest != nil {
                    Button(updates.isUpdating ? "Updating…" : "Update Now") { Task { await updates.updateNow() } }
                        .disabled(updates.isUpdating)
                }
                Button(updates.isChecking ? "Checking…" : "Check Now") { Task { await updates.check() } }
                    .disabled(updates.isChecking || updates.isUpdating)
            }
            HStack {
                SecureField("GitHub access token", text: $tokenDraft, prompt: Text(updates.hasToken ? "Saved in your Keychain" : "Optional if the GitHub CLI is signed in"))
                Button("Save") { saveToken() }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if updates.hasToken {
                    Button("Remove") {
                        tokenDraft = ""
                        saveToken()
                    }
                }
            }
            Text(accessText)
                .font(TandemFont.caption)
                .foregroundStyle(tokenStatus == nil ? Theme.textSecondary : Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.role == .studio {
                SharedMacUpdateRow()
                Toggle("Keep the shared Mac up to date", isOn: $settings.updateSharedMac)
                Text("When the shared Mac connects with an older Tandem, this Mac sends it this version over the encrypted link. The shared Mac checks it's signed by the same developer, installs it and restarts, so it never needs GitHub access of its own.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if settings.role == .source {
                Toggle("Install updates sent by the other Mac", isOn: $settings.acceptPeerUpdates)
                Text("The Mac you ask from sends newer versions of Tandem here after it updates. They're installed only if signed by the same developer, and Tandem restarts by itself.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let updates = model.updates
        if updates.isChecking {
            ProgressView().controlSize(.small)
        } else if updates.latest != nil {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
        } else if updates.checkError != nil || updates.access == .none {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        } else if updates.lastChecked != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        }
    }

    private var statusText: String {
        let updates = model.updates
        if updates.isChecking { return "Checking for updates…" }
        if let phase = updates.installPhase { return phase }
        if let error = updates.installError { return error }
        if let latest = updates.latest { return "Tandem \(latest.version) is available." }
        if updates.access == .none { return "Tandem needs access to its private GitHub repository to check for updates." }
        if let error = updates.checkError { return error }
        if let checked = updates.lastChecked { return "Up to date · checked \(Formatters.relative(checked))" }
        return "Not checked yet."
    }

    private var accessText: String {
        if let tokenStatus { return tokenStatus }
        let repository = model.updates.repository
        switch model.updates.access {
        case .token:
            return "Using the saved access token to read releases from \(repository)."
        case .githubCLI:
            return "Using your GitHub CLI sign-in to read releases from \(repository)."
        case .none, .unknown:
            return "Releases live in the private repository \(repository). Sign in with the GitHub CLI (`gh auth login`), or paste a fine-grained token that can read that repository's contents."
        }
    }

    private func saveToken() {
        do {
            try model.updates.setToken(tokenDraft)
            tokenStatus = tokenDraft.isEmpty ? "Token removed." : "Token saved to your Keychain."
            tokenDraft = ""
            Task { await model.updates.check() }
        } catch {
            tokenStatus = error.localizedDescription
        }
    }
}

/// The shared Mac's version, and updating it from here.
private struct SharedMacUpdateRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updater = model.studio.sharedMacUpdater
        let connection = model.studio.connection
        LabeledContent("Shared Mac") {
            HStack(spacing: 8) {
                Text(detail).foregroundStyle(Theme.textSecondary).lineLimit(2)
                if case .sending(let fraction) = updater.state {
                    ProgressView(value: fraction).frame(width: 90)
                }
                if updater.canUpdateSource, !updater.isBusy {
                    Button("Update It Now") { updater.updateSource() }
                        .help(connection?.linkKind.isConstrained == true ? "Over Bluetooth this takes several minutes" : "Sends this version to the shared Mac")
                }
            }
            .font(TandemFont.callout)
        }
    }

    private var detail: String {
        let studio = model.studio
        let updater = studio.sharedMacUpdater
        guard let connection = studio.connection, connection.isConnected else { return "Not connected" }
        let name = connection.peer?.name ?? "The shared Mac"
        switch updater.state {
        case .preparing: return "Preparing the update…"
        case .sending(let fraction): return "Sending to \(name)… \(Int(fraction * 100))%"
        case .installing(let phase): return phase
        case .restarting: return "\(name) is restarting…"
        case .failed(let message): return message
        case .idle, .done: break
        }
        guard let version = connection.peerVersion else { return name }
        if !connection.peerAcceptsUpdates, version < updater.currentVersion {
            return "\(name) · Tandem \(version). Update it once there with Update Now; after that this Mac keeps it up to date."
        }
        return version < updater.currentVersion ? "\(name) · Tandem \(version) (this Mac has \(updater.currentVersion))" : "\(name) · Tandem \(version) · up to date"
    }
}
