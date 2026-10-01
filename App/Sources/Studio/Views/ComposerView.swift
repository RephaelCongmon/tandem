import AppKit
import SwiftUI
import TandemCore
import TandemUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var editing: ComposerAttachment?
    @State private var dropTargeted = false

    static let quickPrompts: [(icon: String, title: String, prompt: String)] = [
        ("eye", "Explain the screen", "Explain what's on my screen right now."),
        ("ladybug", "Fix this error", "There's an error on my screen. What's causing it and how do I fix it?"),
        ("text.alignleft", "Summarize", "Summarize what's on my screen in a few bullet points."),
        ("arrow.forward.circle", "What next?", "Based on my screen, what should I do next?"),
        ("doc.text.viewfinder", "Extract text", "Transcribe all the text visible on my screen, preserving structure."),
        ("character.bubble", "Translate", "Translate the text on my screen into English."),
        ("paintbrush", "Design review", "Review the design on my screen and suggest concrete improvements.")
    ]

    var body: some View {
        @Bindable var chat = model.chat
        VStack(alignment: .leading, spacing: 8) {
            if !chat.composerAttachments.isEmpty || model.studio.isConnected {
                attachmentsRow
            }
            HStack(alignment: .bottom, spacing: 8) {
                quickPromptMenu
                TextField(placeholder, text: $chat.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                    .disabled(chat.isCapturingForSend)
                sendButton
            }
            HStack(spacing: 6) {
                Text(hint)
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if model.settings.autoCaptureEnabled, let result = model.studio.lastAutoResult {
                    Label(result, systemImage: "timer")
                        .font(TandemFont.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                ReasoningMenu()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Theme.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(dropTargeted ? Theme.accent : (focused ? Theme.accent.opacity(0.45) : Theme.stroke), lineWidth: dropTargeted ? 2 : 1)
        )
        .padding(Spacing.m)
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .sheet(item: $editing) { attachment in
            MarkupEditorSheet(attachment: attachment)
                .environment(model)
        }
        .onAppear { focused = true }
        .onChange(of: model.chat.editRequest) { _, id in
            guard let id else { return }
            model.chat.beginEditing(id)
            editing = model.chat.composerAttachments.first { $0.id == id }
            model.chat.editRequest = nil
        }
    }

    private var placeholder: String {
        if let name = model.studio.sourceName, model.studio.isConnected {
            return "Ask about \(name)…"
        }
        return "Ask anything…"
    }

    private var hint: String {
        if model.chat.isWaitingForWords { return "Catching the last words…" }
        if model.chat.isCapturingForSend { return "Capturing the screen…" }
        if !model.chat.applyingMarkup.isEmpty { return "Applying your edits…" }
        if model.chat.streaming != nil { return "Answering… press ⌘. to stop" }
        return "↩ to send · ⌥↩ for a new line"
    }

    private var canSend: Bool {
        model.chat.canSendFromComposer
    }

    private func send() {
        guard canSend else { return }
        model.chat.sendFromComposer()
    }

    // MARK: Pieces

    private var attachmentsRow: some View {
        @Bindable var chat = model.chat
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !chat.composerAttachments.isEmpty {
                    SelectedPicturesChip(isOn: $chat.useSelectedPictures, count: chat.composerAttachments.count)
                }
                if model.studio.isConnected { ListenToggleChip() }
                ForEach(chat.composerAttachments) { item in
                    ComposerThumbnail(item: item) {
                        chat.beginEditing(item.id)
                        editing = item
                    } onRemove: {
                        chat.removeFromComposer(item.id)
                    }
                }
                if model.studio.isConnected {
                    let on = model.studio.isRegionToolOn
                    Button {
                        model.studio.toggleRegionTool()
                    } label: {
                        Label("Select region", systemImage: model.studio.regionCropsInFlight > 0 ? "hourglass" : "rectangle.dashed")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(on ? Theme.accent.opacity(0.12) : .clear))
                            .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(on ? Theme.accent : Theme.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: on ? [] : [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .disabled(!on && !model.studio.canCapture)
                    .help(on ? "Drag on the live view to add pictures. Click again or press esc to stop (⇧⌘S)" : "Drag on the live view to add pictures of the shared screen (⇧⌘S)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var quickPromptMenu: some View {
        Menu {
            ForEach(Self.quickPrompts, id: \.title) { item in
                Button {
                    model.chat.composerText = item.prompt
                    send()
                } label: {
                    Label(item.title, systemImage: item.icon)
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 28, height: 30)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.chat.isBusy)
        .help("Quick prompts")
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.chat.streaming != nil {
            Button {
                model.chat.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.textSecondary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop (⌘.)")
        } else if model.chat.isCapturingForSend {
            ProgressView().controlSize(.small).frame(width: 30, height: 30)
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(canSend ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.strokeStrong)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (↩)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    onMain { addDropped(cgImage, title: "Dropped image") }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url), let image = ImageCodec.decode(data) else { return }
                    let name = url.lastPathComponent
                    onMain { addDropped(image, title: name) }
                }
            }
        }
        return handled
    }

    private func addDropped(_ image: CGImage, title: String) {
        guard let encoded = ImageCodec.jpeg(image, quality: 0.9, maxDimension: 2576) else { return }
        let header = SnapshotHeader(
            id: UUID(), trigger: .manual, note: nil, pixelWidth: encoded.width, pixelHeight: encoded.height,
            byteCount: encoded.data.count, chunkCount: 1, mimeType: "image/jpeg", capturedAt: Date(), captureTitle: title
        )
        model.chat.addToComposer(ReceivedSnapshot(header: header, data: encoded.data, transferSeconds: 0), sourceName: "This Mac")
    }
}

private struct SelectedPicturesChip: View {
    @Binding var isOn: Bool
    let count: Int

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(count) picture\(count == 1 ? "" : "s")").font(.system(size: 11.5, weight: .semibold))
                    Text(isOn ? "Use on send" : "Excluded from send").font(TandemFont.micro).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(isOn ? Theme.accent.opacity(0.1) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(isOn ? Theme.accent.opacity(0.35) : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Send these selected pictures with your next question or skill" : "These pictures stay here for later; the next question sends without them")
    }
}

private struct ComposerThumbnail: View {
    let item: ComposerAttachment
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 0.5))
                .overlay(alignment: .bottomLeading) {
                    if item.attachment.isEdited {
                        Image(systemName: "pencil.tip.crop.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white, Theme.accent)
                            .padding(2)
                    } else if item.isAutomatic {
                        Image(systemName: "timer")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Theme.accentSecondary))
                            .padding(2)
                    }
                }
                .onTapGesture(perform: onEdit)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Remove")
            }
        }
        .onHover { hovering = $0 }
        .help("Click to annotate, crop or redact")
    }
}

/// Presents the markup editor for one composer attachment.
private struct MarkupEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let attachment: ComposerAttachment
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                SnapshotEditorView(image: image, document: initialDocument) {
                    dismiss()
                } onDone: { document, rendered in
                    apply(document: document, rendered: rendered)
                    dismiss()
                }
            } else {
                ProgressView().frame(width: 300, height: 200)
            }
        }
        .frame(minWidth: 960, idealWidth: 1200, minHeight: 640, idealHeight: 820)
        .task {
            let data = attachment.originalData
            image = await Task.detached(priority: .userInitiated) { ImageCodec.decode(data) }.value
        }
    }

    private var initialDocument: MarkupDocument {
        guard let data = attachment.markup?.data, let document = try? JSONDecoder().decode(MarkupDocument.self, from: data) else {
            return MarkupDocument()
        }
        return document
    }

    private func apply(document: MarkupDocument, rendered: CGImage) {
        let id = attachment.id
        let chat = model.chat
        if document.isEmpty {
            chat.applyMarkup(to: id, rendered: attachment.originalData, width: rendered.width, height: rendered.height, markup: nil)
            return
        }
        let box = (try? JSONEncoder().encode(document)).map(MarkupDocumentBox.init)
        chat.beginApplyingMarkup(id)
        Task {
            let encoded = await Task.detached(priority: .userInitiated) { ImageCodec.jpeg(rendered, quality: 0.92) }.value
            guard let encoded else {
                // Encoding failed: drop the attachment rather than risk sending the original.
                chat.applyMarkup(to: id, rendered: Data(), width: 0, height: 0, markup: nil)
                chat.removeFromComposer(id)
                return
            }
            chat.applyMarkup(to: id, rendered: encoded.data, width: encoded.width, height: encoded.height, markup: box)
        }
    }
}

/// The reasoning level for the next answers, under the message field. Only levels the current
/// model supports are offered; models without reasoning show nothing.
private struct ReasoningMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        let capabilities = ModelCatalog.capabilities(for: settings.currentModel, provider: settings.provider)
        if let current = capabilities.resolvedEffort(settings.effort) {
            Menu {
                Picker("Reasoning", selection: Binding(get: { current }, set: { settings.effort = $0 })) {
                    ForEach(capabilities.supportedEfforts) { effort in
                        Text("\(effort.displayName) — \(effort.detail)").tag(effort)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                    Text("Reasoning: \(current.displayName)")
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(TandemFont.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How much the model thinks before answering. Applies from your next question.")
        }
    }
}

private extension ReasoningEffort {
    var detail: String {
        switch self {
        case .low: return "quickest answers"
        case .medium: return "a little more thought"
        case .high: return "for tricky problems"
        case .xhigh: return "for hard problems; slower"
        case .max: return "slowest; uses the most tokens"
        }
    }
}
