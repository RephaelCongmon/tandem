import AppKit
import Observation
import os
import TandemCore
import UniformTypeIdentifiers

/// An image waiting in the composer.
struct ComposerAttachment: Identifiable, Equatable {
    var id: UUID { attachment.id }
    var attachment: SnapshotAttachment
    /// The unedited capture, kept so markup can be re-done from scratch.
    var originalData: Data
    var markup: MarkupDocumentBox?
    var thumbnail: NSImage
    /// Added by auto-capture (replaced by the next one rather than piling up).
    var isAutomatic: Bool

    static func == (lhs: ComposerAttachment, rhs: ComposerAttachment) -> Bool {
        lhs.attachment == rhs.attachment && lhs.isAutomatic == rhs.isAutomatic && lhs.markup == rhs.markup
    }
}

/// Type-erased markup so this file doesn't need TandemUI types in its API.
struct MarkupDocumentBox: Equatable {
    var data: Data
}

/// Live state of the reply being streamed. Only the streaming message view
/// observes it, so per-token updates don't re-render the whole thread.
@MainActor
@Observable
final class StreamingReply {
    enum Phase: Equatable { case capturing, waiting, streaming }

    let threadID: UUID
    let messageID: UUID
    var phase: Phase
    var text = ""
    var reasoning = ""
    var model: String?
    var notices: [String] = []
    let startedAt = Date()
    var firstTokenAt: Date?

    init(threadID: UUID, messageID: UUID, phase: Phase) {
        self.threadID = threadID
        self.messageID = messageID
        self.phase = phase
    }
}

@MainActor
@Observable
final class ChatController {
    private(set) var threads: [ChatThread] = []
    var selectedThreadID: UUID?
    var composerText = ""
    private(set) var composerAttachments: [ComposerAttachment] = []
    var attachLiveSnapshot: Bool
    private(set) var streaming: StreamingReply?
    private(set) var isCapturingForSend = false
    private(set) var banner: String?
    var searchText = ""

    @ObservationIgnored let snapshots: SnapshotStore
    @ObservationIgnored private let store: ThreadStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let keys: APIKeyStore
    @ObservationIgnored weak var studio: StudioEngine?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var pendingReasoning = ""
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var lastMirror = 0.0
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Chat")

    init(settings: SettingsStore, keys: APIKeyStore) {
        self.settings = settings
        self.keys = keys
        attachLiveSnapshot = settings.attachLiveSnapshot
        store = ThreadStore(directory: AppEnvironment.threadsDirectory)
        snapshots = SnapshotStore(directory: AppEnvironment.snapshotsDirectory, keepOnDisk: settings.keepImages)
        threads = store.loadAll()
        applyRetention()
        selectedThreadID = threads.first?.id
    }

    // MARK: Threads

