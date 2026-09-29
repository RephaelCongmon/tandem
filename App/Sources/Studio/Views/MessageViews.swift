import AppKit
import SwiftUI
import TandemCore
import TandemUI

struct MessageRow: View {
    let message: ChatMessage
    let streaming: StreamingReply?

    var body: some View {
        switch message.role {
        case .user: UserMessageView(message: message)
        case .assistant: AssistantMessageView(message: message, streaming: streaming)
        case .notice: NoticeView(text: message.text)
        }
    }
}

// MARK: - User

private struct UserMessageView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    AttachmentGrid(attachments: message.attachments)
                }
                if let note = message.sourceNote, !note.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "text.bubble").foregroundStyle(Theme.accentSecondary)
                        Text(note)
                            .font(TandemFont.body)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Theme.accentSecondary.opacity(0.12)))
                    .help("Note typed on the shared Mac")
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(TandemFont.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Theme.userBubble))
                }
                HStack(spacing: 6) {
                    if let trigger = message.trigger, trigger != .composer {
                        Pill(triggerLabel(trigger), systemImage: triggerIcon(trigger), tint: Theme.textSecondary)
                    }
                    Text(Formatters.time(message.createdAt))
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .contextMenu {
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            .disabled(message.text.isEmpty)
        }
    }

    private func triggerLabel(_ trigger: SnapshotTrigger) -> String {
        switch trigger {
        case .interval: return "Auto"
        case .hotkey: return "Shortcut"
        case .sourcePush: return "Sent from shared Mac"
        case .manual: return "Capture"
        case .composer: return ""
        }
    }

    private func triggerIcon(_ trigger: SnapshotTrigger) -> String {
        switch trigger {
        case .interval: return "timer"
        case .hotkey: return "keyboard"
        case .sourcePush: return "paperplane"
        case .manual: return "camera.viewfinder"
        case .composer: return "camera"
        }
    }
}

// MARK: - Assistant

private struct AssistantMessageView: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let streaming: StreamingReply?
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(isWorking: streaming != nil)
            VStack(alignment: .leading, spacing: 8) {
                header
                if let streaming {
                    StreamingContent(reply: streaming, showReasoning: model.settings.showReasoning)
                } else {
                    if let reasoning = message.reasoning, !reasoning.isEmpty, model.settings.showReasoning {
                        ReasoningDisclosure(text: reasoning, isStreaming: false)
                    }
                    if !message.text.isEmpty {
                        MarkdownView(message.text)
                    }
                    statusView
                }
                ForEach(message.notices, id: \.self) { notice in
                    Label(notice, systemImage: "info.circle")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                if streaming == nil {
                    footer
                        .opacity(hovering ? 1 : 0.0001)
                }
            }
            Spacer(minLength: 24)
        }
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(modelName)
                .font(.system(size: 12.5, weight: .semibold))
            Text(Formatters.time(message.createdAt))
                .font(TandemFont.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var modelName: String {
        let id = message.model ?? ""
        if let preset = ModelCatalog.presets(for: message.provider ?? .anthropic).first(where: { $0.id == id }) {
            return preset.displayName
        }
        return id.isEmpty ? "Assistant" : id
    }

    @ViewBuilder
    private var statusView: some View {
        switch message.status {
        case .complete, .streaming:
            if message.text.isEmpty {
                Text("No answer was returned.").font(TandemFont.callout).foregroundStyle(Theme.textTertiary)
            }
        case .failed(let error):
            InlineBanner(text: error, systemImage: "exclamationmark.octagon.fill", tint: Theme.danger, actionTitle: "Retry") {
                model.chat.retry(message.id)
            }
        case .cancelled:
            Label("Stopped", systemImage: "stop.circle").font(TandemFont.caption).foregroundStyle(Theme.textTertiary)
        case .refused(let explanation):
            InlineBanner(
                text: explanation.map { "The model declined: \($0)" } ?? "The model declined to answer this request.",
                systemImage: "hand.raised.fill",
                tint: Theme.warning,
                actionTitle: "Retry"
            ) { model.chat.retry(message.id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(message.text.isEmpty)
            Button {
                model.chat.retry(message.id)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .disabled(model.chat.isBusy)
            Spacer(minLength: 8)
            if let first = message.firstTokenSeconds {
                StatChip(systemImage: "bolt", value: String(format: "%.1fs", first), tint: Theme.textTertiary)
                    .help("Time to first word")
            }
            if let total = message.totalSeconds {
                StatChip(systemImage: "clock", value: String(format: "%.1fs", total), tint: Theme.textTertiary)
                    .help("Total time")
            }
            if let usage = message.usage {
                StatChip(systemImage: "number", value: "\(Formatters.tokens(usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens)) in · \(Formatters.tokens(usage.outputTokens)) out", tint: Theme.textTertiary)
                    .help(usage.cacheReadTokens > 0 ? "\(Formatters.tokens(usage.cacheReadTokens)) tokens read from the prompt cache" : "Tokens used")
            }
        }
        .buttonStyle(.plain)
        .font(TandemFont.caption)
        .foregroundStyle(Theme.textSecondary)
        .labelStyle(.titleAndIcon)
    }
}

private struct Avatar: View {
    let isWorking: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.accentGradient)
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .frame(width: 26, height: 26)
        .onAppear { updateSpin() }
        .onChange(of: isWorking) { _, _ in updateSpin() }
        .accessibilityHidden(true)
    }

    private func updateSpin() {
        if isWorking {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { spin = true }
        } else {
            withAnimation(.default) { spin = false }
        }
    }
}

/// Only this view observes the per-token stream.
private struct StreamingContent: View {
    let reply: StreamingReply
    let showReasoning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showReasoning, !reply.reasoning.isEmpty {
                ReasoningDisclosure(text: reply.reasoning, isStreaming: reply.text.isEmpty)
            }
            if reply.text.isEmpty {
                HStack(spacing: 8) {
                    TypingDots()
                    Text(phaseText)
                        .font(TandemFont.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                MarkdownView(reply.text)
            }
        }
    }

    private var phaseText: String {
        switch reply.phase {
        case .capturing: return "Capturing the screen…"
        case .waiting: return "Looking at the screen…"
        case .streaming: return reply.reasoning.isEmpty ? "Thinking…" : "Thinking…"
        }
    }
}

private struct ReasoningDisclosure: View {
    let text: String
    let isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                    Text(isStreaming ? "Thinking…" : "Reasoning")
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.system(size: 9, weight: .bold))
                }
                .font(TandemFont.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(TandemFont.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.strokeStrong).frame(width: 2)
                    }
            }
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin((t * 5) - Double(index) * 0.8)))
                }
            }
        }
        .accessibilityLabel("Working")
    }
}

