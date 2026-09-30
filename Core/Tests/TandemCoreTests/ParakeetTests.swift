import AVFAudio
import XCTest
@testable import TandemCore

final class UtteranceSegmenterTests: XCTestCase {
    private let rate = 16_000.0

    /// `seconds` of a voice-like tone, or silence with a little noise.
    private func audio(_ seconds: Double, speech: Bool) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { index in
            speech ? Float(0.3 * sin(Double(index) * 2 * .pi * 220 / rate)) : Float.random(in: -0.0005...0.0005)
        }
    }

    /// Feeds audio in 100 ms pieces, like the link delivers it.
    private func feed(_ samples: [Float], into segmenter: inout UtteranceSegmenter) -> [UtteranceSegmenter.Action] {
        stride(from: 0, to: samples.count, by: 1_600).flatMap { start in
            segmenter.append(Array(samples[start..<min(samples.count, start + 1_600)]))
        }
    }

    private func finals(_ actions: [UtteranceSegmenter.Action]) -> [(start: Double, end: Double, count: Int)] {
        actions.compactMap { if case .final(let samples, let start, let end) = $0 { return (start, end, samples.count) } else { return nil } }
    }

    private func lives(_ actions: [UtteranceSegmenter.Action]) -> [Double] {
        actions.compactMap { if case .live(_, _, let end) = $0 { return end } else { return nil } }
    }

    func testSilenceProducesNothing() {
        var segmenter = UtteranceSegmenter()
        XCTAssertTrue(feed(audio(5, speech: false), into: &segmenter).isEmpty)
        XCTAssertEqual(segmenter.time, 5, accuracy: 0.001)
        XCTAssertTrue(segmenter.flush().isEmpty)
    }

    func testSpeechIsCaptionedWhileSpokenAndFinishedAtThePause() throws {
        var segmenter = UtteranceSegmenter()
        let actions = feed(audio(1, speech: false) + audio(3, speech: true) + audio(1.5, speech: false), into: &segmenter)
        // Live passes about every 0.8 s while speaking.
        let live = lives(actions)
        XCTAssertGreaterThanOrEqual(live.count, 3)
        XCTAssertLessThan(try XCTUnwrap(live.first) - 1, 1.2, "the first words show within about a second")
        let final = try XCTUnwrap(finals(actions).first)
        XCTAssertEqual(finals(actions).count, 1)
        XCTAssertEqual(final.start, 0.7, accuracy: 0.05, "starts with 0.3 s of pre-roll")
        XCTAssertEqual(final.end, 4.2, accuracy: 0.05, "keeps 0.2 s after the speech")
        XCTAssertFalse(segmenter.isInUtterance)
    }

    func testLongSpeechIsCutBeforeTheModelsLimit() {
        var segmenter = UtteranceSegmenter()
        // 16 s of talk with a slight dip at 12.5 s, then a pause.
        var talk = audio(12.5, speech: true)
        talk += audio(0.04, speech: true).map { $0 * 0.2 }
        talk += audio(3.5, speech: true)
        let actions = feed(talk + audio(1, speech: false), into: &segmenter)
        let parts = finals(actions)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { Double($0.count) / rate <= 14.01 })
        XCTAssertEqual(parts[0].end, parts[1].start, accuracy: 0.001, "no audio lost between the parts")
        XCTAssertEqual(parts[0].end, 12.5, accuracy: 0.1, "cut in the quiet moment")
    }

    func testAClickIsDiscarded() {
        var segmenter = UtteranceSegmenter()
        let actions = feed(audio(1, speech: false) + audio(0.1, speech: true) + audio(1, speech: false), into: &segmenter)
        XCTAssertEqual(actions, [.discard])
    }

    func testFlushFinishesMidUtterance() {
        var segmenter = UtteranceSegmenter()
        _ = feed(audio(0.5, speech: false) + audio(1.2, speech: true), into: &segmenter)
        XCTAssertTrue(segmenter.isInUtterance)
        XCTAssertEqual(finals(segmenter.flush()).count, 1)
        XCTAssertFalse(segmenter.isInUtterance)
    }

    func testSteadyBackgroundNoiseIsNotSpeech() {
        var segmenter = UtteranceSegmenter()
        // Constant hum well below speech: the noise floor rises to meet it.
        let hum = (0..<Int(20 * rate)).map { Float(0.004 * sin(Double($0) * 2 * .pi * 60 / rate)) }
        let actions = feed(hum, into: &segmenter)
        XCTAssertTrue(finals(actions).isEmpty)
    }
}