    var selectedThread: ChatThread? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    var filteredThreads: [ChatThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = threads.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
        guard !query.isEmpty else { return base }
        return base.filter { thread in
            thread.title.localizedCaseInsensitiveContains(query)
                || thread.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var isBusy: Bool { streaming != nil || isCapturingForSend }

    @discardableResult
    func newThread() -> UUID {
        if let current = selectedThread, current.messages.isEmpty { return current.id }
        let thread = ChatThread()
        threads.insert(thread, at: 0)
        selectedThreadID = thread.id
        store.save(thread)
        return thread.id
    }

    func deleteThread(_ id: UUID) {
        if streaming?.threadID == id { stop() }
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        let ids = threads[index].messages.flatMap(\.attachments).map(\.id)
        snapshots.remove(ids)
        threads.remove(at: index)
        store.delete(id)
        if selectedThreadID == id { selectedThreadID = filteredThreads.first?.id }
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id) {
            $0.title = trimmed
            $0.hasCustomTitle = true
        }
    }

    func togglePin(_ id: UUID) {
        mutate(id) { $0.isPinned.toggle() }
    }

    func clearAllHistory() {
        stop()
        threads.removeAll()
        store.deleteAll()
        snapshots.removeAll()
        composerAttachments.removeAll()
        selectedThreadID = nil
    }

    func setKeepImages(_ keep: Bool) {
        snapshots.setKeepOnDisk(keep)
    }

    func flush() { store.flush() }

    private func mutate(_ id: UUID, _ body: (inout ChatThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        body(&threads[index])
        threads[index].updatedAt = Date()
        store.save(threads[index])
    }

    private func applyRetention() {
        let days = settings.historyRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for thread in threads where !thread.isPinned && thread.updatedAt < cutoff {
            snapshots.remove(thread.messages.flatMap(\.attachments).map(\.id))
            store.delete(thread.id)
        }
        threads.removeAll { !$0.isPinned && $0.updatedAt < cutoff }
    }

    // MARK: Composer attachments

    /// Adds a received snapshot to the composer.
    func addToComposer(_ snapshot: ReceivedSnapshot, sourceName: String?, automatic: Bool = false) {
        let attachment = makeAttachment(from: snapshot, sourceName: sourceName)
        snapshots.put(snapshot.data, id: attachment.id)
        if automatic { composerAttachments.removeAll(where: \.isAutomatic) }
        let thumb = ImageCodec.thumbnail(snapshot.data, maxPixelSize: 360).map { NSImage(cgImage: $0, size: .zero) } ?? NSImage()
        composerAttachments.append(ComposerAttachment(attachment: attachment, originalData: snapshot.data, markup: nil, thumbnail: thumb, isAutomatic: automatic))
        if composerAttachments.count > 8 { composerAttachments.removeFirst(composerAttachments.count - 8) }
    }

    func removeFromComposer(_ id: UUID) {
        composerAttachments.removeAll { $0.id == id }
    }

    /// Replaces an attachment's image with an edited version.
    func applyMarkup(to id: UUID, rendered: Data, width: Int, height: Int, markup: MarkupDocumentBox?) {
        guard let index = composerAttachments.firstIndex(where: { $0.id == id }) else { return }
        snapshots.put(rendered, id: id)
        composerAttachments[index].attachment.pixelWidth = width
        composerAttachments[index].attachment.pixelHeight = height
        composerAttachments[index].attachment.byteCount = rendered.count
        composerAttachments[index].attachment.isEdited = markup != nil
        composerAttachments[index].markup = markup
        composerAttachments[index].isAutomatic = false
        if let thumb = ImageCodec.thumbnail(rendered, maxPixelSize: 360) {
            composerAttachments[index].thumbnail = NSImage(cgImage: thumb, size: .zero)
        }
    }

    func makeAttachment(from snapshot: ReceivedSnapshot, sourceName: String?) -> SnapshotAttachment {
        SnapshotAttachment(
            id: snapshot.header.id,
            pixelWidth: snapshot.header.pixelWidth,
            pixelHeight: snapshot.header.pixelHeight,
            byteCount: snapshot.data.count,
            mimeType: snapshot.header.mimeType,
            capturedAt: snapshot.header.capturedAt,
            captureTitle: snapshot.header.captureTitle,
            sourceName: sourceName,
            trigger: snapshot.header.trigger
        )
    }

    // MARK: Sending

    /// Sends the composer's text and attachments (plus a fresh live snapshot if enabled).
    func sendFromComposer() {
        guard !isBusy else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsLive = attachLiveSnapshot && (studio?.canCapture ?? false)
        guard !text.isEmpty || !composerAttachments.isEmpty || wantsLive else { return }
        let attachments = composerAttachments.map(\.attachment)
        composerText = ""
        composerAttachments.removeAll()
        banner = nil

        guard wantsLive, let studio else {
            submit(text: text, attachments: attachments, trigger: nil, sourceNote: nil)
            return
        }
        isCapturingForSend = true
        Task {
            defer { isCapturingForSend = false }
            do {
                let snapshot = try await studio.requestSnapshot(trigger: .composer)
                let attachment = makeAttachment(from: snapshot, sourceName: studio.sourceName)
                snapshots.put(snapshot.data, id: attachment.id)
                submit(text: text, attachments: attachments + [attachment], trigger: .composer, sourceNote: nil)
            } catch {
                banner = "Sent without a new screenshot: \(error.localizedDescription)"
                submit(text: text, attachments: attachments, trigger: nil, sourceNote: nil)
            }
        }
    }

    /// Asks about a snapshot without using the composer (hotkeys, pushes, automation).
    func ask(prompt: String, snapshot: ReceivedSnapshot?, sourceName: String?, trigger: SnapshotTrigger, sourceNote: String? = nil) {
        guard streaming == nil else {
            // Keep the snapshot for the user instead of dropping it.
            if let snapshot { addToComposer(snapshot, sourceName: sourceName) }
            banner = "Still answering the previous question — the new screenshot was added to the composer."
            return
        }
        var attachments: [SnapshotAttachment] = []
        if let snapshot {
            let attachment = makeAttachment(from: snapshot, sourceName: sourceName)
            snapshots.put(snapshot.data, id: attachment.id)
            attachments.append(attachment)
        }
        submit(text: prompt, attachments: attachments, trigger: trigger, sourceNote: sourceNote)
    }

    private func submit(text: String, attachments: [SnapshotAttachment], trigger: SnapshotTrigger?, sourceNote: String?) {
        let threadID = selectedThread.map(\.id) ?? newThread()
        let message = ChatMessage(role: .user, text: text, attachments: attachments, trigger: trigger, sourceNote: sourceNote)
        mutate(threadID) { thread in
            thread.messages.append(message)
            if !thread.hasCustomTitle, thread.messages.filter({ $0.role == .user }).count == 1 {
                let seed = text.isEmpty ? (sourceNote ?? "") : text
                thread.title = ChatThread.autoTitle(for: seed, fallbackDate: message.createdAt)
            }
        }
        selectedThreadID = threadID
        startReply(in: threadID)
    }

    /// Regenerates the assistant reply `messageID` (and drops anything after it).
    func retry(_ messageID: UUID) {
        guard streaming == nil, let threadID = selectedThreadID,
              let thread = threads.first(where: { $0.id == threadID }),
              let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
        mutate(threadID) { $0.messages.removeSubrange(index...) }
        startReply(in: threadID)
    }

    func deleteMessage(_ messageID: UUID) {
        guard let threadID = selectedThreadID, streaming?.messageID != messageID else { return }
        mutate(threadID) { thread in
            if let message = thread.messages.first(where: { $0.id == messageID }) {
                snapshots.remove(message.attachments.map(\.id))
            }
            thread.messages.removeAll { $0.id == messageID }
        }
    }

    func stop() {
        streamTask?.cancel()
    }

    // MARK: Streaming

    private func makeClient() throws -> (any AIClient, AIProviderKind, String) {
        let provider = settings.provider
        let model = settings.currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIError.invalidConfiguration("Choose a model in Settings › AI.") }
        let key = keys.key(for: provider)
        if provider.requiresAPIKey, key.isEmpty { throw AIError.missingAPIKey }
        var baseURL: URL? = provider == .openAICompatible ? URL(string: settings.customBaseURL) : nil
        if let debug = AppEnvironment.debugAIBaseURL { baseURL = debug }
        if provider == .openAICompatible, baseURL == nil {
            throw AIError.invalidConfiguration("The custom server URL isn't valid.")
        }
        let endpoint = AIEndpoint(kind: provider, baseURL: baseURL, apiKey: key)
        return (AIClientFactory.make(endpoint: endpoint), provider, model)
    }

    private func startReply(in threadID: UUID) {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return }
        let history = thread.messages
        let assistant = ChatMessage(role: .assistant, text: "", status: .streaming, provider: settings.provider, model: settings.currentModel)
        mutate(threadID) { $0.messages.append(assistant) }
        let reply = StreamingReply(threadID: threadID, messageID: assistant.id, phase: .waiting)
        streaming = reply

        let client: any AIClient
        let provider: AIProviderKind
        let model: String
        do {
            (client, provider, model) = try makeClient()
        } catch {
            finish(reply, status: .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription), usage: nil, servedModel: nil)
            return
        }

