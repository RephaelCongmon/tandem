import AVFAudio
import Speech
import XCTest
@testable import TandemCore

final class AudioTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testContinuousAudioTracksTheClock() {
        var timeline = AudioTimeline()
        for index in 0..<50 {
            timeline.feed(sampleCount: 1_600, sampleRate: 16_000, capturedAt: t0.addingTimeInterval(Double(index) * 0.1 + 0.01))
        }
        XCTAssertEqual(timeline.fedSeconds, 5, accuracy: 1e-9)
        XCTAssertEqual(timeline.date(forAudioTime: 2.5).timeIntervalSince(t0), 2.51, accuracy: 1e-6)
    }

    func testAGapStartsANewAnchor() {
        var timeline = AudioTimeline()
        timeline.feed(sampleCount: 16_000, sampleRate: 16_000, capturedAt: t0)
        // Sharing paused for a minute, then resumed.
        timeline.feed(sampleCount: 16_000, sampleRate: 16_000, capturedAt: t0.addingTimeInterval(61))
        XCTAssertEqual(timeline.date(forAudioTime: 0.5).timeIntervalSince(t0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(timeline.date(forAudioTime: 1.5).timeIntervalSince(t0), 61.5, accuracy: 1e-6)
        timeline.reset()
        XCTAssertEqual(timeline.fedSeconds, 0)
    }

    func testTracksTheLastSound() {
        var timeline = AudioTimeline()
        timeline.feed(sampleCount: 1_600, sampleRate: 16_000, capturedAt: t0)
        timeline.feed(sampleCount: 1_600, sampleRate: 16_000, capturedAt: t0.addingTimeInterval(0.1), isSilent: true)
        XCTAssertEqual(timeline.lastSoundAt ?? -1, 0.1, accuracy: 1e-9)
    }
}

/// Runs real on-device speech recognition on a clip spoken by `say`.
final class LiveSpeechTests: XCTestCase {
    private static let sentence = "So my follow up question is, how would you handle cache invalidation if two services write to the same key?"

    /// 16 kHz mono samples of `text` spoken by the system voice.
    private func spokenSamples(_ text: String) throws -> [Int16] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0, "say isn't available")
        let file = try AVAudioFile(forReading: url)
        let target = LiveAudio.pcmFormat()
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024))
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return source
        }
        XCTAssertNil(error)
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TranscriberEvent] = []
        func add(_ event: TranscriberEvent) { lock.withLock { storage.append(event) } }
        var events: [TranscriberEvent] { lock.withLock { storage } }
    }

    private func transcribe(with transcriber: LiveSpeechTranscriber) async throws -> (finalText: String, sawVolatile: Bool) {
        let collector = Collector()
        try await transcriber.start(onEvent: { collector.add($0) }, progress: { _ in })
        let samples = try spokenSamples(Self.sentence) + [Int16](repeating: 0, count: 16_000 * 2)
        // 100 ms chunks, faster than real time.
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            transcriber.append(Array(samples[start..<min(samples.count, start + 1_600)]))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await transcriber.flush()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await transcriber.stop()
        let events = collector.events
        let finals = events.compactMap { event -> String? in if case .final(let text, _, _) = event { return text } else { return nil } }
        let sawVolatile = events.contains { if case .volatile = $0 { return true } else { return false } }
        return (finals.joined(separator: " "), sawVolatile)
    }

    func testSpeechAnalyzerTranscribesALiveStream() async throws {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { throw XCTSkip("needs macOS 26") }
        let installed = await SpeechTranscriber.installedLocales
        try XCTSkipUnless(installed.contains { $0.identifier.hasPrefix("en") }, "no English speech model installed")
        let transcriber = LiveSpeech.makeTranscriber(locale: Locale(identifier: "en-US"))
        XCTAssertEqual(transcriber.engineName, "SpeechAnalyzer")
        let result = try await transcribe(with: transcriber)
        let text = result.finalText.lowercased()
        XCTAssertTrue(result.sawVolatile, "words arrive while they're still being spoken")
        for word in ["follow", "question", "invalidation", "services", "same key"] {
            XCTAssertTrue(text.contains(word), "\(word) missing from: \(text)")
        }
    }

    func testRecognizerFallbackTranscribesALiveStream() async throws {
        // Asking for permission from a test runner would crash it (no usage description), so this
        // only runs where the permission was already granted.
        try XCTSkipUnless(SFSpeechRecognizer.authorizationStatus() == .authorized, "Speech Recognition permission not granted to the test runner")
        let transcriber = LiveSpeech.makeTranscriber(locale: Locale(identifier: "en-US"), preferLegacy: true)
        XCTAssertEqual(transcriber.engineName, "SFSpeechRecognizer")
        let result = try await transcribe(with: transcriber)
        XCTAssertTrue(result.finalText.lowercased().contains("question"), result.finalText)
    }

    func testUnsupportedLanguageIsExplained() async throws {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { throw XCTSkip("needs macOS 26") }
        let transcriber = LiveSpeech.makeTranscriber(locale: Locale(identifier: "tlh"))
        do {
            try await transcriber.start(onEvent: { _ in }, progress: { _ in })
            XCTFail("Klingon isn't a supported language")
        } catch TranscriberError.unsupportedLocale {}
    }
}
