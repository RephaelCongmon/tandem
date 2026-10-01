import SwiftUI
import TandemCore
import TandemUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            if model.settings.role != .studio {
                SharingSettings().tabItem { Label("Sharing", systemImage: "rectangle.on.rectangle.angled") }.tag("sharing")
            }
            if model.settings.role != .source {
                AISettings().tabItem { Label("AI", systemImage: "sparkles") }.tag("ai")
                StudioSettings().tabItem { Label("Studio", systemImage: "rectangle.split.2x1") }.tag("studio")
                SkillSettings().tabItem { Label("Skills", systemImage: "wand.and.stars") }.tag("skills")
                ListeningSettings().tabItem { Label("Listening", systemImage: "waveform") }.tag("listening")
                AutomationSettings().tabItem { Label("Automation", systemImage: "timer") }.tag("automation")
            }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }.tag("shortcuts")
            DeviceSettings().tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }.tag("devices")
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 640)
        .frame(minHeight: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("This Mac") {
                LabeledContent("Mode") {
                    Picker("Mode", selection: Binding(get: { settings.role ?? .studio }, set: { model.switchRole(to: $0) })) {
                        ForEach(AppRole.allCases) { Text("\($0.shortTitle) — \($0.title)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                TextField("Name", text: $settings.deviceName, prompt: Text(DeviceIdentity.systemName))
                    .onSubmit { model.applyDeviceName() }
                    .task(id: settings.deviceName) {
                        // Debounced: re-advertising on every keystroke is wasteful.
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        guard !Task.isCancelled else { return }
                        model.applyDeviceName()
                    }
            }
            Section("Connection") {
                Picker("Preferred link", selection: $settings.linkPreference) {
                    ForEach(LinkPreference.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Use Bluetooth when there's no shared network", isOn: $settings.bluetoothEnabled)
                    .onChange(of: settings.bluetoothEnabled) { _, _ in model.connections.applyBluetoothPreference() }
                Text("Tandem connects over the fastest link available: a Thunderbolt or Ethernet cable, your Wi-Fi network, peer-to-peer Wi-Fi (no network needed), or Bluetooth as a last resort.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Section("App") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.appearance) { _, _ in model.applyAppearance() }
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Open at login")
                    Text("When sharing, Tandem starts quietly in the menu bar and waits for your other Mac.")
                }
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sharing (Source)

private struct SharingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("What's shared") {
                LabeledContent("Source") { SourcePicker().fixedSize() }
                Toggle("Show the pointer", isOn: $settings.showCursor)
                    .onChange(of: settings.showCursor) { _, _ in model.source.captureSettingsChanged() }
                Toggle("Hide Tandem's own windows", isOn: $settings.excludeTandemWindows)
                    .onChange(of: settings.excludeTandemWindows) { _, _ in model.source.captureSettingsChanged() }
                Toggle("Let the Studio choose what's shared", isOn: $settings.allowRemoteSourceSelection)
                    .onChange(of: settings.allowRemoteSourceSelection) { _, _ in model.source.remoteSelectionSettingChanged() }
            }
            Section("Snapshots") {
                Picker("Resolution", selection: $settings.snapshotResolution) {
                    ForEach(SnapshotResolution.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Quality") {
                    Slider(value: $settings.snapshotQuality, in: 0.6...1.0, step: 0.05) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Smaller").font(TandemFont.caption)
                    } maximumValueLabel: {
                        Text("Sharper").font(TandemFont.caption)
                    }
                    .frame(width: 260)
                }
            }
            Section {
                Toggle("Let the other Mac hear this Mac's audio", isOn: $settings.shareAudio)
                    .onChange(of: settings.shareAudio) { _, _ in model.source.audioSettingChanged() }
            } header: {
                Text("Audio")
            } footer: {
                Text("When the other Mac turns on Listen, it transcribes what this Mac plays (a meeting or call) so it can answer questions asked out loud. Tandem's own sounds and your microphone aren't included, and audio stops whenever sharing is paused or this Mac is locked.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Section("Privacy & control") {
                Toggle("Pause sharing while this Mac is locked", isOn: $settings.pauseWhenLocked)
                Toggle("Accept new pairing requests", isOn: $settings.acceptPairingRequests)
                Toggle("Ask before each session, even from paired Macs", isOn: $settings.approveEachSession)
                Toggle("Show the AI's answers on this Mac", isOn: $settings.showRepliesOnSource)
            }
            Section {
                Toggle("Let the other Mac show text on this screen (Glance)", isOn: $settings.allowGlance)
                    .onChange(of: settings.allowGlance) { _, _ in model.source.glance.allowedChanged() }
            } header: {
                Text("Glance")
            } footer: {
                Text("The Studio can put a note or an AI answer in a see-through panel on this screen, and move and scroll it from there. Clicks pass through it, and it never appears in what this Mac shares. \(model.settings.combo(for: .toggleGlance)?.displayString ?? "The menu bar") hides it.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI

private struct AISettings: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var testing = false
    @State private var remoteModels: [AIModelInfo] = []

    var body: some View {
        @Bindable var settings = model.settings
        let capabilities = ModelCatalog.capabilities(for: settings.currentModel, provider: settings.provider)
        Form {
            Section("Provider") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AIProviderKind.menuOrder) { Text($0.menuTitle).tag($0) }
                }
                .onChange(of: settings.provider) { _, provider in
                    keyDraft = model.keys.key(for: settings.provider)
                    keyStatus = nil
                    remoteModels = []
                    if provider == .claudeCode { model.claudeCode.refreshInBackground() }
                    if provider == .codex { model.codex.refreshInBackground() }
                }
                if settings.provider == .codex {
                    CodexStatusRow()
                    HStack {
                        TextField("Location", text: $settings.codexPath, prompt: Text(model.codex.executable?.path ?? "Found automatically"))
                            .onSubmit { model.codex.refreshInBackground() }
                        Button("Check Again") { model.codex.refreshInBackground() }
                            .disabled(model.codex.isChecking)
                        Button(testing ? "Testing…" : "Test") { Task { await test() } }
                            .disabled(testing)
                    }
                    Text("Questions go to OpenAI's models through Codex on this Mac and count toward your ChatGPT plan's usage, with no API key. Tandem starts Codex with no tools (no shell, code, browser, apps or web search) and without your plugins or MCP servers; Codex still reads your ~/.codex/AGENTS.md. Each conversation is a private thread that isn't saved.")
                        .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                } else if settings.provider == .claudeCode {
                    ClaudeCodeStatusRow()
                    HStack {
                        TextField("Location", text: $settings.claudeCodePath, prompt: Text(model.claudeCode.executable?.path ?? "Found automatically"))
                            .onSubmit { model.claudeCode.refreshInBackground() }
                        Button("Check Again") { model.claudeCode.refreshInBackground() }
                            .disabled(model.claudeCode.isChecking)
                        Button(testing ? "Testing…" : "Test") { Task { await test() } }
                            .disabled(testing)
                    }
                    Text("Questions go to Claude through Claude Code on this Mac and count toward your Claude plan's usage, with no API key. Tandem starts it with its tools, plugins, hooks and CLAUDE.md files turned off.")
                        .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    if settings.provider == .openAICompatible {
                        TextField("Server URL", text: $settings.customBaseURL)
                    }
                    HStack {
                        SecureField("API key", text: $keyDraft, prompt: Text(settings.provider == .openAICompatible ? "Optional" : "Paste your key"))
                        Button("Save") { saveKey() }
                            .disabled(keyDraft == model.keys.key(for: settings.provider))
                        Button(testing ? "Testing…" : "Test") { Task { await test() } }
                            .disabled(testing)
                    }
                }
                if let keyStatus {
                    Text(keyStatus).font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Section("Model") {
                if settings.provider == .openAICompatible {
                    TextField("Model ID", text: $settings.customModel)
                } else {
                    Picker("Model", selection: Binding(get: { settings.currentModel }, set: { settings.currentModel = $0 })) {
                        ForEach(ModelCatalog.presets(for: settings.provider)) { preset in
                            Text("\(preset.displayName) — \(preset.summary)").tag(preset.id)
                        }
                        let listed = settings.provider == .codex ? model.codex.models : remoteModels
                        let extra = listed.map(\.id).filter { id in !ModelCatalog.presets(for: settings.provider).contains { $0.id == id } }
                        if !extra.isEmpty {
                            Divider()
                            ForEach(extra, id: \.self) { id in
                                Text(listed.first { $0.id == id }?.displayName ?? id).tag(id)
                            }
                        }
                        if !ModelCatalog.presets(for: settings.provider).contains(where: { $0.id == settings.currentModel }) && !listed.contains(where: { $0.id == settings.currentModel }) {
                            Text(settings.currentModel).tag(settings.currentModel)
                        }
                    }
                }
                if !capabilities.supportedEfforts.isEmpty {
                    Picker("Reasoning effort", selection: $settings.effort) {
                        ForEach(capabilities.supportedEfforts) { Text($0.displayName).tag($0) }
                    }
                    Text("Fast keeps answers quick for screen questions; raise it for hard problems.")
                        .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                }
                Toggle("Show a summary of the model's reasoning", isOn: $settings.showReasoning)
                Picker("Max response length", selection: $settings.maxOutputTokens) {
                    Text("Short (4k tokens)").tag(4_000)
                    Text("Standard (16k tokens)").tag(16_000)
                    Text("Long (32k tokens)").tag(32_000)
                    Text("Very long (64k tokens)").tag(64_000)
                }
                Stepper("Screenshots kept in context: \(settings.maxImagesInContext)", value: $settings.maxImagesInContext, in: 1...12)
            }
            Section("Instructions") {
                TextEditor(text: $settings.systemPrompt)
                    .font(TandemFont.callout)
                    .frame(minHeight: 110)
                HStack {
                    Spacer()
                    Button("Restore Default") { settings.systemPrompt = SettingsStore.defaultSystemPrompt }
                        .disabled(settings.systemPrompt == SettingsStore.defaultSystemPrompt)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            keyDraft = model.keys.key(for: model.settings.provider)
            if model.settings.provider == .claudeCode { model.claudeCode.refreshInBackground() }
            if model.settings.provider == .codex { model.codex.refreshInBackground() }
        }
    }

    private func saveKey() {
        do {
            try model.keys.setKey(keyDraft, for: model.settings.provider)
            keyStatus = keyDraft.isEmpty ? "Key removed." : "Saved to your Keychain."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let settings = model.settings
        if settings.provider == .claudeCode {
            keyStatus = await model.claudeCode.test(model: settings.currentModel)
            return
        }
        if settings.provider == .codex {
            keyStatus = await model.codex.test(model: settings.currentModel)
            return
        }
        saveKey()
        let baseURL = settings.provider == .openAICompatible ? URL(string: settings.customBaseURL) : nil
        let client = AIClientFactory.make(endpoint: AIEndpoint(kind: settings.provider, baseURL: baseURL, apiKey: model.keys.key(for: settings.provider)))
        do {
            let models = try await client.listModels()
            remoteModels = models
            keyStatus = "Connected — \(models.count) models available."
        } catch {
            keyStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Whether Codex is installed and signed in, with the fix when it isn't.
struct CodexStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if model.codex.isChecking && model.codex.status == nil {
                ProgressView().controlSize(.small)
                Text("Looking for Codex…").foregroundStyle(Theme.textSecondary)
            } else if let status = model.codex.status {
                Image(systemName: status.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.isReady ? Theme.success : Theme.warning)
                Text(status.summary)
                    .foregroundStyle(status.isReady ? Theme.textPrimary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .font(TandemFont.callout)
    }
}

/// Whether Claude Code is installed and signed in, with the fix when it isn't.
struct ClaudeCodeStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if model.claudeCode.isChecking && model.claudeCode.status == nil {
                ProgressView().controlSize(.small)
                Text("Looking for Claude Code…").foregroundStyle(Theme.textSecondary)
            } else if let status = model.claudeCode.status {
                Image(systemName: status.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.isReady ? Theme.success : Theme.warning)
                Text(status.summary)
                    .foregroundStyle(status.isReady ? Theme.textPrimary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .font(TandemFont.callout)
    }
}

// MARK: - Studio

private struct StudioSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Live view") {
                Picker("Quality", selection: $settings.liveQuality) {
                    ForEach(LiveQualityPreset.allCases) { preset in
                        Text("\(preset.title) — \(preset.detail)").tag(preset)
                    }
                }
                .onChange(of: settings.liveQuality) { _, _ in model.studio.sendStreamRequest() }
                Text("Tandem adapts the bitrate to your link automatically to keep latency low. Bluetooth links use a small, low-frame-rate preview.")
                    .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
            }
            Section("Asking") {
                Text("Questions and skills use only the pictures selected in the composer. Choose Select region to add a picture, or turn off Use on send to keep it for later.")
                    .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                Picker("When the shared Mac sends a snapshot", selection: $settings.pushBehavior) {
                    ForEach(PushBehavior.allCases) { Text($0.title).tag($0) }
                }
                PromptEditor(title: "Prompt for snapshots without a note", text: $settings.pushPrompt)
                Toggle("Show answers on the shared Mac too", isOn: $settings.mirrorReplies)
            }
            Section("Connection") {
                Toggle("Reconnect to the last Mac automatically", isOn: $settings.autoConnect)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Listening

/// Whether the Parakeet model is on this Mac, with download and remove.
private struct ParakeetModelRow: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemove = false

    var body: some View {
        let transcription = model.studio.transcription
        LabeledContent("Speech model") {
            HStack(spacing: 8) {
                switch transcription.modelState {
                case .installed:
                    Label("Downloaded (\(Self.size))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    Button("Remove…") { confirmRemove = true }
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 120)
                    Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(Theme.textSecondary)
                case .notInstalled:
                    Text("Not downloaded yet (\(Self.size))").foregroundStyle(Theme.textSecondary)
                    Button("Download") { transcription.downloadModel() }
                case .failed(let message):
                    Text(message).foregroundStyle(Theme.warning).lineLimit(2)
                    Button("Try Again") { transcription.downloadModel() }
                }
            }
            .font(TandemFont.callout)
        }
        .confirmationDialog("Remove the speech model?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { transcription.removeModel() }
        } message: {
            Text("Listen will download it again (\(Self.size)) the next time it uses Parakeet.")
        }
    }

    private static var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(ParakeetModelStore.Mirror.size), countStyle: .file)
    }
}

private struct ListeningSettings: View {
    @Environment(AppModel.self) private var model
    @State private var locales: [Locale] = []

    var body: some View {
        @Bindable var settings = model.settings
        let transcription = model.studio.transcription
        Form {
            Section {
                Toggle("Transcribe the shared Mac's audio", isOn: Binding(get: { settings.listen }, set: { model.studio.setListening($0) }))
                Picker("Speech recognition", selection: $settings.speechEngine) {
                    Text("Parakeet — most accurate (English)").tag(SpeechEngine.parakeet)
                    Text("Apple — built in").tag(SpeechEngine.apple)
                }
                .onChange(of: settings.speechEngine) { _, _ in
                    transcription.prepareModelInBackground()
                    transcription.restart()
                }
                if settings.speechEngine == .parakeet {
                    ParakeetModelRow()
                }
                Picker("Language", selection: $settings.transcriptLanguage) {
                    Text("Same as this Mac (\(Self.name(of: Locale.current)))").tag("")
                    if !locales.isEmpty { Divider() }
                    ForEach(locales, id: \.identifier) { locale in
                        Text(Self.name(of: locale)).tag(locale.identifier)
                    }
                }
                .onChange(of: settings.transcriptLanguage) { _, _ in
                    transcription.prepareModelInBackground()
                    transcription.restart()
                }
                if settings.speechEngine == .parakeet, !transcription.usesParakeet {
                    Text("Parakeet understands English only, so Apple's recognizer is used for \(Self.name(of: transcription.locale)).")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Toggle("Show live captions above the skills", isOn: $settings.showCaptions)
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(Theme.textSecondary)
                }
            } header: {
                Text("Live transcript")
            } footer: {
                Text("The shared Mac sends what it plays (a meeting or call, not Tandem's own sounds), and this Mac turns it into text on-device, about a second behind. Nothing leaves this Mac until you ask a question. Parakeet (NVIDIA, CC-BY-4.0) makes about a quarter fewer mistakes than Apple's recognizer on conversation; it's downloaded once, to this Mac only.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Names and terms")
                    TextField("People, companies, products, jargon — separated by commas", text: $settings.transcriptTerms, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                    Text("Sent with the transcript so the AI spells them right when speech-to-text mishears them (\"cooper netties\" → Kubernetes).")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } header: {
                Text("Vocabulary")
            }
            Section {
                Toggle("Send what was said with each question", isOn: $settings.includeTranscript)
                Picker("At most", selection: $settings.transcriptWindowMinutes) {
                    ForEach([2, 5, 10, 20, 30], id: \.self) { Text("The last \($0) minutes").tag($0) }
                }
                .disabled(!settings.includeTranscript)
            } header: {
                Text("Asking")
            } footer: {
                Text("Each question carries what was said since the thread's previous question, up to this limit, so Follow-up can find a question asked out loud. Earlier transcripts stay in the thread, so the AI keeps the whole conversation in mind.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Section {
                Button("Clear Transcript") { transcription.clear() }
                    .disabled(transcription.transcript.isEmpty)
            }
        }
        .formStyle(.grouped)
        .task {
            let supported = await LiveSpeech.supportedLocales()
            locales = supported.sorted { Self.name(of: $0) < Self.name(of: $1) }
        }
    }

    private var statusText: String {
        let transcription = model.studio.transcription
        let engine = transcription.engineName.map { " (\($0))" } ?? ""
        switch transcription.engineState {
        case .off: return model.settings.listen ? "Starting…" : "Off"
        case .preparing: return "Loading the speech model…"
        case .downloading(let fraction): return "Downloading the speech model… \(Int(fraction * 100))%"
        case .ready: return transcription.isReceivingAudio() ? "Listening\(engine)" : "Ready\(engine), waiting for audio"
        case .failed(let message): return message
        }
    }

    private static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// A labeled, left-aligned multi-line text field for prompts inside grouped forms.
private struct PromptEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextEditor(text: $text)
                .font(TandemFont.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 60, maxHeight: 110)
                .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Theme.surfaceSunken.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        }
    }
}

// MARK: - Automation

private struct AutomationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Capture automatically", isOn: $settings.autoCaptureEnabled)
                    .onChange(of: settings.autoCaptureEnabled) { _, _ in model.studio.restartAutomation() }
                LabeledContent("Every") {
                    HStack {
                        Slider(value: Binding(get: { log2(settings.autoCaptureInterval) }, set: { settings.autoCaptureInterval = (pow(2, $0)).rounded() }), in: 1...log2(1800))
                            .frame(width: 240)
                        Text(Formatters.interval(settings.autoCaptureInterval))
                            .font(TandemFont.stat)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                .onChange(of: settings.autoCaptureInterval) { _, _ in model.studio.restartAutomation() }
                Toggle("Only when the screen changes", isOn: $settings.onlyWhenChanged)
                if settings.onlyWhenChanged {
                    Picker("Sensitivity", selection: $settings.changeSensitivity) {
                        ForEach(ChangeSensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Change detection runs on the shared Mac, so unchanged screens aren't even sent.")
                    .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
            }
            Section("What happens with each capture") {
                Picker("Action", selection: $settings.autoAsk) {
                    Text("Ask the AI with the prompt below").tag(true)
                    Text("Just attach it to the composer").tag(false)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.autoAsk) { _, _ in model.studio.sendAutomationStatus() }
                PromptEditor(title: "Prompt", text: $settings.autoPrompt)
                    .disabled(!settings.autoAsk)
                Stepper("At most \(settings.maxAutoAsksPerHour) automatic questions per hour", value: $settings.maxAutoAsksPerHour, in: 1...720, step: settings.maxAutoAsksPerHour < 30 ? 1 : 10)
                    .disabled(!settings.autoAsk)
                Button("Restore Default Prompt") { settings.autoPrompt = SettingsStore.defaultAutoPrompt }
                    .disabled(settings.autoPrompt == SettingsStore.defaultAutoPrompt)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let role = model.settings.role ?? .studio
        Form {
            Section {
                ForEach(HotkeyAction.actions(for: role.hotkeyRole)) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent {
                            HotkeyRecorder(
                                combo: Binding(
                                    get: { model.settings.combo(for: action) },
                                    set: { combo in
                                        model.settings.setCombo(combo, for: action)
                                        model.hotkeys.registerAll()
                                    }
                                ),
                                defaultCombo: action.defaultCombo,
                                validate: { model.hotkeys.validate($0, for: action) }
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title)
                                Text(action.detail).font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        if let error = model.hotkeys.errors[action] {
                            Text(error).font(TandemFont.caption).foregroundStyle(Theme.danger)
                        }
                    }
                }
            } header: {
                Text("Global shortcuts (\(role.shortTitle))")
            } footer: {
                Text("These work from any app, even when Tandem is in the background.")
                    .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Devices

private struct DeviceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmForgetAll = false

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Name", value: model.identity.name)
                LabeledContent("Mode", value: model.settings.role?.shortTitle ?? "Not set")
                if case .ready(let port) = model.connections.listenerState {
                    LabeledContent("Address") {
                        Text(model.connections.localAddresses.map { "\($0):\(port)" }.joined(separator: "\n"))
                            .font(TandemFont.mono)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Bluetooth", value: model.connections.bluetoothState == .ready ? "Available" : model.connections.bluetoothState.localizedDescription)
            }
            Section("Paired Macs") {
                if model.trust.peers.isEmpty {
                    Text("No paired Macs yet.").foregroundStyle(Theme.textSecondary)
                }
                ForEach(model.trust.peers) { peer in
                    HStack(spacing: 10) {
                        DeviceIcon(model: peer.model, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name).font(.system(size: 13, weight: .semibold))
                            Text("Paired \(peer.pairedAt.formatted(date: .abbreviated, time: .omitted))\(peer.lastConnectedAt.map { " · last connected \(Formatters.relative($0))" } ?? "")\(peer.lastLink.map { " · \($0.displayName)" } ?? "")")
                                .font(TandemFont.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Forget") { model.connections.forget(peer.id) }
                    }
                }
                if !model.trust.peers.isEmpty {
                    Button("Forget All Paired Macs…", role: .destructive) { confirmForgetAll = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget all paired Macs?", isPresented: $confirmForgetAll) {
            Button("Forget All", role: .destructive) {
                for peer in model.trust.peers { model.connections.forget(peer.id) }
            }
        } message: {
            Text("You'll need to pair again (with a code) before they can connect.")
        }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Label("Screen sharing between your Macs is end-to-end encrypted (X25519 + ChaCha20-Poly1305) and only works after you confirm a pairing code.", systemImage: "lock.shield")
                Label("Screenshots go only to the AI provider you choose, using your own API key. Nothing is sent anywhere else.", systemImage: "paperplane")
                Label("API keys and pairing keys live in your Keychain.", systemImage: "key")
            }
            .font(TandemFont.callout)
            .foregroundStyle(Theme.textSecondary)
            if settings.role != .source {
                Section("History") {
                    Toggle("Keep screenshots after quitting", isOn: $settings.keepImages)
                        .onChange(of: settings.keepImages) { _, keep in model.chat.setKeepImages(keep) }
                    Text(settings.keepImages ? "Screenshots are stored in Tandem's container so old threads keep their pictures." : "Screenshots stay in memory only and are gone when Tandem quits. Thread text is kept.")
                        .font(TandemFont.caption).foregroundStyle(Theme.textSecondary)
                    Picker("Delete threads older than", selection: $settings.historyRetentionDays) {
                        Text("1 day").tag(1)
                        Text("1 week").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("Never").tag(0)
                    }
                    .onChange(of: settings.historyRetentionDays) { _, _ in model.chat.applyRetentionNow() }
                    Button("Clear All History…", role: .destructive) { confirmClear = true }
                }
            }
            Section("Reset") {
                Button("Reset Tandem…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete every thread and screenshot?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { model.chat.clearAllHistory() }
        }
        .confirmationDialog("Reset Tandem to its first-run state?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                model.connections.deactivate()
                model.chat.clearAllHistory()
                model.trust.forgetAll()
                model.settings.resetAll()
                model.resetOnboarding()
            }
        } message: {
            Text("This unpairs all Macs, deletes history and restores default settings. API keys stay in your Keychain.")
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Tandem").font(TandemFont.display)
            Text("Version \(AppEnvironment.appVersion)").font(TandemFont.callout).foregroundStyle(Theme.textSecondary)
            Text("Two Macs, one conversation. Share one Mac's screen with the other in real time and ask Claude or OpenAI about it.")
                .font(TandemFont.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let profile = AppEnvironment.profile {
                Pill("Profile: \(profile)", systemImage: "person.crop.square", tint: Theme.warning)
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