        let capabilities = ModelCatalog.capabilities(for: model, provider: provider)
        let policy = ContextPolicy(maxImages: settings.maxImagesInContext)
        let snapshots = self.snapshots
        let request = AIRequest(
            model: model,
            systemPrompt: settings.systemPrompt,
            turns: [],
            maxOutputTokens: settings.maxOutputTokens,
            effort: settings.effort,
            includeReasoningSummary: settings.showReasoning
        )

        streamTask = Task { [weak self] in
            // Building turns may re-encode images; keep it off the main thread.
            let turns = await Task.detached(priority: .userInitiated) {
                ContextBuilder.turns(for: history, policy: policy) { attachment in
                    snapshots.aiImage(for: attachment.id, maxDimension: capabilities.maxImageLongEdge)
                }
            }.value
            var fullRequest = request
            fullRequest.turns = turns
            guard let self else { return }
            guard !turns.isEmpty else {
                self.finish(reply, status: .failed("There's nothing to send yet."), usage: nil, servedModel: nil)
                return
            }
            var completion: AICompletion?
            do {
                for try await event in client.stream(fullRequest) {
                    switch event {
                    case .started(let served):
                        reply.model = served
                    case .textDelta(let delta):
                        if reply.firstTokenAt == nil { reply.firstTokenAt = Date() }
                        self.pendingText += delta
                        self.scheduleFlush(reply)
                    case .reasoningDelta(let delta):
                        self.pendingReasoning += delta
                        self.scheduleFlush(reply)
                    case .notice(let notice):
                        reply.notices.append(notice)
                    case .completed(let done):
                        completion = done
                    }
                }
                self.flushPending(reply)
                switch completion?.stopReason {
                case .refusal(_, let explanation):
                    self.finish(reply, status: .refused(explanation), usage: completion?.usage, servedModel: completion?.servedModel)
                case .maxTokens:
                    reply.notices.append("The answer hit the length limit (Settings › AI › Max response length).")
                    self.finish(reply, status: .complete, usage: completion?.usage, servedModel: completion?.servedModel)
                default:
                    self.finish(reply, status: .complete, usage: completion?.usage, servedModel: completion?.servedModel)
                }
            } catch {
                self.flushPending(reply)
                if Task.isCancelled || (error as? AIError) == .cancelled || error is CancellationError {
                    self.finish(reply, status: .cancelled, usage: nil, servedModel: nil)
                } else {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.finish(reply, status: .failed(message), usage: nil, servedModel: nil)
                }
            }
        }
    }

    private func scheduleFlush(_ reply: StreamingReply) {
        if reply.phase != .streaming { reply.phase = .streaming }
        guard !flushScheduled else { return }
        flushScheduled = true
        // ~30 updates/s is smooth without re-rendering Markdown on every token.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScheduled = false
                self?.flushPending(reply)
            }
        }
    }

    private func flushPending(_ reply: StreamingReply) {
        if !pendingText.isEmpty {
            reply.text += pendingText
            pendingText = ""
        }
        if !pendingReasoning.isEmpty {
            reply.reasoning += pendingReasoning
            pendingReasoning = ""
        }
        mirrorIfNeeded(reply, isFinal: false)
    }

    private func finish(_ reply: StreamingReply, status: ChatMessage.Status, usage: AIUsage?, servedModel: String?) {
        let now = Date()
        mutate(reply.threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == reply.messageID }) else { return }
            thread.messages[index].text = reply.text
            thread.messages[index].reasoning = reply.reasoning.isEmpty ? nil : reply.reasoning
            thread.messages[index].status = status
            thread.messages[index].usage = usage
            thread.messages[index].model = servedModel ?? reply.model ?? thread.messages[index].model
            thread.messages[index].notices = reply.notices
            thread.messages[index].firstTokenSeconds = reply.firstTokenAt.map { $0.timeIntervalSince(reply.startedAt) }
            thread.messages[index].totalSeconds = now.timeIntervalSince(reply.startedAt)
        }
        mirrorIfNeeded(reply, isFinal: true)
        if streaming === reply { streaming = nil }
        streamTask = nil
        pendingText = ""
        pendingReasoning = ""
        if case .failed(let message) = status {
            log.error("Reply failed: \(message, privacy: .public)")
        }
    }

    private func mirrorIfNeeded(_ reply: StreamingReply, isFinal: Bool) {
        guard settings.mirrorReplies, let studio else { return }
        let now = monotonicSeconds()
        guard isFinal || now - lastMirror > 0.75 else { return }
        lastMirror = now
        let prompt = threads.first { $0.id == reply.threadID }?.messages.last { $0.role == .user }?.text
        studio.mirror(ReplyMirror(
            threadID: reply.threadID, messageID: reply.messageID, prompt: prompt,
            text: reply.text, isFinal: isFinal, model: reply.model
        ))
    }

    // MARK: Export

    func markdownExport(of thread: ChatThread) -> String {
        var lines = ["# \(thread.title)", ""]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for message in thread.messages where message.role != .notice {
            let who = message.role == .user ? "You" : (message.model ?? "Assistant")
            lines.append("## \(who) · \(formatter.string(from: message.createdAt))")
            if !message.attachments.isEmpty {
                lines.append("_\(message.attachments.count) screenshot\(message.attachments.count == 1 ? "" : "s")_")
            }
            if let note = message.sourceNote { lines.append("> \(note)") }
            lines.append(message.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func export(_ thread: ChatThread) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(thread.title).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdownExport(of: thread).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            banner = "Couldn't export: \(error.localizedDescription)"
        }
    }

    func dismissBanner() { banner = nil }

    func reportBanner(_ text: String) { banner = text }
}
