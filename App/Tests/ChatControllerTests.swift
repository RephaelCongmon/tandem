import TandemCore
import TandemUI
import XCTest
@testable import Tandem

/// A scripted AI client that records requests.
final class ScriptedClient: AIClient, @unchecked Sendable {
    enum Behavior {
        case reply([AIStreamEvent], delayNanos: UInt64 = 0)
        case fail(AIError)
    }

    private let lock = NSLock()
    private var _behavior: Behavior
    private var _requests: [AIRequest] = []

    init(_ behavior: Behavior) { _behavior = behavior }

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }

    var requests: [AIRequest] { lock.withLock { _requests } }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        lock.withLock { _requests.append(request) }
        let behavior = self.behavior
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch behavior {
                case .fail(let error):
                    continuation.finish(throwing: error)
                case .reply(let events, let delay):
                    for event in events {
                        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                        if Task.isCancelled {
                            continuation.finish(throwing: AIError.cancelled)
                            return
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [AIModelInfo] { [] }
}

@MainActor
final class ChatControllerTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func makeChat(_ client: ScriptedClient) -> ChatController {
        let defaults = UserDefaults(suiteName: "tandem.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        // The OpenAI-compatible provider needs no key, so tests never touch the Keychain.
        settings.provider = .openAICompatible
        settings.customModel = "mock-model"
        settings.customBaseURL = "http://127.0.0.1:9/v1/"
        let keys = APIKeyStore(servicePrefix: "com.rofel.tandem.tests.\(UUID().uuidString)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let chat = ChatController(
            settings: settings,
            keys: keys,
            threadStore: ThreadStore(directory: directory, coalesceInterval: 0.01),
            snapshots: SnapshotStore(directory: nil, keepOnDisk: false),
            clientFactory: { _ in client }
        )
        return chat
    }

    /// A selected region waiting in the composer.
    private func addPicture(to chat: ChatController) throws {
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: ImageCodec.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let jpeg = try XCTUnwrap(ImageCodec.jpeg(try XCTUnwrap(pixels.makeImage()), quality: 0.9))
        let header = SnapshotHeader(id: UUID(), trigger: .manual, note: nil, pixelWidth: jpeg.width, pixelHeight: jpeg.height, byteCount: jpeg.data.count, chunkCount: 1, mimeType: "image/jpeg", capturedAt: Date(), captureTitle: "Display")
        chat.addToComposer(ReceivedSnapshot(header: header, data: jpeg.data, transferSeconds: 0), sourceName: "Source Mac")
    }

    private func sentImages(_ client: ScriptedClient) -> Int {
        client.requests.first?.turns.first?.parts.filter { if case .image = $0 { return true } else { return false } }.count ?? 0
    }

    func testSendIncludesTheSelectedPictures() async throws {
        let client = ScriptedClient(.reply(greeting))
        let chat = makeChat(client)
        try addPicture(to: chat)
        chat.composerText = "What does this say?"
        chat.sendFromComposer()
        await waitUntilIdle(chat)
        XCTAssertEqual(sentImages(client), 1)
        XCTAssertTrue(chat.composerAttachments.isEmpty)
    }

    func testExcludedPicturesStayInTheComposer() async throws {
        let client = ScriptedClient(.reply(greeting))
        let chat = makeChat(client)
        try addPicture(to: chat)
        chat.includesPictures = false
        chat.composerText = "Just a question"
        chat.sendFromComposer()
        await waitUntilIdle(chat)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(sentImages(client), 0)
        XCTAssertEqual(chat.composerAttachments.count, 1)
    }

    func testSkillThatSkipsPicturesLeavesThemForLater() async throws {
        let client = ScriptedClient(.reply(greeting))
        let chat = makeChat(client)
        try addPicture(to: chat)
        chat.send(skill: PromptSkill(title: "Follow-up", symbol: "ear", instructions: "Answer the last question.", attachesScreenshot: false))
        await waitUntilIdle(chat)
        XCTAssertEqual(sentImages(client), 0)
        XCTAssertEqual(chat.composerAttachments.count, 1)
    }

    func testAddingAPictureIncludesPicturesAgain() throws {
        let chat = makeChat(ScriptedClient(.reply([])))
        chat.includesPictures = false
        try addPicture(to: chat)
        XCTAssertTrue(chat.includesPictures)
    }

    private func waitUntilIdle(_ chat: ChatController, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.streaming != nil || chat.isCapturingForSend, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private var greeting: [AIStreamEvent] {
        [
            .started(model: "mock-model"),
            .reasoningDelta("Considering…"),
            .textDelta("Hi "),
            .textDelta("there!"),
            .completed(AICompletion(stopReason: .endTurn, usage: AIUsage(inputTokens: 12, outputTokens: 3), servedModel: "mock-model"))
        ]
    }

    func testSendStreamsAnAnswerIntoANewThread() async {
        let client = ScriptedClient(.reply(greeting))
        let chat = makeChat(client)
        chat.composerText = "Hello, what's up?"
        chat.sendFromComposer()
        await waitUntilIdle(chat)

        let thread = try? XCTUnwrap(chat.selectedThread)
        XCTAssertEqual(thread?.title, "Hello, what's up?")
        XCTAssertEqual(thread?.messages.count, 2)
        let answer = thread?.messages.last
        XCTAssertEqual(answer?.role, .assistant)
        XCTAssertEqual(answer?.text, "Hi there!")
        XCTAssertEqual(answer?.reasoning, "Considering…")
        XCTAssertEqual(answer?.status, .complete)
        XCTAssertEqual(answer?.usage?.outputTokens, 3)
        XCTAssertNotNil(answer?.firstTokenSeconds)
        XCTAssertEqual(chat.composerText, "")

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].model, "mock-model")
        XCTAssertEqual(client.requests[0].turns, [AITurn(role: .user, parts: [.text("Hello, what's up?")])])
    }

    func testFailureIsShownAndRetryRecovers() async {
        let client = ScriptedClient(.fail(.rateLimited(retryAfter: 3, message: "slow down")))
        let chat = makeChat(client)
        chat.composerText = "Question"
        chat.sendFromComposer()
        await waitUntilIdle(chat)
        guard case .failed(let message) = chat.selectedThread?.messages.last?.status else {
            return XCTFail("expected a failed message")
        }
        XCTAssertTrue(message.contains("Rate limited"))

        client.behavior = .reply(greeting)
        let failedID = chat.selectedThread!.messages.last!.id
        chat.retry(failedID)
        await waitUntilIdle(chat)
        XCTAssertEqual(chat.selectedThread?.messages.count, 2)
        XCTAssertEqual(chat.selectedThread?.messages.last?.text, "Hi there!")
        // The failed answer isn't replayed to the model.
        XCTAssertEqual(client.requests.last?.turns.count, 1)
    }

    func testStopKeepsPartialAnswerAsCancelled() async {
        let chunks = (0..<40).map { AIStreamEvent.textDelta("word\($0) ") }
        let client = ScriptedClient(.reply([.started(model: nil)] + chunks, delayNanos: 30_000_000))
        let chat = makeChat(client)
        chat.composerText = "Tell me a long story"
        chat.sendFromComposer()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(chat.streaming)
        chat.stop()
        await waitUntilIdle(chat)
        let answer = chat.selectedThread?.messages.last
        XCTAssertEqual(answer?.status, .cancelled)
        XCTAssertFalse(answer?.text.isEmpty ?? true)
        XCTAssertLessThan(answer?.text.count ?? 0, chunks.count * 6)
    }

    func testAskWithSnapshotSendsTheImage() async throws {
        let client = ScriptedClient(.reply(greeting))
        let chat = makeChat(client)
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: ImageCodec.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        pixels.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let jpeg = try XCTUnwrap(ImageCodec.jpeg(try XCTUnwrap(pixels.makeImage()), quality: 0.9))
        let header = SnapshotHeader(id: UUID(), trigger: .hotkey, note: "look here", pixelWidth: jpeg.width, pixelHeight: jpeg.height, byteCount: jpeg.data.count, chunkCount: 1, mimeType: "image/jpeg", capturedAt: Date(), captureTitle: "Display")
        chat.ask(prompt: "What's this?", snapshot: ReceivedSnapshot(header: header, data: jpeg.data, transferSeconds: 0), sourceName: "Source Mac", trigger: .hotkey, sourceNote: "look here")
        await waitUntilIdle(chat)

        let parts = try XCTUnwrap(client.requests.first?.turns.first?.parts)
        guard case .image(let image) = parts.first else { return XCTFail("image first") }
        XCTAssertEqual(image.width, 64)
        XCTAssertTrue(parts.contains(.text("What's this?")))
        XCTAssertTrue(parts.contains(.text("Note typed on the shared Mac: look here")))
        XCTAssertEqual(chat.selectedThread?.messages.first?.attachments.count, 1)
    }

    func testBusyAskParksSnapshotInComposer() async throws {
        let slow = ScriptedClient(.reply([.started(model: nil), .textDelta("…")], delayNanos: 400_000_000))
        let chat = makeChat(slow)
        chat.composerText = "First"
        chat.sendFromComposer()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let header = SnapshotHeader(id: UUID(), trigger: .interval, note: nil, pixelWidth: 1, pixelHeight: 1, byteCount: 3, chunkCount: 1, mimeType: "image/jpeg", capturedAt: Date(), captureTitle: nil)
        chat.ask(prompt: "Auto", snapshot: ReceivedSnapshot(header: header, data: Data([1, 2, 3]), transferSeconds: 0), sourceName: nil, trigger: .interval)
        XCTAssertEqual(chat.composerAttachments.count, 1)
        XCTAssertNotNil(chat.banner)
        await waitUntilIdle(chat)
    }

    func testThreadManagement() async {
        let chat = makeChat(ScriptedClient(.reply([])))
        let first = chat.newThread()
        XCTAssertEqual(chat.newThread(), first, "an empty thread is reused")
        chat.rename(first, to: "  Renamed  ")
        XCTAssertEqual(chat.selectedThread?.title, "Renamed")
        XCTAssertTrue(chat.selectedThread?.hasCustomTitle ?? false)
        chat.togglePin(first)
        XCTAssertTrue(chat.selectedThread?.isPinned ?? false)
        chat.deleteThread(first)
        XCTAssertTrue(chat.threads.isEmpty)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testValuesPersistAcrossInstances() {
        let defaults = UserDefaults(suiteName: "tandem.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertNil(settings.role)
        XCTAssertEqual(settings.anthropicModel, "claude-opus-5-5")
        settings.role = .studio
        settings.autoCaptureInterval = 45
        settings.liveQuality = .crisp
        settings.captureSource = CaptureSourceID(kind: .window, id: "7")
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.role, .studio)
        XCTAssertEqual(reloaded.autoCaptureInterval, 45)
        XCTAssertEqual(reloaded.liveQuality, .crisp)
        XCTAssertEqual(reloaded.captureSource, CaptureSourceID(kind: .window, id: "7"))
    }

    func testHotkeyOverrides() {
        let defaults = UserDefaults(suiteName: "tandem.tests.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.combo(for: .sendSnapshot), HotkeyAction.sendSnapshot.defaultCombo)
        settings.setCombo(nil, for: .sendSnapshot)
        XCTAssertNil(settings.combo(for: .sendSnapshot), "nil disables the shortcut")
        let custom = KeyCombo(keyCode: 0x01, modifiers: KeyCombo.carbonModifiers(from: [.command, .option]))
        settings.setCombo(custom, for: .sendSnapshot)
        XCTAssertEqual(SettingsStore(defaults: defaults).combo(for: .sendSnapshot), custom)
        settings.setCombo(HotkeyAction.sendSnapshot.defaultCombo, for: .sendSnapshot)
        XCTAssertNil(settings.hotkeyOverrides[HotkeyAction.sendSnapshot.id], "resetting to default removes the override")
    }

    func testCurrentModelFollowsProvider() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tandem.tests.\(UUID().uuidString)")!)
        settings.provider = .openAI
        XCTAssertEqual(settings.currentModel, "gpt-6-astra")
        settings.currentModel = "gpt-6-luna"
        XCTAssertEqual(settings.openAIModel, "gpt-6-luna")
        XCTAssertEqual(settings.anthropicModel, "claude-opus-5-5")
    }
}
