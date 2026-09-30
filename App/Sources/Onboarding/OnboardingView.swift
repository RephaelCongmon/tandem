import SwiftUI
import TandemCore
import TandemUI

/// First-run flow: welcome → choose a role → set up (permissions or AI) → pair.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step = OnboardingView.initialStep
    @State private var role: AppRole = OnboardingView.initialRole

    private static var initialStep: Step {
        #if DEBUG
        return Step(rawValue: UserDefaults.standard.integer(forKey: "TandemOnboardingStep")) ?? .welcome
        #else
        return .welcome
        #endif
    }

    private static var initialRole: AppRole {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "TandemOnboardingRole").flatMap(AppRole.init(rawValue:)) ?? .studio
        #else
        return .studio
        #endif
    }

    enum Step: Int, CaseIterable { case welcome, role, setup, pair }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case .welcome: WelcomeStep { advance() }
                    case .role: RoleStep(role: $role, onBack: back) { advance() }
                    case .setup:
                        if role == .source {
                            SourceSetupStep(onBack: back) { advance() }
                        } else {
                            StudioSetupStep(onBack: back) { advance() }
                        }
                    case .pair: PairStep(role: role, onBack: back) { finish() }
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                .frame(maxWidth: 640)
                .padding(Spacing.xxl)
                .tandemPanel(cornerRadius: Radius.xl)
                .shadow(color: .black.opacity(0.18), radius: 30, y: 12)

                StepDots(current: step.rawValue, count: Step.allCases.count)
                    .padding(.top, Spacing.l)
            }
            .padding(Spacing.xxl)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: step)
    }

    private func advance() {
        if step == .role {
            // Start the role now so permission prompts and discovery happen in context.
            model.connections.activate(role: role)
            if role == .source { model.source.activate() }
        }
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    private func back() {
        if step == .setup { model.connections.deactivate() }
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    private func finish() {
        model.activate(role)
    }
}

private struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .topLeading, startRadius: 20, endRadius: 700)
            RadialGradient(colors: [Theme.accentSecondary.opacity(0.16), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.strokeStrong))
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.3), value: current)
        .accessibilityHidden(true)
    }
}

private struct StepFooter: View {
    var backTitle: String? = "Back"
    let onBack: (() -> Void)?
    let nextTitle: String
    var nextEnabled = true
    let onNext: () -> Void

    var body: some View {
        HStack {
            if let onBack, let backTitle {
                Button(backTitle, action: onBack).buttonStyle(TandemButtonStyle(.ghost, size: .large))
            }
            Spacer()
            Button(nextTitle, action: onNext)
                .buttonStyle(TandemButtonStyle(.primary, size: .large))
                .keyboardShortcut(.defaultAction)
                .disabled(!nextEnabled)
        }
        .padding(.top, Spacing.l)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: Theme.accent.opacity(0.35), radius: 24, y: 8)
            VStack(spacing: 6) {
                Text("Tandem").font(TandemFont.display)
                Text("Two Macs, one conversation.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: Spacing.m) {
                Feature(icon: "bolt.horizontal.fill", title: "Real-time live view", detail: "See your other Mac with near-zero latency over Wi-Fi, a cable, or Bluetooth.")
                Feature(icon: "sparkles", title: "Ask Claude or OpenAI", detail: "Send snapshots with your own context, markup and redactions, on your Claude subscription or an API key.")
                Feature(icon: "timer", title: "On your schedule", detail: "Capture on demand, with a global shortcut, or automatically when the screen changes.")
                Feature(icon: "lock.shield.fill", title: "Private by design", detail: "End-to-end encrypted pairing. Screenshots stay in memory unless you choose to keep them.")
            }
            .padding(.vertical, Spacing.s)
            StepFooter(onBack: nil, nextTitle: "Get Started", onNext: onNext)
        }
    }

    private struct Feature: View {
        let icon: String
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TandemFont.headline)
                    Text(detail).font(TandemFont.callout).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