/// Real Parakeet transcription. Uses a model folder from `TANDEM_PARAKEET_MODELS` (the folder
/// that contains `parakeet-tdt-0.6b-v2`) and never downloads the 450 MB model itself.
final class ParakeetLiveTests: XCTestCase {
    private func modelStore() throws -> ParakeetModelStore {
        guard let path = ProcessInfo.processInfo.environment["TANDEM_PARAKEET_MODELS"] else {
            throw XCTSkip("set TANDEM_PARAKEET_MODELS to a folder containing parakeet-tdt-0.6b-v2")
        }
        let store = ParakeetModelStore(modelsDirectory: URL(fileURLWithPath: path), mirror: nil)
        try XCTSkipUnless(store.isInstalled, "no Parakeet model in \(path)")
        return store
    }

    private func spoken(_ text: String) throws -> [Int16] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        try say.run()
        say.waitUntilExit()
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
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [TranscriberEvent] = []
        func add(_ event: TranscriberEvent) { lock.withLock { items.append(event) } }
        var all: [TranscriberEvent] { lock.withLock { items } }
    }

    func testParakeetTranscribesALiveStream() async throws {
        let transcriber = LiveSpeech.makeTranscriber(locale: Locale(identifier: "en-US"), engine: .parakeet, parakeet: try modelStore())
        XCTAssertEqual(transcriber.engineName, "Parakeet")
        let events = Events()
        try await transcriber.start(onEvent: { events.add($0) }, progress: { _ in })
        let samples = [Int16](repeating: 0, count: 8_000)
            + (try spoken("So my follow up question is, how would you handle cache invalidation if two services write to the same key?"))
            + [Int16](repeating: 0, count: 24_000)
            + (try spoken("And then, what's the difference between optimistic and pessimistic locking?"))
            + [Int16](repeating: 0, count: 24_000)
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            transcriber.append(Array(samples[start..<min(samples.count, start + 1_600)]))
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        await transcriber.flush()
        await transcriber.stop()
        let finals = events.all.compactMap { if case .final(let text, _, _) = $0 { return text } else { return nil } }
        let volatile = events.all.filter { if case .volatile(let text, _, _) = $0 { return !text.isEmpty } else { return false } }
        XCTAssertFalse(volatile.isEmpty, "live captions while speaking")
        XCTAssertEqual(finals.count, 2, "one segment per sentence: \(finals)")
        let text = finals.joined(separator: " ").lowercased()
        for phrase in ["follow", "invalidation", "same key", "optimistic", "pessimistic locking"] {
            XCTAssertTrue(text.contains(phrase), "\(phrase) missing from: \(text)")
        }
    }
}

/// Downloads the model from Hugging Face when Tandem's mirror isn't reachable (450 MB, so only
/// with `TANDEM_PARAKEET_DOWNLOAD_TEST=1`).
final class ParakeetDownloadTests: XCTestCase {
    func testFallsBackToHuggingFaceWhenTheMirrorFails() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TANDEM_PARAKEET_DOWNLOAD_TEST"] == "1", "downloads 450 MB")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ParakeetModelStore(modelsDirectory: folder) { _, _ in throw UpdateError.accessDenied("no GitHub access") }
        XCTAssertFalse(store.isInstalled)
        final class Last: @unchecked Sendable { var value = 0.0 }
        let last = Last()
        try await store.install { last.value = $0 }
        XCTAssertTrue(store.isInstalled)
        XCTAssertGreaterThan(last.value, 0.9)
        XCTAssertEqual(store.directory.lastPathComponent, ParakeetModelStore.folderName)
    }
}
