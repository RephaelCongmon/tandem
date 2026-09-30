import AVFAudio
import CoreMedia
import Foundation
import os
import Speech

/// What a live transcriber reports. Times are seconds of audio since the transcriber started.
public enum TranscriberEvent: Sendable, Equatable {
    /// The newest words so far; replaced by the next volatile or final result.
    case volatile(text: String, start: Double, end: Double)
    case final(text: String, start: Double, end: Double)
    /// Transcription stopped and needs a restart.
    case failed(String)
}

public enum TranscriberError: Error, LocalizedError, Equatable {
    case unsupportedLocale(String)
    case unavailable(String)
    case permissionDenied
    case modelDownloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let name):
            return "Live transcription doesn't support \(name) on this Mac. Choose another language in Settings › Listening."
        case .unavailable(let reason):
            return reason
        case .permissionDenied:
            return "Tandem needs Speech Recognition permission to transcribe. Turn it on in System Settings › Privacy & Security › Speech Recognition."
        case .modelDownloadFailed(let reason):
            return "Couldn't download the speech model: \(reason)"
        }
    }
}

/// On-device speech-to-text for a live stream of 16 kHz mono samples.
public protocol LiveSpeechTranscriber: AnyObject, Sendable {
    /// Loads (downloading if needed) the model and starts listening. `progress` reports a
    /// model download, 0…1.
    func start(onEvent: @escaping @Sendable (TranscriberEvent) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Feeds samples. Call from one queue at a time.
    func append(_ samples: [Int16])
    /// Finishes the words still being recognized (e.g. after the audio paused).
    func flush() async
    func stop() async
    /// A short name for logs and settings ("SpeechAnalyzer", "SFSpeechRecognizer").
    var engineName: String { get }
}

/// Which recognizer transcribes the shared Mac's audio.
public enum SpeechEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    /// NVIDIA Parakeet TDT 0.6B v2 (English), downloaded once (about 450 MB).
    case parakeet
    /// Apple's built-in recognizer (SpeechAnalyzer on macOS 26, SFSpeechRecognizer before).
    case apple

    public var id: String { rawValue }
}

public enum LiveSpeech {
    /// A transcriber for `locale`: Parakeet when chosen and the language is English, otherwise
    /// Apple's SpeechAnalyzer on macOS 26 and later (long-form, fully on-device), otherwise
    /// SFSpeechRecognizer.
    public static func makeTranscriber(
        locale: Locale,
        engine: SpeechEngine = .apple,
        parakeet: ParakeetModelStore? = nil,
        preferLegacy: Bool = false
    ) -> LiveSpeechTranscriber {
        if engine == .parakeet, let parakeet, parakeetSupports(locale) {
            return ParakeetTranscriber(store: parakeet)
        }
        if #available(macOS 26.0, *), !preferLegacy, SpeechTranscriber.isAvailable {
            return AnalyzerTranscriber(locale: locale)
        }
        return RecognizerTranscriber(locale: locale)
    }

    /// Parakeet v2 is English-only.
    public static func parakeetSupports(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "en"
    }

    /// Languages live transcription can use on this Mac, by identifier.
    public static func supportedLocales() async -> [Locale] {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            return await SpeechTranscriber.supportedLocales
        }
        return Array(SFSpeechRecognizer.supportedLocales())
    }

    static func buffer(_ samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            buffer.int16ChannelData![0].update(from: base, count: samples.count)
        }
        return buffer
    }
}

// MARK: - SpeechAnalyzer (macOS 26)

@available(macOS 26.0, *)
final class AnalyzerTranscriber: LiveSpeechTranscriber, @unchecked Sendable {
    let engineName = "SpeechAnalyzer"
    private let locale: Locale
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var inputFormat = LiveAudio.pcmFormat()
    private var converter: AVAudioConverter?
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Speech")

    init(locale: Locale) {
        self.locale = locale
    }

