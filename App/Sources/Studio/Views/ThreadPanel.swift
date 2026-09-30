import SwiftUI
import TandemCore
import TandemUI

struct ThreadPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeader()
            Hairline()
            VStack(spacing: Spacing.s) {
                if needsKey {
                    if model.claudeCode.isReady {
                        InlineBanner(
                            text: "Add your \(model.settings.provider.displayName) API key, or ask through Claude Code on your Claude subscription.",
                            systemImage: "key.fill",
                            tint: Theme.accent,
                            actionTitle: "Use Claude Code",
                            action: { model.settings.provider = .claudeCode }
                        )
                    } else {
                        InlineBanner(
                            text: "Add your \(model.settings.provider.displayName) API key to start asking.",
                            systemImage: "key.fill",
                            tint: Theme.accent,
                            actionTitle: "Open Settings",
                            action: { model.openSettingsAction?() }
                        )
                    }
                }
                if let problem = claudeCodeProblem {
                    InlineBanner(
                        text: problem,
                        systemImage: "terminal",
                        tint: Theme.warning,
                        actionTitle: "Check Again",
                        action: { model.claudeCode.refreshInBackground() }
                    )
                }
                if let banner = model.chat.banner {
                    InlineBanner(text: banner, onDismiss: { model.chat.dismissBanner() })
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, model.chat.banner != nil || needsKey || claudeCodeProblem != nil ? Spacing.m : 0)

            if let thread = model.chat.selectedThread, !thread.messages.isEmpty {
                MessageList(thread: thread)
            } else {
                ThreadEmptyState()
            }
            SkillBar()
                .padding(.horizontal, Spacing.m + 2)
                .padding(.top, Spacing.s)
                .padding(.bottom, -Spacing.s)
            ComposerView()
        }
        .background(Theme.surface)
    }

    private var needsKey: Bool {
        model.settings.provider.requiresAPIKey && !model.keys.hasKey(for: model.settings.provider)
    }

    /// Why Claude Code can't answer yet, once a check has run.
    private var claudeCodeProblem: String? {
        guard model.settings.provider == .claudeCode, let status = model.claudeCode.status, !status.isReady else { return nil }
        return status.summary
    }
}

private struct ThreadHeader: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let thread = model.chat.selectedThread
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                if editing, let thread {
                    TextField("Title", text: $draft)
                        .textFieldStyle(.plain)
                        .font(TandemFont.headline)
                        .focused($focused)
                        .onSubmit {
                            model.chat.rename(thread.id, to: draft)
                            editing = false
                        }
                        .onExitCommand { editing = false }
                } else {
                    Text(thread?.title ?? "New Thread")
                        .font(TandemFont.headline)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            guard let thread else { return }
                            draft = thread.title
                            editing = true
                            focused = true
                        }
                }
                Text(subtitle(thread))
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if let thread {
                Menu {
                    Button("Rename…") {
                        draft = thread.title
                        editing = true
                        focused = true
                    }
                    Button(thread.isPinned ? "Unpin" : "Pin") { model.chat.togglePin(thread.id) }
                    Button("Export as Markdown…") { model.chat.export(thread) }
                    Divider()
                    Button("Delete Thread", role: .destructive) { model.chat.deleteThread(thread.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private func subtitle(_ thread: ChatThread?) -> String {
        guard let thread, !thread.messages.isEmpty else { return model.settings.currentModelDisplayName }
        let questions = thread.messages.filter { $0.role == .user }.count
        let shots = thread.attachmentCount
        return "\(questions) question\(questions == 1 ? "" : "s") · \(shots) screenshot\(shots == 1 ? "" : "s") · \(model.settings.currentModelDisplayName)"
    }
}

private struct MessageList: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(thread.messages) { message in
                    MessageRow(message: message, streaming: model.chat.streaming?.messageID == message.id ? model.chat.streaming : nil)
                        .id(message.id)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.l)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .scrollContentBackground(.hidden)
        .id(thread.id)
    }
}

/// Suggestions shown in an empty thread.
private struct ThreadEmptyState: View {
    @Environment(AppModel.self) private var model

    static let suggestions: [(icon: String, text: String)] = [
        ("eye", "What am I looking at?"),
        ("ladybug", "Help me fix the error on screen."),
        ("text.alignleft", "Summarize what's on this page."),
        ("arrow.forward.circle", "What should I do next?"),
        ("doc.text.viewfinder", "Extract all the text on screen."),
        ("paintbrush", "Review this design and suggest improvements.")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                EmptyStateView(
                    systemImage: "sparkles",
                    title: model.studio.isConnected ? "Ask about \(model.studio.sourceName ?? "the other Mac")" : "Start a conversation",
                    message: model.studio.isConnected
                        ? "Each question includes a fresh screenshot of the shared screen. Add your own context, or mark up a capture first."
                        : "Connect your other Mac to include its screen, or just type a question."
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(Self.suggestions, id: \.text) { suggestion in
                        SuggestionCard(icon: suggestion.icon, text: suggestion.text) {
                            model.chat.composerText = suggestion.text
                            model.chat.sendFromComposer()
                        }
                        .disabled(model.chat.isBusy)
                    }
                }
                .frame(maxWidth: 560)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: 360)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private struct SuggestionCard: View {
        let icon: String
        let text: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                    Text(text)
                        .font(TandemFont.callout)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.surfaceRaised.opacity(hovering ? 1 : 0.7)))
                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(hovering ? Theme.accent.opacity(0.4) : Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}
