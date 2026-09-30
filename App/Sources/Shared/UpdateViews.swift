import SwiftUI
import TandemCore
import TandemUI

/// The bar across the top of the window when an update is available or being installed.
struct UpdateBar: View {
    @Environment(AppModel.self) private var model
    @State private var showingNotes = false

    var body: some View {
        let updates = model.updates
        HStack(spacing: 10) {
            if let phase = updates.installPhase {
                ProgressView().controlSize(.small)
                Text("Updating to Tandem \(updates.latest?.version.description ?? "")… \(phase)")
                    .font(TandemFont.callout.weight(.medium))
                Spacer(minLength: 8)
            } else if let error = updates.installError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(error)
                    .font(TandemFont.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Later") { updates.postpone() }
                    .buttonStyle(TandemButtonStyle(.ghost, size: .small))
                Button("Try Again") { Task { await updates.updateNow() } }
                    .buttonStyle(TandemButtonStyle(.primary, size: .small))
            } else if let release = updates.latest {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tandem \(release.version.description) is available")
                        .font(TandemFont.callout.weight(.semibold))
                    Text("You have \(updates.currentVersion.description). Tandem restarts to finish; the other Mac reconnects by itself.")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if !release.notes.isEmpty {
                    Button("What's New") { showingNotes = true }
                        .buttonStyle(TandemButtonStyle(.ghost, size: .small))
                        .popover(isPresented: $showingNotes, arrowEdge: .bottom) { ReleaseNotesView(release: release) }
                }
                Button("Later") { updates.postpone() }
                    .buttonStyle(TandemButtonStyle(.ghost, size: .small))
                Button("Update Now") { Task { await updates.updateNow() } }
                    .buttonStyle(TandemButtonStyle(.primary, size: .small))
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.08))
        .overlay(alignment: .bottom) { Hairline() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ReleaseNotesView: View {
    let release: ReleaseInfo

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(release.title).font(TandemFont.headline)
            if let date = release.publishedAt {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                MarkdownView(release.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .padding(Spacing.l)
        .frame(width: 380)
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
