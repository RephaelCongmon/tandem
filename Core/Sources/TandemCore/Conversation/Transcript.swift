import Foundation

/// One finished stretch of speech recognized from the shared Mac's audio.
public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var start: Date
    public var end: Date

    public init(id: UUID = UUID(), text: String, start: Date, end: Date) {
        self.id = id
        self.text = text
        self.start = start
        self.end = max(start, end)
    }
}

/// The part of the live transcript sent with a message: what was said on the shared Mac since
/// the previous excerpt (within a time window). It's saved with the message, so later questions
/// in the thread still carry it as context.
public struct TranscriptExcerpt: Codable, Sendable, Hashable {
    public var segments: [TranscriptSegment]
    /// Words still being recognized when the message was sent (the newest speech).
    public var pendingText: String?
    public var sourceName: String?
    /// Earlier speech was left out to keep the excerpt within its window.
    public var omitsEarlierSpeech: Bool
    /// The newest speech this excerpt covers (including pending words); the next excerpt in the
    /// thread starts after it.
    public var coveredThrough: Date?
    /// Names and terms the user listed (Settings › Listening), to spell misheard words right.
    public var terms: [String]?

    public init(segments: [TranscriptSegment], pendingText: String? = nil, sourceName: String? = nil, omitsEarlierSpeech: Bool = false, coveredThrough: Date? = nil, terms: [String]? = nil) {
        self.segments = segments
        self.pendingText = pendingText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.sourceName = sourceName
        self.omitsEarlierSpeech = omitsEarlierSpeech
        self.coveredThrough = coveredThrough ?? segments.last?.end
        self.terms = terms.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Splits a comma- or line-separated list of names and terms.
    public static func terms(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(200)
            .map { $0 }
    }

    public var isEmpty: Bool { segments.isEmpty && pendingText == nil }

    public var start: Date? { segments.first?.start }
    public var end: Date? { segments.last?.end }

    /// Plain text, one segment per line.
    public var plainText: String {
        (segments.map(\.text) + [pendingText].compactMap { $0 }).joined(separator: "\n")
    }

    public var wordCount: Int {
        plainText.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// What the model reads. Deterministic for a given excerpt, so cached prompts stay valid.
    public func contextText(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let place = sourceName.map { " on \($0)" } ?? ""
        var lines = ["Live transcript of the computer audio\(place) (a meeting or call the user is in), heard since the previous message. It's automatic speech-to-text, so expect misheard words and missing punctuation; read it for the intended meaning. Newest last:"]
        if omitsEarlierSpeech { lines.append("[Earlier speech omitted.]") }
        for segment in segments {
            lines.append("[\(formatter.string(from: segment.start))] \(segment.text)")
        }
        if let pendingText {
            lines.append("[just now, still being transcribed] \(pendingText)")
        }
        if let terms, !terms.isEmpty {
            lines.append("Names and terms that may come up; words that sound like them probably are them: \(terms.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }
}

/// The rolling transcript of the shared Mac's audio: finished segments plus the words still
/// being recognized.
public struct LiveTranscript: Sendable, Equatable {
    public private(set) var segments: [TranscriptSegment] = []
    /// The newest words; replaced on every update until the recognizer finalizes them.
    public private(set) var volatile: TranscriptSegment?
    /// Segments older than this are dropped.
    public var retention: TimeInterval
    public var maxSegments: Int

    public init(retention: TimeInterval = 4 * 3600, maxSegments: Int = 4000) {
        self.retention = retention
        self.maxSegments = maxSegments
    }

    public var isEmpty: Bool { segments.isEmpty && volatile == nil }

    /// A finalized result. Replaces the volatile text it covers.
    public mutating func commit(_ text: String, start: Date, end: Date) {
        let cleaned = Self.clean(text)
        volatile = nil
        guard !cleaned.isEmpty else { return }
        // Recognizers can report the same stretch again after a restart; keep one copy.
        if let last = segments.last, last.text == cleaned, abs(last.start.timeIntervalSince(start)) < 1 { return }
        segments.append(TranscriptSegment(text: cleaned, start: start, end: end))
        trim(now: end)
    }

    public mutating func updateVolatile(_ text: String, start: Date, end: Date) {
        let cleaned = Self.clean(text)
        if cleaned.isEmpty {
            volatile = nil
        } else if let current = volatile {
            volatile = TranscriptSegment(id: current.id, text: cleaned, start: start, end: end)
        } else {
            volatile = TranscriptSegment(text: cleaned, start: start, end: end)
        }
    }

    public mutating func clearVolatile() {
        volatile = nil
    }

    public mutating func removeAll() {
        segments.removeAll()
        volatile = nil
    }

    /// The newest finished text (trimmed to fit `maxCharacters` with the volatile words), for captions.
    public func recentText(maxCharacters: Int = 240) -> (final: String, volatile: String) {
        let pending = volatile?.text ?? ""
        var budget = max(0, maxCharacters - pending.count)
        var pieces: [String] = []
        for segment in segments.reversed() where budget > 0 {
            if segment.text.count <= budget {
                pieces.insert(segment.text, at: 0)
                budget -= segment.text.count + 1
            } else {
                // Start at a word boundary.
                let tail = segment.text.suffix(budget)
                let cutsWord = tail.startIndex > segment.text.startIndex && segment.text[segment.text.index(before: tail.startIndex)] != " "
                let words = tail.split(separator: " ", maxSplits: 1)
                let trimmed = cutsWord && words.count == 2 ? String(words[1]) : String(tail)
                pieces.insert("…" + trimmed.trimmingCharacters(in: .whitespaces), at: 0)
                budget = 0
            }
        }
        return (pieces.joined(separator: " "), pending)
    }

    /// Speech that ended after `after` and within `window` of `now`, newest kept when over
    /// `maxCharacters`. `nil` when there's nothing new.
    public func excerpt(
        after: Date?,
        now: Date = Date(),
        window: TimeInterval,
        maxCharacters: Int = 16_000,
        includeVolatile: Bool = true,
        sourceName: String? = nil,
        terms: [String] = []
    ) -> TranscriptExcerpt? {
        let windowStart = now.addingTimeInterval(-window)
        let fresh = segments.filter { segment in
            if let after, segment.end <= after { return false }
            return true
        }
        var kept = fresh.filter { $0.end > windowStart }
        var omitted = kept.count < fresh.count
        let pending = includeVolatile ? volatile?.text : nil
        var total = kept.reduce(pending?.count ?? 0) { $0 + $1.text.count + 12 }
        while total > maxCharacters, !kept.isEmpty {
            total -= kept.removeFirst().text.count + 12
            omitted = true
        }
        let covered = [kept.last?.end, pending == nil ? nil : volatile?.end].compactMap { $0 }.max()
        let excerpt = TranscriptExcerpt(segments: kept, pendingText: pending, sourceName: sourceName, omitsEarlierSpeech: omitted, coveredThrough: covered, terms: terms)
        return excerpt.isEmpty ? nil : excerpt
    }

    private mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        if let first = segments.first, first.end < cutoff {
            segments.removeAll { $0.end < cutoff }
        }
        if segments.count > maxSegments {
            segments.removeFirst(segments.count - maxSegments)
        }
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
