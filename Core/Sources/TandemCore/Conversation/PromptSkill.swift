import Foundation

/// A one-click instruction set for a kind of question (e.g. "Debug"), sent with selected
/// pictures, the latest audio transcript and anything the user typed. The thread shows the
/// skill's name; the model gets its full instructions.
public struct PromptSkill: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    /// SF Symbol name.
    public var symbol: String
    public var instructions: String
    /// Include selected composer pictures when the user has enabled them for this question.
    public var attachesScreenshot: Bool
    /// Attach what was said on the shared Mac's audio since the last message (when listening).
    public var attachesTranscript: Bool

    public init(id: UUID = UUID(), title: String, symbol: String, instructions: String, attachesScreenshot: Bool = true, attachesTranscript: Bool = true) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.instructions = instructions
        self.attachesScreenshot = attachesScreenshot
        self.attachesTranscript = attachesTranscript
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, symbol, instructions, attachesScreenshot, attachesTranscript
    }

    /// Skills saved by older versions lack the newer switches; they default to on.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        symbol = try container.decode(String.self, forKey: .symbol)
        instructions = try container.decode(String.self, forKey: .instructions)
        attachesScreenshot = try container.decodeIfPresent(Bool.self, forKey: .attachesScreenshot) ?? true
        attachesTranscript = try container.decodeIfPresent(Bool.self, forKey: .attachesTranscript) ?? true
    }

    /// What the model receives: the instructions, then the user's own words, if any.
    public func prompt(with extraContext: String) -> String {
        let extra = extraContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty else { return base }
        return "\(base)\n\nMore context from me: \(extra)"
    }

    /// Symbols offered when editing a skill.
    public static let symbolChoices = [
        "ladybug", "lightbulb", "arrowshape.turn.up.left", "questionmark.bubble", "text.magnifyingglass",
        "list.bullet.clipboard", "checklist", "hammer", "wrench.and.screwdriver", "doc.text.magnifyingglass",
        "brain", "graduationcap", "character.bubble", "paintbrush", "chart.bar", "sparkles"
    ]

    public static let defaults: [PromptSkill] = [
        PromptSkill(
            id: UUID(uuidString: "5D1B6A2E-0C3F-4A7E-9C10-6B7A1D2E0001")!,
            title: "Debug",
            symbol: "ladybug",
            instructions: """
            Help me debug what's on the screen.
            1. Pin down the symptom: quote the exact error, failing output or unexpected behavior, and say where on the screen it is.
            2. Name the most likely root cause, based on what's visible. Mention at most two alternatives, and only if it's genuinely unclear.
            3. Give the fix as concrete steps: the exact code, command or setting to change, in order.
            4. Say how to confirm it's fixed.
            If the screen doesn't show enough (for example the full stack trace, the failing line or the relevant code), say exactly what to capture next instead of guessing.
            """
        ),
        PromptSkill(
            id: UUID(uuidString: "5D1B6A2E-0C3F-4A7E-9C10-6B7A1D2E0002")!,
            title: "New Problem",
            symbol: "lightbulb",
            instructions: """
            This is a new problem. Give me analysis and guidance.
            1. Restate the problem in a sentence or two: what's given, what's asked, and any constraints, from the screen and from what was said in the audio transcript. Flag anything ambiguous and the assumption you'd make.
            2. Lay out one or two ways to approach it, with their trade-offs, and recommend one.
            3. Walk through the recommended approach step by step, including edge cases and common pitfalls.
            Keep it structured and easy to scan.
            """
        ),
        PromptSkill(
            id: UUID(uuidString: "5D1B6A2E-0C3F-4A7E-9C10-6B7A1D2E0003")!,
            title: "Follow-up",
            symbol: "arrowshape.turn.up.left",
            instructions: """
            Someone just asked me a follow-up question. Find it: first in the live transcript of the computer audio (usually the last question someone asked out loud), otherwise on the screen (usually the most recent question or message). Work out what it's asking, using the transcript, the screen and our conversation so far.
            Put the question as you understood it on the first line, in italics, with obvious speech-to-text mistakes fixed. Then answer it in plain text: no headings, lists or preamble, just a direct answer in a few sentences. If you can't find a follow-up question in the transcript or on the screen, say so in one sentence.
            """
        )
    ]

    /// Built-in instructions from earlier versions, by skill id.
    static let previousDefaultInstructions: [UUID: Set<String>] = [
        UUID(uuidString: "5D1B6A2E-0C3F-4A7E-9C10-6B7A1D2E0002")!: [
            """
            This is a new problem. Give me analysis and guidance.
            1. Restate the problem in a sentence or two: what's given, what's asked, and any constraints visible on the screen. Flag anything ambiguous and the assumption you'd make.
            2. Lay out one or two ways to approach it, with their trade-offs, and recommend one.
            3. Walk through the recommended approach step by step, including edge cases and common pitfalls.
            Keep it structured and easy to scan.
            """
        ],
        UUID(uuidString: "5D1B6A2E-0C3F-4A7E-9C10-6B7A1D2E0003")!: [
            """
            There's a follow-up question on the screen, usually the most recent question or message. Find it and work out what it's asking, using what's on the screen and our conversation so far. Then answer it in plain text: no headings, lists or preamble, just a direct answer in a few sentences. If you can't find a follow-up question on the screen, say so in one sentence.
            """
        ]
    ]

    /// Saved skills with built-in wording from an earlier version get the current wording;
    /// anything the user wrote or edited is left alone.
    public static func upgradingBuiltIns(_ skills: [PromptSkill]) -> [PromptSkill] {
        skills.map { skill in
            guard let current = defaults.first(where: { $0.id == skill.id }),
                  previousDefaultInstructions[skill.id]?.contains(skill.instructions) == true else { return skill }
            var upgraded = skill
            upgraded.instructions = current.instructions
            return upgraded
        }
    }
}
