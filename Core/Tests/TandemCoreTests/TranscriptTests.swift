import XCTest
@testable import TandemCore

final class LiveTranscriptTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testVolatileWordsAreReplacedAndThenCommitted() {
        var transcript = LiveTranscript()
        transcript.updateVolatile("Thanks", start: at(0), end: at(1))
        transcript.updateVolatile("Thanks for walking   us through", start: at(0), end: at(2))
        XCTAssertEqual(transcript.volatile?.text, "Thanks for walking us through")
        let volatileID = transcript.volatile?.id
        transcript.updateVolatile("Thanks for walking us through that", start: at(0), end: at(2.5))
        XCTAssertEqual(transcript.volatile?.id, volatileID, "one live line, updated in place")
        XCTAssertTrue(transcript.segments.isEmpty)

        transcript.commit("Thanks for walking us through that design.", start: at(0), end: at(3))
        XCTAssertNil(transcript.volatile)
        XCTAssertEqual(transcript.segments.map(\.text), ["Thanks for walking us through that design."])

        transcript.commit("   ", start: at(3), end: at(4))
        XCTAssertEqual(transcript.segments.count, 1, "blank results are dropped")
        transcript.commit("Thanks for walking us through that design.", start: at(0.2), end: at(3))
        XCTAssertEqual(transcript.segments.count, 1, "a repeated result is kept once")
        transcript.updateVolatile("", start: at(4), end: at(5))
        XCTAssertNil(transcript.volatile)
    }

    func testExcerptTakesOnlyNewSpeechInsideTheWindow() throws {
        var transcript = LiveTranscript()
        for index in 0..<10 {
            transcript.commit("Sentence \(index).", start: at(Double(index) * 60), end: at(Double(index) * 60 + 5))
        }
        transcript.updateVolatile("So my follow-up question is", start: at(600), end: at(603))

        // Nothing sent yet: the last five minutes.
        let first = try XCTUnwrap(transcript.excerpt(after: nil, now: at(604), window: 300))
        XCTAssertEqual(first.segments.map(\.text), ["Sentence 5.", "Sentence 6.", "Sentence 7.", "Sentence 8.", "Sentence 9."])
        XCTAssertEqual(first.pendingText, "So my follow-up question is")
        XCTAssertTrue(first.omitsEarlierSpeech)
        XCTAssertEqual(first.coveredThrough, at(603), "through the pending words")

        // After an excerpt that ended at 8:05, only what came later.
        let next = try XCTUnwrap(transcript.excerpt(after: at(485), now: at(604), window: 300))
        XCTAssertEqual(next.segments.map(\.text), ["Sentence 9."])
        XCTAssertFalse(next.omitsEarlierSpeech)

        // Nothing new at all.
        transcript.clearVolatile()
        XCTAssertNil(transcript.excerpt(after: at(545), now: at(604), window: 300))
        XCTAssertEqual(transcript.excerpt(after: nil, now: at(604), window: 300)?.pendingText, nil)
    }

    func testExcerptKeepsTheNewestSpeechWhenTooLong() throws {
        var transcript = LiveTranscript()
        for index in 0..<50 {
            transcript.commit(String(repeating: "word\(index) ", count: 20), start: at(Double(index)), end: at(Double(index) + 1))
        }
        let excerpt = try XCTUnwrap(transcript.excerpt(after: nil, now: at(51), window: 3600, maxCharacters: 1_000))
        XCTAssertLessThanOrEqual(excerpt.plainText.count, 1_000)
        XCTAssertTrue(excerpt.segments.last?.text.hasPrefix("word49") == true)
        XCTAssertTrue(excerpt.omitsEarlierSpeech)
    }

    func testOldSpeechIsDropped() {
        var transcript = LiveTranscript(retention: 600, maxSegments: 3)
        transcript.commit("old", start: at(0), end: at(1))
        transcript.commit("newer", start: at(700), end: at(701))
        XCTAssertEqual(transcript.segments.map(\.text), ["newer"])
        for index in 0..<5 { transcript.commit("s\(index)", start: at(702 + Double(index)), end: at(703 + Double(index))) }
        XCTAssertEqual(transcript.segments.map(\.text), ["s2", "s3", "s4"])
    }

    func testCaptionsShowTheNewestWords() {
        var transcript = LiveTranscript()
        transcript.commit("First sentence here.", start: at(0), end: at(1))
        transcript.commit("Second sentence is a bit longer.", start: at(1), end: at(2))
        transcript.updateVolatile("and now", start: at(2), end: at(3))
        let all = transcript.recentText(maxCharacters: 200)
        XCTAssertEqual(all.final, "First sentence here. Second sentence is a bit longer.")
        XCTAssertEqual(all.volatile, "and now")
        let short = transcript.recentText(maxCharacters: 20)
        XCTAssertEqual(short.final, "…a bit longer.")
        XCTAssertEqual(transcript.recentText(maxCharacters: 22).final, "…a bit longer.", "never starts mid-word")
        XCTAssertEqual(short.volatile, "and now")
    }

    func testExcerptTextForTheModel() throws {
        let excerpt = TranscriptExcerpt(
            segments: [
                TranscriptSegment(text: "Thanks for walking us through that design.", start: at(0), end: at(2)),
                TranscriptSegment(text: "So how would you handle cash invalidation?", start: at(2), end: at(6))
            ],
            pendingText: " if two services write at once ",
            sourceName: "Work MacBook",
            omitsEarlierSpeech: true
        )
        let text = excerpt.contextText(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text, """
        Live transcript of the computer audio on Work MacBook (a meeting or call the user is in), heard since the previous message. It's automatic speech-to-text, so expect misheard words and missing punctuation; read it for the intended meaning. Newest last:
        [Earlier speech omitted.]
        [22:13:20] Thanks for walking us through that design.
        [22:13:22] So how would you handle cash invalidation?
        [just now, still being transcribed] if two services write at once
        """)
        XCTAssertEqual(excerpt.wordCount, 20)
        XCTAssertEqual(excerpt.start, at(0))
        XCTAssertEqual(excerpt.end, at(6))
        XCTAssertTrue(TranscriptExcerpt(segments: [], pendingText: "  ").isEmpty)
    }

    func testNamesAndTermsGoWithTheTranscript() throws {
        XCTAssertEqual(TranscriptExcerpt.terms(from: " Kubernetes, MTN Ghana\nRephael;  kubernetes ,, "), ["Kubernetes", "MTN Ghana", "Rephael"])
        var transcript = LiveTranscript()
        transcript.commit("How do you scale cooper netties?", start: at(0), end: at(2))
        let excerpt = try XCTUnwrap(transcript.excerpt(after: nil, now: at(3), window: 300, terms: ["Kubernetes"]))
        XCTAssertTrue(excerpt.contextText().hasSuffix("Names and terms that may come up; words that sound like them probably are them: Kubernetes."))
        let none = try XCTUnwrap(transcript.excerpt(after: nil, now: at(3), window: 300))
        XCTAssertNil(none.terms)
        XCTAssertFalse(none.contextText().contains("Names and terms"))
    }
}

