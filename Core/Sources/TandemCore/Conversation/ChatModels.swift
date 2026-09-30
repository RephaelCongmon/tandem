import Foundation

/// Metadata for a screenshot attached to a message. The pixels live in
/// `SnapshotStore`, keyed by `id` — by default only in memory.
public struct SnapshotAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var byteCount: Int
    public var mimeType: String
    public var capturedAt: Date
    /// What was captured, e.g. "Built-in Retina Display" or "Xcode — Tandem".
    public var captureTitle: String?
    /// Which Mac it came from.
    public var sourceName: String?
    /// Annotated/cropped/redacted in the markup editor.
    public var isEdited: Bool
    public var trigger: SnapshotTrigger

    public init(
        id: UUID = UUID(), pixelWidth: Int, pixelHeight: Int, byteCount: Int, mimeType: String = "image/jpeg",
        capturedAt: Date, captureTitle: String?, sourceName: String?, isEdited: Bool = false, trigger: SnapshotTrigger
    ) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.mimeType = mimeType
        self.capturedAt = capturedAt
        self.captureTitle = captureTitle
        self.sourceName = sourceName
        self.isEdited = isEdited
        self.trigger = trigger
    }
}

public struct ChatMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable, Hashable {
        case user
        case assistant
        /// A system notice shown in the thread (never sent to the AI).
        case notice
    }

    public enum Status: Codable, Sendable, Hashable {
        case complete
        case streaming
        case failed(String)
        case cancelled
        case refused(String?)
    }

    public var id: UUID
    public var role: Role
    public var createdAt: Date
    public var text: String
    public var reasoning: String?
    public var attachments: [SnapshotAttachment]
    public var status: Status
    /// What caused this message (for user messages created by automation/hotkeys).
    public var trigger: SnapshotTrigger?
    /// Note typed on the Source Mac when it pushed the snapshot.
    public var sourceNote: String?
    public var provider: AIProviderKind?
    /// Model that produced an assistant message.
    public var model: String?
    public var usage: AIUsage?
    /// Seconds from request to first streamed token.
    public var firstTokenSeconds: Double?
    /// Seconds from request to completion.
    public var totalSeconds: Double?
    public var notices: [String]
    /// The skill a user message was sent with (a copy, so later edits don't rewrite history).
    public var skill: PromptSkill?

    public init(
        id: UUID = UUID(), role: Role, createdAt: Date = Date(), text: String, reasoning: String? = nil,
        attachments: [SnapshotAttachment] = [], status: Status = .complete, trigger: SnapshotTrigger? = nil,
        sourceNote: String? = nil, provider: AIProviderKind? = nil, model: String? = nil, usage: AIUsage? = nil,
        firstTokenSeconds: Double? = nil, totalSeconds: Double? = nil, notices: [String] = [], skill: PromptSkill? = nil
    ) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.text = text
        self.reasoning = reasoning
        self.attachments = attachments
        self.status = status
        self.trigger = trigger
        self.sourceNote = sourceNote
        self.provider = provider
        self.model = model
        self.usage = usage
        self.firstTokenSeconds = firstTokenSeconds
        self.totalSeconds = totalSeconds
        self.notices = notices
        self.skill = skill
    }

    public var isStreaming: Bool {
        if case .streaming = status { return true }
        return false
    }
}

public struct ChatThread: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    /// True once the user renamed the thread (auto-titling stops).
    public var hasCustomTitle: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var messages: [ChatMessage]

    public init(id: UUID = UUID(), title: String = "New Thread", createdAt: Date = Date(), messages: [ChatMessage] = []) {
        self.id = id
        self.title = title
        hasCustomTitle = false
        self.createdAt = createdAt
        updatedAt = createdAt
        isPinned = false
        self.messages = messages
    }

    public var attachmentCount: Int { messages.reduce(0) { $0 + $1.attachments.count } }

    /// Last user- or assistant-authored text as plain text, for sidebar previews.
    public var preview: String {
        for message in messages.reversed() where message.role != .notice {
            let text = Self.plainText(fromMarkdown: message.text)
            if !text.isEmpty { return text }
            if !message.attachments.isEmpty { return "Screenshot" }
        }
        return "No messages yet"
    }

    /// Strips common Markdown syntax so previews read naturally.
    public static func plainText(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence || line.isEmpty { continue }
            if line.allSatisfy({ "-*_=|: ".contains($0) }) { continue }
            while let first = line.first, "#>".contains(first) { line.removeFirst() }
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") { line.removeFirst(6) }
            if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " { line.removeFirst(2) }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "|", with: " ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
            if lines.count >= 3 { break }
        }
        return lines.joined(separator: " ")
    }

    /// Derives a short title from the first user message.
    public static func autoTitle(for text: String, fallbackDate: Date) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Screen at \(formatter.string(from: fallbackDate))"
        }
        if cleaned.count <= 48 { return cleaned }
        let cut = cleaned.prefix(48)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 24 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}