private struct RoleStep: View {
    @Environment(AppModel.self) private var model
    @Binding var role: AppRole
    let onBack: () -> Void
    let onNext: () -> Void

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What should this Mac do?").font(TandemFont.title)
                Text("Set up Tandem on both Macs — one shares, the other asks. You can switch any time.")
                    .font(TandemFont.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: Spacing.m) {
                ForEach([AppRole.source, AppRole.studio]) { option in
                    RoleCard(role: option, isSelected: role == option) { role = option }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac's name").font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                TextField(DeviceIdentity.systemName, text: $settings.deviceName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.applyDeviceName() }
            }
            StepFooter(onBack: onBack, nextTitle: "Continue") {
                model.applyDeviceName()
                onNext()
            }
        }
    }

    private struct RoleCard: View {
        let role: AppRole
        let isSelected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.accent.opacity(0.12)))
                            Image(systemName: role.systemImage)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.accent))
                        }
                        .frame(width: 44, height: 44)
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    }
                    Text(role.title).font(TandemFont.headline).foregroundStyle(Theme.textPrimary)
                    Text(role.detail)
                        .font(TandemFont.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Spacer(minLength: 0)
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity)
                .frame(height: 172, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Theme.surfaceRaised.opacity(hovering || isSelected ? 1 : 0.6)))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 2 : 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

private struct SourceSetupStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow screen sharing").font(TandemFont.title)
                Text("macOS asks before any app can see your screen. Tandem only captures while a paired Studio is viewing, and you can pause at any time.")
                    .font(TandemFont.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            PermissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                detail: "Required to share a display or window.",
                granted: model.source.hasScreenPermission,
                actionTitle: "Allow…"
            ) {
                model.source.requestPermission()
            }
            PermissionRow(
                icon: "network",
                title: "Local Network",
                detail: "Lets the Studio find this Mac. Approve the prompt when macOS shows it.",
                granted: listenerReady,
                actionTitle: nil,
                action: nil
            )
            PermissionRow(
                icon: "wave.3.right",
                title: "Bluetooth (optional)",
                detail: "A fallback when the Macs aren't on the same network.",
                granted: model.connections.bluetoothState == .ready,
                actionTitle: nil,
                action: nil
            )
            if !model.source.hasScreenPermission {
                Text("After allowing, macOS may ask you to reopen Tandem.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            StepFooter(onBack: onBack, nextTitle: model.source.hasScreenPermission ? "Continue" : "Continue Anyway", onNext: onNext)
        }
        .onAppear { model.source.refreshPermission() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            model.source.refreshPermission()
        }
    }

    private var listenerReady: Bool {
        if case .ready = model.connections.listenerState { return true }
        return false
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Theme.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TandemFont.headline)
                Text(detail).font(TandemFont.callout).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if granted {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(TandemFont.callout.weight(.semibold))
                    .foregroundStyle(Theme.success)
            } else if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(TandemButtonStyle(.secondary))
            } else {
                Text("Pending").font(TandemFont.callout).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Spacing.m)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.surfaceRaised))
    }
}