final class TranscriptContextTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func texts(_ turn: AITurn) -> [String] {
        turn.parts.compactMap { if case .text(let text) = $0 { return text } else { return nil } }
    }

    private func excerpt(_ text: String) -> TranscriptExcerpt {
        TranscriptExcerpt(segments: [TranscriptSegment(text: text, start: t0, end: t0.addingTimeInterval(3))], sourceName: "Work Mac")
    }

    func testTranscriptGoesBeforeTheQuestionAndStaysInHistory() throws {
        let followUp = PromptSkill.defaults[2]
        let messages = [
            ChatMessage(role: .user, text: "What is this?", transcript: excerpt("Let's look at the caching layer.")),
            ChatMessage(role: .assistant, text: "It's a cache."),
            ChatMessage(role: .user, text: "", skill: followUp, transcript: excerpt("How would you invalidate it?"))
        ]
        let turns = ContextBuilder.turns(for: messages, timeZone: TimeZone(identifier: "UTC")!) { _ in nil }
        XCTAssertEqual(turns.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(texts(turns[0]).count, 2)
        XCTAssertTrue(texts(turns[0])[0].contains("Let's look at the caching layer."))
        XCTAssertEqual(texts(turns[0])[1], "What is this?")
        XCTAssertTrue(texts(turns[2])[0].hasPrefix("Live transcript of the computer audio on Work Mac"))
        XCTAssertTrue(texts(turns[2])[0].hasSuffix("How would you invalidate it?"))
        XCTAssertEqual(texts(turns[2])[1], followUp.instructions)
    }

    func testATranscriptAloneIsAQuestion() {
        let message = ChatMessage(role: .user, text: "", transcript: excerpt("Any questions?"))
        XCTAssertEqual(ContextBuilder.turns(for: [message]) { _ in nil }.count, 1)
        let empty = ChatMessage(role: .user, text: "", transcript: TranscriptExcerpt(segments: []))
        XCTAssertTrue(ContextBuilder.turns(for: [empty]) { _ in nil }.isEmpty)
    }

    func testMessagesSavedBeforeTranscriptsStillLoad() throws {
        let message = ChatMessage(role: .user, text: "Hi", transcript: excerpt("hello"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        XCTAssertNotNil(object["transcript"])
        object["transcript"] = nil
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.transcript)
        let roundTripped = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(roundTripped.transcript, message.transcript)
    }
}

final class SkillTranscriptTests: XCTestCase {
    func testFollowUpLooksInTheTranscriptFirst() {
        let followUp = PromptSkill.defaults[2]
        XCTAssertTrue(followUp.instructions.contains("transcript"))
        XCTAssertTrue(followUp.attachesTranscript && followUp.attachesScreenshot)
    }

    func testSkillsSavedByOlderVersionsDecodeWithTranscriptsOn() throws {
        let json = #"[{"id":"5D1B6A2E-0C3F-4A7E-9C10-6B7A1D2E0009","title":"Mine","symbol":"sparkles","instructions":"Do it.","attachesScreenshot":false}]"#
        let skills = try JSONDecoder().decode([PromptSkill].self, from: Data(json.utf8))
        XCTAssertEqual(skills.first?.attachesScreenshot, false)
        XCTAssertEqual(skills.first?.attachesTranscript, true)
        let again = try JSONDecoder().decode([PromptSkill].self, from: JSONEncoder().encode(skills))
        XCTAssertEqual(again, skills)
    }

    func testOldBuiltInWordingIsUpgradedButEditsAreKept() throws {
        let oldFollowUp = try XCTUnwrap(PromptSkill.previousDefaultInstructions[PromptSkill.defaults[2].id]?.first)
        var stored = PromptSkill.defaults
        stored[2].instructions = oldFollowUp
        stored[2].title = "Follow up"
        stored[0].instructions = "My own debug steps."
        stored.append(PromptSkill(title: "Custom", symbol: "sparkles", instructions: oldFollowUp))

        let upgraded = PromptSkill.upgradingBuiltIns(stored)
        XCTAssertEqual(upgraded[2].instructions, PromptSkill.defaults[2].instructions)
        XCTAssertEqual(upgraded[2].title, "Follow up", "only the wording changes")
        XCTAssertEqual(upgraded[0].instructions, "My own debug steps.")
        XCTAssertEqual(upgraded[3].instructions, oldFollowUp, "a user's own skill is never rewritten")
        XCTAssertEqual(PromptSkill.upgradingBuiltIns(PromptSkill.defaults), PromptSkill.defaults)
    }
}
