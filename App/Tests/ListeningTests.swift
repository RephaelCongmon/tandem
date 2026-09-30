import AVFoundation
import CoreMedia
import TandemCore
import XCTest
@testable import Tandem

/// Converting ScreenCaptureKit's audio buffers into the 16 kHz samples that go on the wire.
final class AudioCaptureConversionTests: XCTestCase {
    private func sampleBuffer(_ buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription, sampleCount: CMItemCount(buffer.frameLength),
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample
        )
        XCTAssertEqual(status, noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buffer.audioBufferList), noErr)
        return result
    }

    func testScreenCaptureKitsMonoFloatIsConvertedDirectly() throws {
        // What ScreenCaptureKit delivers with sampleRate 16 000 and one channel: 20 ms of float.
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        for index in 0..<320 { buffer.floatChannelData![0][index] = Float(index % 3) * 0.25 - 0.25 }
        let samples = try XCTUnwrap(AudioCaptureService().samples(from: sampleBuffer(buffer)))
        XCTAssertEqual(samples.count, 320)
        XCTAssertEqual(Array(samples.prefix(3)), [-8192, 0, 8192])
    }

    func testOtherFormatsAreResampledToSixteenKilohertzMono() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for index in 0..<4_800 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000) * 0.5) }
        }
        let service = AudioCaptureService()
        var total = 0
        // A converter keeps some samples back at first; over several buffers it catches up.
        for _ in 0..<5 { total += try service.samples(from: sampleBuffer(buffer))?.count ?? 0 }
        XCTAssertEqual(Double(total), 8_000, accuracy: 400, "5 × 100 ms at 16 kHz")
    }
}

/// Questions carry what was said on the shared Mac since the thread's previous question.
@MainActor
final class TranscriptAttachmentTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func make() -> (ChatController, TranscriptionService, SettingsStore, ScriptedClient) {
        let client = ScriptedClient(.reply([.textDelta("Answer."), .completed(AICompletion(stopReason: .endTurn))]))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tandem.tests.\(UUID().uuidString)")!)
        settings.provider = .openAICompatible
        settings.customModel = "mock-model"
        settings.customBaseURL = "http://127.0.0.1:9/v1/"
        settings.listen = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let chat = ChatController(
            settings: settings,
            keys: APIKeyStore(servicePrefix: "com.rofel.tandem.tests.\(UUID().uuidString)"),
            threadStore: ThreadStore(directory: directory, coalesceInterval: 0.01),
            snapshots: SnapshotStore(directory: nil, keepOnDisk: false),
            clientFactory: { _ in client }
        )
        let transcription = TranscriptionService(settings: settings)
        chat.transcription = transcription
        return (chat, transcription, settings, client)
    }

    private func said(_ text: String, _ transcription: TranscriptionService, secondsAgo: Double) {
        let end = Date().addingTimeInterval(-secondsAgo)
        transcription.apply(.final(text: text, start: 0, end: 0), start: end.addingTimeInterval(-2), end: end)
    }

    private func waitUntilIdle(_ chat: ChatController) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, chat.isBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func lastTurnText(_ request: AIRequest?) -> String {
        request?.turns.last?.parts.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(separator: "\n") ?? ""
    }

    func testFollowUpCarriesTheSpokenQuestionAndOnlyNewSpeechAfterwards() async throws {
        let (chat, transcription, _, client) = make()
        let followUp = PromptSkill.defaults[2]

        said("Thanks for walking us through the design.", transcription, secondsAgo: 30)
        said("How would you handle cache invalidation?", transcription, secondsAgo: 5)
        chat.send(skill: followUp)
        await waitUntilIdle(chat)

        let first = try XCTUnwrap(chat.selectedThread?.messages.first)
        XCTAssertEqual(first.transcript?.segments.map(\.text), ["Thanks for walking us through the design.", "How would you handle cache invalidation?"])
        let sent = lastTurnText(client.requests.first)
        XCTAssertTrue(sent.contains("Live transcript of the computer audio"))
        XCTAssertTrue(sent.contains("How would you handle cache invalidation?"))
        XCTAssertTrue(sent.hasSuffix(followUp.instructions))
        XCTAssertEqual(client.requests.first?.conversation?.messageIDs, [first.id])

        said("And what about two writers at once?", transcription, secondsAgo: 1)
        chat.send(skill: followUp)
        await waitUntilIdle(chat)
        let messages = try XCTUnwrap(chat.selectedThread?.messages)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[2].transcript?.segments.map(\.text), ["And what about two writers at once?"], "only what's new since the last question")
        XCTAssertEqual(client.requests.last?.conversation?.messageIDs, [messages[0].id, messages[1].id, messages[2].id])
        XCTAssertEqual(client.requests.last?.conversation?.replyID, messages[3].id)
    }

    func testNothingIsAttachedWhenNotListeningOrTurnedOff() async throws {
        let (chat, transcription, settings, _) = make()
        said("Something was said.", transcription, secondsAgo: 2)

        settings.includeTranscript = false
        chat.composerText = "One"
        chat.sendFromComposer()
        await waitUntilIdle(chat)
        XCTAssertNil(chat.selectedThread?.messages.last(where: { $0.role == .user })?.transcript)

        settings.includeTranscript = true
        var screenOnly = PromptSkill.defaults[0]
        screenOnly.attachesTranscript = false
        chat.send(skill: screenOnly)
        await waitUntilIdle(chat)
        XCTAssertNil(chat.selectedThread?.messages.last(where: { $0.role == .user })?.transcript)

        settings.listen = false
        chat.composerText = "Three"
        chat.sendFromComposer()
        await waitUntilIdle(chat)
        XCTAssertNil(chat.selectedThread?.messages.last(where: { $0.role == .user })?.transcript)

        settings.listen = true
        chat.composerText = "Four"
        chat.sendFromComposer()
        await waitUntilIdle(chat)
        XCTAssertEqual(chat.selectedThread?.messages.last(where: { $0.role == .user })?.transcript?.segments.map(\.text), ["Something was said."])
    }

    func testWindowLimitsHowFarBackTheFirstExcerptGoes() async throws {
        let (chat, transcription, settings, _) = make()
        settings.transcriptWindowMinutes = 2
        said("Long ago.", transcription, secondsAgo: 600)
        said("Just now.", transcription, secondsAgo: 3)
        chat.composerText = "What was said?"
        chat.sendFromComposer()
        await waitUntilIdle(chat)
        let transcript = try XCTUnwrap(chat.selectedThread?.messages.first?.transcript)
        XCTAssertEqual(transcript.segments.map(\.text), ["Just now."])
        XCTAssertTrue(transcript.omitsEarlierSpeech)
    }
}