private struct StudioSetupStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onNext: () -> Void
    @State private var keyDraft = ""
    @State private var error: String?

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your AI").font(TandemFont.title)
                Text(settings.provider == .claudeCode
                     ? "Tandem asks Claude through Claude Code on this Mac, using your Claude subscription. No API key needed."
                     : settings.provider == .codex
                     ? "Tandem asks OpenAI's models through Codex on this Mac, using your ChatGPT subscription. No API key needed."
                     : "Tandem talks to the provider directly with your key. The key is stored in your Keychain.")
                    .font(TandemFont.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Provider", selection: $settings.provider) {
                ForEach(AIProviderKind.menuOrder) { Text($0.menuTitle).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: settings.provider) { _, provider in
                keyDraft = model.keys.key(for: provider)
                error = nil
                if provider == .claudeCode { model.claudeCode.refreshInBackground() }
                if provider == .codex { model.codex.refreshInBackground() }
            }

            if settings.provider == .codex {
                VStack(alignment: .leading, spacing: 8) {
                    CodexStatusRow()
                    if let status = model.codex.status, !status.isReady {
                        Button("Check Again") { model.codex.refreshInBackground() }
                            .buttonStyle(TandemButtonStyle(.secondary, size: .small))
                            .disabled(model.codex.isChecking)
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.surfaceRaised))
            } else if settings.provider == .claudeCode {
                VStack(alignment: .leading, spacing: 8) {
                    ClaudeCodeStatusRow()
                    if let status = model.claudeCode.status, !status.isReady {
                        Button("Check Again") { model.claudeCode.refreshInBackground() }
                            .buttonStyle(TandemButtonStyle(.secondary, size: .small))
                            .disabled(model.claudeCode.isChecking)
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.surfaceRaised))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.provider == .openAICompatible ? "API key (optional)" : "API key")
                        .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                    SecureField(placeholder, text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    if let link = keyLink {
                        Link("Get an API key", destination: link).font(TandemFont.caption)
                    }
                }
            }
            if settings.provider == .openAICompatible {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server URL").font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                    TextField("http://localhost:1234/v1", text: $settings.customBaseURL).textFieldStyle(.roundedBorder)
                    Text("Model").font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                    TextField("model id", text: $settings.customModel).textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model").font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                    Picker("Model", selection: Binding(get: { settings.currentModel }, set: { settings.currentModel = $0 })) {
                        ForEach(ModelCatalog.presets(for: settings.provider)) { preset in
                            Text("\(preset.displayName) — \(preset.summary)").tag(preset.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            if let error {
                InlineBanner(text: error)
            }
            StepFooter(onBack: onBack, nextTitle: "Continue", nextEnabled: canContinue) {
                guard settings.provider.requiresAPIKey || settings.provider == .openAICompatible else { return onNext() }
                do {
                    try model.keys.setKey(keyDraft, for: settings.provider)
                    onNext()
                } catch {
                    self.error = error.localizedDescription
                }
            }
            Text("You can skip this and change it later in Settings › AI.")
                .font(TandemFont.caption)
                .foregroundStyle(Theme.textTertiary)
                .onTapGesture { onNext() }
        }
        .onAppear {
            keyDraft = model.keys.key(for: model.settings.provider)
            Task {
                await model.claudeCode.refresh()
                // Prefer the subscription when Claude Code is ready and no key was set up yet.
                if model.claudeCode.isReady, model.settings.provider.requiresAPIKey, !model.keys.hasKey(for: model.settings.provider) {
                    model.settings.provider = .claudeCode
                }
            }
        }
    }

    private var canContinue: Bool {
        switch model.settings.provider {
        case .claudeCode, .codex, .openAICompatible: return true
        case .anthropic, .openAI: return !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var placeholder: String {
        switch model.settings.provider {
        case .anthropic: return "sk-ant-…"
        case .openAI: return "sk-…"
        case .openAICompatible: return "Leave empty if the server doesn't need one"
        case .claudeCode, .codex: return ""
        }
    }

    private var keyLink: URL? {
        switch model.settings.provider {
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .openAICompatible, .claudeCode, .codex: return nil
        }
    }
}

private struct PairStep: View {
    @Environment(AppModel.self) private var model
    let role: AppRole
    let onBack: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if role == .source {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ready to pair").font(TandemFont.title)
                    Text("On your other Mac, open Tandem, choose **Ask from this Mac**, and select “\(model.identity.name)”. Approve the code here when it appears.")
                        .font(TandemFont.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: Spacing.m) {
                    DeviceIcon(model: model.identity.model, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.identity.name).font(TandemFont.headline)
                        Text(listenerText).font(TandemFont.callout).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if model.trust.peers.isEmpty {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Paired", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.success)
                    }
                }
                .padding(Spacing.m)
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.surfaceRaised))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pair with your other Mac").font(TandemFont.title)
                    Text("Open Tandem on the Mac you want to see and choose **Share this Mac**. It will appear below.")
                        .font(TandemFont.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                NearbyDeviceList(compact: false)
                    .frame(minHeight: 160)
            }
            StepFooter(onBack: onBack, nextTitle: model.trust.peers.isEmpty ? "Finish — Pair Later" : "Finish", onNext: onFinish)
        }
    }

    private var listenerText: String {
        switch model.connections.listenerState {
        case .ready: return "Discoverable nearby — waiting for your Studio…"
        case .waitingForPermission: return "Allow Local Network access to be discoverable."
        case .failed(let message): return message
        default: return "Starting…"
        }
    }
}