    func start(onEvent: @escaping @Sendable (TranscriberEvent) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        if await AssetInventory.status(forModules: [transcriber]) < .installed {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { item, _ in
                        progress(item.fractionCompleted)
                    }
                    defer { observation.invalidate() }
                    try await request.downloadAndInstall()
                }
            } catch {
                throw TranscriberError.modelDownloadFailed(error.localizedDescription)
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.unavailable("This Mac's speech model can't read live audio.")
        }
        let native = LiveAudio.pcmFormat()
        let converter = format == native ? nil : AVAudioConverter(from: native, to: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let log = self.log
        let results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let start = result.range.start.seconds
                    let end = CMTimeRangeGetEnd(result.range).seconds
                    guard start.isFinite, end.isFinite else { continue }
                    onEvent(result.isFinal ? .final(text: text, start: start, end: end) : .volatile(text: text, start: start, end: end))
                }
            } catch is CancellationError {
            } catch {
                log.error("Transcription stopped: \(error.localizedDescription, privacy: .public)")
                onEvent(.failed(error.localizedDescription))
            }
        }
        try await analyzer.start(inputSequence: stream)
        lock.withLock {
            self.analyzer = analyzer
            self.input = continuation
            self.resultsTask = results
            self.inputFormat = format
            self.converter = converter
        }
        log.info("SpeechAnalyzer listening (\(supported.identifier, privacy: .public), \(format.description, privacy: .public))")
    }

    func append(_ samples: [Int16]) {
        let (input, converter, format) = lock.withLock { (self.input, self.converter, self.inputFormat) }
        guard let input, !samples.isEmpty, let native = LiveSpeech.buffer(samples, format: LiveAudio.pcmFormat()) else { return }
        guard let converter else {
            input.yield(AnalyzerInput(buffer: native))
            return
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / Double(LiveAudio.sampleRate)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return native
        }
        if error == nil, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
    }

    func flush() async {
        guard let analyzer = lock.withLock({ self.analyzer }) else { return }
        try? await analyzer.finalize(through: nil)
    }

    func stop() async {
        let (analyzer, input, results) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?) in
            defer {
                self.analyzer = nil
                self.input = nil
                self.resultsTask = nil
            }
            return (self.analyzer, self.input, self.resultsTask)
        }
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
    }
}

// MARK: - SFSpeechRecognizer (macOS 14 and 15)

/// Live transcription with `SFSpeechRecognizer`. One recognition request covers one stretch of
/// speech; a pause (or 50 seconds) ends it and the next words start a new one, which keeps
/// requests inside the recognizer's limits and turns pauses into finished segments.
final class RecognizerTranscriber: LiveSpeechTranscriber, @unchecked Sendable {
    let engineName = "SFSpeechRecognizer"
    private let locale: Locale
    private let queue = DispatchQueue(label: "tandem.speech.recognizer", qos: .userInitiated)
    private var recognizer: SFSpeechRecognizer?
    private var onEvent: (@Sendable (TranscriberEvent) -> Void)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var requestID = 0
    private var requestStart = 0.0
    private var fedSamples = 0
    private var lastPartial = ""
    private var lastChange = 0.0
    private var stopped = false
    private let format = LiveAudio.pcmFormat()

    static let pauseToFinish = 1.2
    static let maxRequestSeconds = 50.0

    init(locale: Locale) {
        self.locale = locale
    }

    private var audioTime: Double { Double(fedSamples) / Double(LiveAudio.sampleRate) }

    func start(onEvent: @escaping @Sendable (TranscriberEvent) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw TranscriberError.permissionDenied }
        default:
            throw TranscriberError.permissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriberError.unsupportedLocale(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw TranscriberError.unavailable("Speech recognition isn't available right now.")
        }
        progress(1)
        queue.sync {
            self.recognizer = recognizer
            self.onEvent = onEvent
            self.stopped = false
        }
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty, let buffer = LiveSpeech.buffer(samples, format: format) else { return }
        queue.async { [self] in
            guard !stopped, recognizer != nil else { return }
            if request == nil { beginRequest() }
            request?.append(buffer)
            fedSamples += samples.count
            let now = audioTime
            if !lastPartial.isEmpty, now - lastChange > Self.pauseToFinish {
                endRequest()
            } else if now - requestStart > Self.maxRequestSeconds {
                endRequest()
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                endRequest()
                continuation.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                stopped = true
                endRequest()
                task = nil
                onEvent = nil
                continuation.resume()
            }
        }
    }

    private func beginRequest() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        requestID += 1
        let id = requestID
        let start = audioTime
        requestStart = start
        lastPartial = ""
        lastChange = start
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.queue.async { self?.handle(result: result, error: error, requestID: id, start: start) }
        }
    }

    /// Ends the current request; its final result arrives later.
    private func endRequest() {
        guard let request else { return }
        if lastPartial.isEmpty {
            task?.cancel()
        } else {
            request.endAudio()
        }
        self.request = nil
        lastPartial = ""
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, requestID id: Int, start: Double) {
        guard let onEvent else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            let segments = result.bestTranscription.segments
            let first = start + (segments.first?.timestamp ?? 0)
            let last = start + (segments.last.map { $0.timestamp + $0.duration } ?? 0)
            if result.isFinal {
                onEvent(.final(text: text, start: first, end: max(first, last)))
            } else if id == requestID, request != nil {
                if text != lastPartial {
                    lastPartial = text
                    lastChange = audioTime
                }
                onEvent(.volatile(text: text, start: first, end: max(first, last)))
            }
        } else if let error = error as NSError?, id == requestID, request != nil {
            // "No speech detected" and cancellations just end the request; the next audio starts another.
            let benign = error.domain == "kAFAssistantErrorDomain" && [203, 216, 1110].contains(error.code)
            request = nil
            lastPartial = ""
            if !benign { onEvent(.failed(error.localizedDescription)) }
        }
    }
}
