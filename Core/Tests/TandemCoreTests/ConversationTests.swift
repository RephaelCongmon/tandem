import XCTest
@testable import TandemCore

final class ConversationTests: XCTestCase {
    private func attachment(_ i: Int) -> SnapshotAttachment {
        SnapshotAttachment(pixelWidth: 100, pixelHeight: 50, byteCount: 10, capturedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)), captureTitle: "Display", sourceName: "Alice's Mac", trigger: .manual)
    }

    private func image(_ a: SnapshotAttachment) -> AIImage {
        AIImage(data: Data(a.id.uuidString.utf8), mimeType: "image/jpeg", width: a.pixelWidth, height: a.pixelHeight)
    }

    func testSteppedWindow() {
        XCTAssertEqual(ContextPolicy.steppedStart(count: 3, limit: 4, step: 2), 0)
        XCTAssertEqual(ContextPolicy.steppedStart(count: 5, limit: 4, step: 2), 2)
        XCTAssertEqual(ContextPolicy.steppedStart(count: 6, limit: 4, step: 2), 2)
        XCTAssertEqual(ContextPolicy.steppedStart(count: 7, limit: 4, step: 2), 4)
        // Kept count stays within (limit - step, limit].
        for count in 1...50 {
            let start = ContextPolicy.steppedStart(count: count, limit: 6, step: 3)
            let kept = count - start
            XCTAssertLessThanOrEqual(kept, 6)
            XCTAssertGreaterThan(kept, min(count, 6) - 3)
            XCTAssertEqual(start % 3, 0)
        }
    }

    func testTurnsIncludeNewestImagesAndPlaceholdersForOlderOnes() {
        var messages: [ChatMessage] = []
        for i in 0..<6 {
            messages.append(ChatMessage(role: .user, text: "q\(i)", attachments: [attachment(i)]))
            messages.append(ChatMessage(role: .assistant, text: "a\(i)"))
        }
        messages.append(ChatMessage(role: .user, text: "latest", attachments: [attachment(99)]))
        let turns = ContextBuilder.turns(for: messages, policy: ContextPolicy(maxImages: 3, imageWindowStep: 2), imageProvider: image)
        XCTAssertEqual(turns.count, 13)
        XCTAssertEqual(turns.last?.role, .user)
        let imageCount = turns.flatMap(\.parts).filter { if case .image = $0 { return true } else { return false } }.count
        XCTAssertLessThanOrEqual(imageCount, 3)
        XCTAssertGreaterThanOrEqual(imageCount, 2)
        guard case .image = turns.last?.parts.first else { return XCTFail("newest image first in last turn") }
        let placeholders = turns.flatMap(\.parts).filter { $0 == .text(ContextBuilder.omittedImageText) }.count
        XCTAssertEqual(placeholders + imageCount, 7)
    }

    func testFailedAssistantMessagesAreSkippedAndUserTurnsMerged() {
        let messages = [
            ChatMessage(role: .user, text: "first"),
            ChatMessage(role: .assistant, text: "partial", status: .failed("boom")),
            ChatMessage(role: .notice, text: "Connection lost"),
            ChatMessage(role: .user, text: "retry"),
        ]
        let turns = ContextBuilder.turns(for: messages, imageProvider: image)
        XCTAssertEqual(turns, [AITurn(role: .user, parts: [.text("first"), .text("retry")])])
    }

    func testMissingImagesBecomePlaceholders() {
        let a = attachment(1)
        let messages = [ChatMessage(role: .user, text: "what's this?", attachments: [a], sourceNote: "from the other mac")]
        let turns = ContextBuilder.turns(for: messages) { _ in nil }
        XCTAssertEqual(turns.first?.parts, [.text(ContextBuilder.missingImageText), .text("Note typed on the shared Mac: from the other mac"), .text("what's this?")])
    }

    func testCaptionsAreDeterministic() {
        let a = attachment(3)
        XCTAssertEqual(ContextBuilder.describe(a), ContextBuilder.describe(a))
        XCTAssertTrue(ContextBuilder.describe(a).contains("Alice's Mac"))
    }

    func testAutoTitle() {
        XCTAssertEqual(ChatThread.autoTitle(for: "Why does this build fail?", fallbackDate: Date()), "Why does this build fail?")
        let long = ChatThread.autoTitle(for: String(repeating: "word ", count: 30), fallbackDate: Date())
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.count, 50)
        XCTAssertTrue(ChatThread.autoTitle(for: "  ", fallbackDate: Date()).hasPrefix("Screen at"))
    }

    func testThreadStoreRoundTripAndCrashRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory, coalesceInterval: 0.01)
        var thread = ChatThread(title: "Test")
        thread.messages = [ChatMessage(role: .user, text: "hi", attachments: [attachment(1)]), ChatMessage(role: .assistant, text: "…", status: .streaming)]
        store.save(thread)
        store.flush()
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].messages[0], thread.messages[0])
        XCTAssertEqual(loaded[0].messages[1].status, .cancelled)
        store.delete(thread.id)
        store.flush()
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testSnapshotStoreMemoryOnlyAndDiskModes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let memoryOnly = SnapshotStore(directory: directory, keepOnDisk: false)
        memoryOnly.put(Data([1, 2, 3]), id: id)
        XCTAssertEqual(memoryOnly.data(for: id), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id.uuidString).jpg").path))

        memoryOnly.setKeepOnDisk(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id.uuidString).jpg").path))
        let reopened = SnapshotStore(directory: directory, keepOnDisk: true)
        XCTAssertEqual(reopened.data(for: id), Data([1, 2, 3]))
        reopened.setKeepOnDisk(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id.uuidString).jpg").path))
    }

    func testSnapshotStoreEvictsUnderMemoryPressure() {
        let store = SnapshotStore(directory: nil, keepOnDisk: false, memoryLimitBytes: 1000)
        let ids = (0..<10).map { _ in UUID() }
        for id in ids { store.put(Data(repeating: 1, count: 300), id: id) }
        XCTAssertTrue(store.contains(ids.last!))
        XCTAssertFalse(store.contains(ids.first!))
    }
}
