import Foundation

/// Scrolling math shared by the overlay and the Studio's controls.
public enum GlanceScroll {
    public static func maxOffset(content: Double, viewport: Double) -> Double {
        guard content.isFinite, viewport.isFinite else { return 0 }
        return max(0, content - viewport)
    }

    public static func clamp(_ offset: Double, content: Double, viewport: Double) -> Double {
        guard offset.isFinite else { return 0 }
        return min(max(0, offset), maxOffset(content: content, viewport: viewport))
    }

    /// One arrow press: a few lines, never more than a quarter of the view so
    /// consecutive views overlap (Glance's step).
    public static func lineStep(viewport: Double) -> Double {
        max(12, min(48, viewport * 0.25))
    }

    /// One page: most of the view, keeping a couple of lines for context.
    public static func pageStep(viewport: Double) -> Double {
        max(lineStep(viewport: viewport), viewport * 0.85)
    }
}

/// The Studio's side of a Glance document: turns the text it wants shown into the
/// smallest message that gets the Source there.
public struct GlanceOutbox: Sendable {
    public private(set) var documentID = UUID()
    public private(set) var revision = 0
    /// What the Source holds if every message so far arrived; nil when it must get the whole text.
    private var delivered: (text: String, title: String?, origin: GlanceContent.Origin, isStreaming: Bool)?
    /// The last state asked for, resent in full by `resync`.
    private var wanted: (text: String, title: String?, origin: GlanceContent.Origin, isStreaming: Bool)?

    public init() {}

    /// What the Source should be showing (as last requested).
    public var text: String { wanted?.text ?? "" }
    public var title: String? { wanted?.title }
    public var origin: GlanceContent.Origin? { wanted?.origin }
    public var isStreaming: Bool { wanted?.isStreaming ?? false }

    /// Starts a new document: the next update replaces whatever the overlay showed.
    public mutating func startDocument(id: UUID = UUID()) {
        documentID = id
        revision = 0
        delivered = nil
        wanted = nil
    }

    /// The message that brings the Source to `text`, or nil when nothing changed. An answer
    /// that only grew is sent as an append of the new part.
    public mutating func update(text: String, title: String?, origin: GlanceContent.Origin, isStreaming: Bool) -> GlanceContent? {
        let text = Self.capped(text)
        wanted = (text, title, origin, isStreaming)
        if let delivered, delivered.text == text, delivered.title == title, delivered.origin == origin, delivered.isStreaming == isStreaming {
            return nil
        }
        revision += 1
        var message = GlanceContent(documentID: documentID, revision: revision, text: text, title: title, origin: origin, isStreaming: isStreaming)
        if let delivered, text.utf8.starts(with: delivered.text.utf8) {
            let base = delivered.text.utf8.count
            message.text = String(decoding: Array(text.utf8.dropFirst(base)), as: UTF8.self)
            message.appendingToUTF8Count = base
        }
        delivered = (text, title, origin, isStreaming)
        return message
    }

    /// The whole current text again (after reconnecting, or when the Source lost track),
    /// marked as a resync.
    public mutating func resync() -> GlanceContent? {
        guard let wanted else { return nil }
        delivered = nil
        var message = update(text: wanted.text, title: wanted.title, origin: wanted.origin, isStreaming: wanted.isStreaming)
        message?.isResync = true
        return message
    }

    /// Cuts text over `GlanceContent.maxTextBytes` at a character boundary.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > GlanceContent.maxTextBytes else { return text }
        var end = text.startIndex
        var bytes = 0
        for index in text.indices {
            let next = text.index(after: index)
            bytes += text[index..<next].utf8.count
            if bytes > GlanceContent.maxTextBytes - 16 { break }
            end = next
        }
        return String(text[..<end]) + "\n\n…"
    }
}

/// The Source's copy of a Glance document.
public struct GlanceDocument: Sendable, Equatable {
    public enum Outcome: Equatable, Sendable {
        case applied
        /// Older than what's shown already; nothing changed.
        case stale
        /// An append that doesn't fit what's held: ask for the whole text.
        case needsFullText
    }

    public private(set) var id: UUID?
    public private(set) var revision = 0
    public private(set) var text = ""
    public private(set) var title: String?
    public private(set) var origin: GlanceContent.Origin = .note
    public private(set) var isStreaming = false

    public init() {}

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public mutating func apply(_ content: GlanceContent) -> Outcome {
        let sameDocument = id == content.documentID
        if sameDocument, content.revision <= revision { return .stale }
        if let base = content.appendingToUTF8Count {
            guard sameDocument, text.utf8.count == base else { return .needsFullText }
            text += content.text
        } else {
            text = content.text
        }
        if text.utf8.count > GlanceContent.maxTextBytes { text = GlanceOutbox.capped(text) }
        id = content.documentID
        revision = content.revision
        title = content.title
        origin = content.origin
        isStreaming = content.isStreaming
        return .applied
    }

    public mutating func clear() {
        self = GlanceDocument()
    }
}
