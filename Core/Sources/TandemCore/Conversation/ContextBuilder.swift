import Foundation

/// How much of a thread is sent to the model.
public struct ContextPolicy: Sendable, Hashable {
    /// Most screenshots to include (newest first). Older ones become text placeholders.
    public var maxImages: Int
    /// Images drop out of the window in steps of this size, so the cached prompt
    /// prefix changes only every few turns instead of on every new screenshot.
    public var imageWindowStep: Int
    /// Most messages to include.
    public var maxMessages: Int
    public var messageWindowStep: Int

    public init(maxImages: Int = 4, imageWindowStep: Int = 2, maxMessages: Int = 80, messageWindowStep: Int = 10) {
        self.maxImages = max(1, maxImages)
        self.imageWindowStep = max(1, imageWindowStep)
        self.maxMessages = max(2, maxMessages)
        self.messageWindowStep = max(1, messageWindowStep)
    }

    /// Index of the first item to keep out of `count`, keeping between
    /// `limit - step + 1` and `limit` items, moving only in multiples of `step`.
    static func steppedStart(count: Int, limit: Int, step: Int) -> Int {
        guard count > limit else { return 0 }
        let overflow = count - limit
        let effectiveStep = min(step, limit)
        return ((overflow + effectiveStep - 1) / effectiveStep) * effectiveStep
    }
}

/// Converts a thread into provider-neutral turns.
public enum ContextBuilder {
    public static let omittedImageText = "[An earlier screenshot was here; it's omitted to keep the conversation short.]"
    public static let missingImageText = "[An earlier screenshot was here but is no longer available.]"

    /// - Parameters:
    ///   - messages: the thread, oldest first; the last user message is the new prompt.
    ///   - imageProvider: returns the encoded image for an attachment id, sized for
    ///     the target model, or `nil` if it's gone.
    public static func turns(
        for messages: [ChatMessage],
        policy: ContextPolicy = ContextPolicy(),
        timeZone: TimeZone = .current,
        imageProvider: (SnapshotAttachment) -> AIImage?
    ) -> [AITurn] {
        let windowed = window(messages, policy: policy)
        return build(windowed, policy: policy, timeZone: timeZone, imageProvider: imageProvider)
    }

    /// The messages `turns(for:policy:…)` draws on, oldest first.
    public static func includedMessageIDs(for messages: [ChatMessage], policy: ContextPolicy = ContextPolicy()) -> [UUID] {
        var windowed = window(messages, policy: policy)
        // Mirrors the trailing-assistant trim in `build`.
        while let last = windowed.last, last.role != .user { windowed.removeLast() }
        return windowed.map(\.id)
    }

    /// Steps 1–2: eligible messages inside the (stepped) message window, starting with a user message.
    private static func window(_ messages: [ChatMessage], policy: ContextPolicy) -> [ChatMessage] {
        // 1. Eligible messages: user messages and assistant messages with content.
        let eligible = messages.filter { message in
            switch message.role {
            case .user:
                return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty
                    || message.skill != nil || !(message.transcript?.isEmpty ?? true)
            case .assistant:
                guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                switch message.status {
                case .complete: return true
                case .streaming, .failed, .cancelled, .refused: return false
                }
            case .notice:
                return false
            }
        }

        // 2. Message window (stepped).
        let messageStart = ContextPolicy.steppedStart(count: eligible.count, limit: policy.maxMessages, step: policy.messageWindowStep)
        var windowed = Array(eligible[messageStart...])
        while let first = windowed.first, first.role != .user { windowed.removeFirst() }
        return windowed
    }

    private static func build(
        _ windowed: [ChatMessage],
        policy: ContextPolicy,
        timeZone: TimeZone,
        imageProvider: (SnapshotAttachment) -> AIImage?
    ) -> [AITurn] {

        // 3. Image window (stepped), always keeping the newest message's images.
        let allAttachmentIDs = windowed.flatMap { $0.role == .user ? $0.attachments.map(\.id) : [] }
        let newestIDs = Set(windowed.last(where: { $0.role == .user })?.attachments.map(\.id) ?? [])
        let imageStart = ContextPolicy.steppedStart(count: allAttachmentIDs.count, limit: max(policy.maxImages, newestIDs.count), step: policy.imageWindowStep)
        let keptIDs = Set(allAttachmentIDs[imageStart...]).union(newestIDs)

        // 4. Build turns, merging consecutive same-role messages.
        var turns: [AITurn] = []
        for message in windowed {
            let role: AIRole = message.role == .user ? .user : .assistant
            var parts: [AIPart] = []
            if role == .user {
                for attachment in message.attachments {
                    if keptIDs.contains(attachment.id), let image = imageProvider(attachment) {
                        parts.append(.image(image))
                        parts.append(.text(describe(attachment)))
                    } else if keptIDs.contains(attachment.id) {
                        parts.append(.text(missingImageText))
                    } else {
                        parts.append(.text(omittedImageText))
                    }
                }
                if let note = message.sourceNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    parts.append(.text("Note typed on the shared Mac: \(note)"))
                }
                if let transcript = message.transcript, !transcript.isEmpty {
                    parts.append(.text(transcript.contextText(timeZone: timeZone)))
                }
            }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if role == .user, let skill = message.skill {
                parts.append(.text(skill.prompt(with: text)))
            } else if !text.isEmpty {
                parts.append(.text(text))
            }
            guard !parts.isEmpty else { continue }

            if let last = turns.last, last.role == role {
                turns[turns.count - 1].parts.append(contentsOf: parts)
            } else {
                turns.append(AITurn(role: role, parts: parts))
            }
        }
        // The API needs the conversation to end on a user turn.
        while let last = turns.last, last.role != .user { turns.removeLast() }
        return turns
    }

    /// Deterministic caption (stable across requests so prompt caching works).
    static func describe(_ attachment: SnapshotAttachment) -> String {
        var pieces: [String] = []
        if let title = attachment.captureTitle, !title.isEmpty { pieces.append("of \(title)") }
        if let source = attachment.sourceName, !source.isEmpty { pieces.append("from \(source)") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]
        pieces.append("captured \(formatter.string(from: attachment.capturedAt))")
        let edited = attachment.isEdited ? " The user annotated or cropped it to highlight what matters." : ""
        return "(Screenshot \(pieces.joined(separator: " ")), \(attachment.pixelWidth)×\(attachment.pixelHeight) px.\(edited))"
    }
}