private struct NoticeView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(TandemFont.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
    }
}

// MARK: - Attachments

struct AttachmentGrid: View {
    @Environment(AppModel.self) private var model
    let attachments: [SnapshotAttachment]
    @State private var viewing: SnapshotAttachment?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentThumbnail(attachment: attachment, height: attachments.count == 1 ? 180 : 110)
                    .onTapGesture { viewing = attachment }
                    .help(attachment.captureTitle ?? "Screenshot")
            }
        }
        .sheet(item: $viewing) { attachment in
            SnapshotViewer(attachment: attachment)
                .environment(model)
        }
    }
}

/// Lazily decoded thumbnail with a graceful "not kept" placeholder.
struct AttachmentThumbnail: View {
    @Environment(AppModel.self) private var model
    let attachment: SnapshotAttachment
    var height: CGFloat = 110
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        let aspect = attachment.pixelHeight > 0 ? CGFloat(attachment.pixelWidth) / CGFloat(attachment.pixelHeight) : 16 / 10
        ZStack {
            Theme.surfaceSunken
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if missing {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Not kept").font(TandemFont.micro)
                }
                .foregroundStyle(Theme.textTertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: min(height * aspect, 420), height: height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            if attachment.isEdited {
                MarkupThumbnailBadge().padding(5)
            }
        }
        .contentShape(Rectangle())
        .task(id: attachment.id) {
            let store = model.chat.snapshots
            let id = attachment.id
            let pixels = Int(height * 2 * max(aspect, 1))
            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let data = store.data(for: id), let thumb = ImageCodec.thumbnail(data, maxPixelSize: pixels) else { return nil }
                return NSImage(cgImage: thumb, size: .zero)
            }.value
            image = loaded
            missing = loaded == nil
        }
    }
}

/// Full-size viewer with zoom, copy and save.
struct SnapshotViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let attachment: SnapshotAttachment
    @State private var image: NSImage?
    @State private var actualSize = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.captureTitle ?? "Screenshot").font(TandemFont.headline)
                    Text("\(attachment.pixelWidth)×\(attachment.pixelHeight) · \(Formatters.bytes(attachment.byteCount)) · \(attachment.sourceName ?? "Shared Mac") · \(attachment.capturedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Toggle("Actual Size", isOn: $actualSize).toggleStyle(.button)
                Button("Copy") {
                    guard let image else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                .disabled(image == nil)
                Button("Save…") { save() }.disabled(image == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.m)
            Hairline()
            ZStack {
                Theme.surfaceSunken
                if let image {
                    if actualSize {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image)
                                .frame(width: CGFloat(attachment.pixelWidth) / (NSScreen.main?.backingScaleFactor ?? 2),
                                       height: CGFloat(attachment.pixelHeight) / (NSScreen.main?.backingScaleFactor ?? 2))
                        }
                    } else {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(Spacing.m)
                    }
                } else {
                    EmptyStateView(systemImage: "photo", title: "Not available", message: "This screenshot wasn't kept. Turn on Settings › Privacy › Keep screenshots to keep them after quitting.")
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 560, idealHeight: 760)
        .task {
            if let data = model.chat.snapshots.data(for: attachment.id) { image = NSImage(data: data) }
        }
    }

    private func save() {
        guard let data = model.chat.snapshots.data(for: attachment.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "Tandem \(attachment.capturedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
