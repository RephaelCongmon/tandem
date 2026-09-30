import XCTest
@testable import TandemCore

final class PromptSkillTests: XCTestCase {
    private let debug = PromptSkill.defaults[0]

    private func attachment() -> SnapshotAttachment {
        SnapshotAttachment(pixelWidth: 100, pixelHeight: 50, byteCount: 10, capturedAt: Date(timeIntervalSince1970: 1_700_000_000), captureTitle: "Display", sourceName: "Alice's Mac", trigger: .composer)
    }

    private let image = AIImage(data: Data([1, 2, 3]), mimeType: "image/jpeg", width: 100, height: 50)

    private func texts(_ turn: AITurn) -> [String] {
        turn.parts.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
    }

    func testSkillWithOnlyAScreenshotSendsItsInstructions() throws {
        let message = ChatMessage(role: .user, text: "", attachments: [attachment()], skill: debug)
        let turns = ContextBuilder.turns(for: [message]) { _ in self.image }
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turn.parts.contains { if case .image = $0 { return true } else { return false } })
        XCTAssertEqual(texts(turn).last, debug.instructions)
    }

    func testTypedTextBecomesExtraContext() throws {
        let message = ChatMessage(role: .user, text: "  It started after the upgrade. ", attachments: [], skill: debug)
        let turn = try XCTUnwrap(ContextBuilder.turns(for: [message]) { _ in nil }.first)
        XCTAssertEqual(texts(turn).last, debug.instructions + "\n\nMore context from me: It started after the upgrade.")
    }

    func testASkillAloneIsStillAQuestion() {
        let message = ChatMessage(role: .user, text: "", skill: debug)
        XCTAssertEqual(ContextBuilder.turns(for: [message]) { _ in nil }.count, 1)
    }

    func testEarlierSkillMessagesKeepTheirInstructionsInHistory() throws {
        let messages = [
            ChatMessage(role: .user, text: "", skill: PromptSkill.defaults[1]),
            ChatMessage(role: .assistant, text: "Here's the plan."),
            ChatMessage(role: .user, text: "", skill: PromptSkill.defaults[2])
        ]
        let turns = ContextBuilder.turns(for: messages) { _ in nil }
        XCTAssertEqual(turns.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(texts(turns[0]).last, PromptSkill.defaults[1].instructions)
        XCTAssertEqual(texts(turns[2]).last, PromptSkill.defaults[2].instructions)
    }

    func testMessagesSavedBeforeSkillsStillLoad() throws {
        let message = ChatMessage(role: .user, text: "Hi")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object["skill"] = nil
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.skill)
        XCTAssertEqual(decoded.text, "Hi")

        let withSkill = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(ChatMessage(role: .user, text: "", skill: debug)))
        XCTAssertEqual(withSkill.skill, debug)
    }

    func testDefaults() {
        XCTAssertEqual(PromptSkill.defaults.map(\.title), ["Debug", "New Problem", "Follow-up"])
        XCTAssertEqual(Set(PromptSkill.defaults.map(\.id)).count, 3)
        XCTAssertTrue(PromptSkill.defaults.allSatisfy { $0.attachesScreenshot && !$0.instructions.isEmpty })
        XCTAssertTrue(PromptSkill.defaults.allSatisfy { PromptSkill.symbolChoices.contains($0.symbol) })
    }
}
