import Foundation
import Observation
import os
import TandemCore

/// Live transcript of the shared Mac's computer audio: the Source sends Opus packets, and this
/// Mac decodes them and transcribes them on-device as they arrive. New words show up about a
/// second after they're spoken.
@MainActor
@Observable
final class TranscriptionService {
    enum EngineState: Equatable {
        case off
        case preparing
        /// Downloading the speech model (0…1).
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var engineState: EngineState = .off
    private(set) var transcript = LiveTranscript()
    /// Loudness of the incoming audio for the meter, 0…1.
    private(set) var level: Double = 0
    /// When the last audio packet arrived (this Mac's clock).
    private(set) var lastAudioAt: Date?
    private(set) var engineName: String?

    var isEnabled: Bool { settings.listen }
    var isReady: Bool { engineState == .ready }

    /// Audio arrived in the last couple of seconds.
    func isReceivingAudio(now: Date = Date()) -> Bool {
        guard let lastAudioAt else { return false }
        return now.timeIntervalSince(lastAudioAt) < 2
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored nonisolated let pipeline = AudioPipeline()
    @ObservationIgnored private var engine: LiveSpeechTranscriber?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var engineGeneration = 0
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var flushedForGap = false
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Transcript")

    init(settings: SettingsStore) {
        self.settings = settings
        pipeline.onLevel = { [weak self] level in
            onMain {
                guard let self else { return }
                self.level = level
                self.lastAudioAt = Date()
                self.flushedForGap = false
            }
        }
        pipeline.onEvent = { [weak self] event, start, end in
            onMain { self?.apply(event, start: start, end: end) }
        }
    }

    // MARK: Lifecycle

    /// Turns listening on or off (the setting persists).
    func setEnabled(_ enabled: Bool) {
        settings.listen = enabled
        if enabled { startEngine() } else { stopEngine() }
    }

    /// Starts the recognizer if listening is on (call at launch and after role changes).
    func resume() {
        if settings.listen, engine == nil, engineTask == nil { startEngine() }
    }

    func suspend() {
        stopEngine()
    }

    /// The language changed: reload the recognizer.
    func restart() {
        guard settings.listen else { return }
        stopEngine()
        startEngine()
    }

    func clear() {
        transcript.removeAll()
    }

    private func startEngine() {
        guard engine == nil, engineTask == nil else { return }
        engineGeneration += 1
        let generation = engineGeneration
        let locale = settings.transcriptLanguage.isEmpty ? Locale.current : Locale(identifier: settings.transcriptLanguage)
        let transcriber = LiveSpeech.makeTranscriber(locale: locale, preferLegacy: AppEnvironment.preferLegacySpeech)
        engineName = transcriber.engineName
        engineState = .preparing
        let pipeline = self.pipeline
        engineTask = Task { [weak self] in
            do {
                try await transcriber.start(onEvent: { event in
                    pipeline.deliver(event)
                }, progress: { fraction in
                    onMain {
                        guard let self, self.engineGeneration == generation, fraction < 1 else { return }
                        self.engineState = .downloading(fraction)
                    }
                })
                guard let self, self.engineGeneration == generation else {
                    await transcriber.stop()
                    return
                }
                self.engine = transcriber
                self.engineTask = nil
                self.engineState = .ready
                self.restartAttempts = 0
                pipeline.attach(transcriber)
                self.startHeartbeat()
                self.log.info("Listening with \(transcriber.engineName, privacy: .public) (\(locale.identifier, privacy: .public))")
            } catch {
                guard let self, self.engineGeneration == generation else { return }
                self.engineTask = nil
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.engineState = .failed(message)
                self.log.error("Transcription couldn't start: \(message, privacy: .public)")
            }
        }
    }

    private func stopEngine() {
        engineGeneration += 1
        engineTask?.cancel()
        engineTask = nil
        heartbeat?.invalidate()
        heartbeat = nil
        pipeline.attach(nil)
        transcript.clearVolatile()
        level = 0
        engineState = .off
        if let engine {
            self.engine = nil
            Task { await engine.stop() }
        }
    }

    /// Recognizer failures restart it a few times before giving up.
    private func engineFailed(_ message: String) {
        log.error("Transcription stopped: \(message, privacy: .public)")
        stopEngine()
        restartAttempts += 1
        guard restartAttempts <= 3, settings.listen else {
            engineState = .failed(message)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.restartAttempts ?? 1) * 1_000_000_000)
            guard let self, self.settings.listen, self.engine == nil else { return }
            self.startEngine()
        }
    }

    /// Finishes pending words once audio pauses, and lets the meter fall back when it stops.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let last = self.lastAudioAt, Date().timeIntervalSince(last) > 1.2 else { return }
                self.level = 0
                if !self.flushedForGap, self.transcript.volatile != nil, let engine = self.engine {
                    self.flushedForGap = true
                    Task { await engine.flush() }
                }
            }
        }
    }

    /// A recognizer result, already mapped to dates (internal for tests).
    func apply(_ event: TranscriberEvent, start: Date, end: Date) {
        switch event {
        case .volatile(let text, _, _):
            transcript.updateVolatile(text, start: start, end: end)
        case .final(let text, _, _):
            transcript.commit(text, start: start, end: end)
        case .failed(let message):
            engineFailed(message)
        }
    }

    // MARK: For questions

    /// Waits (briefly) until the recognizer has caught up with the newest speech, so a question
    /// asked out loud a moment ago is complete when it's sent.
    func waitForLatestWords(timeout: TimeInterval = 0.8) async {
        guard isReady, isReceivingAudio() else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !pipeline.isCaughtUp {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The speech since `after` (within the configured window) to send with a question.
    func excerpt(after: Date?, sourceName: String?) -> TranscriptExcerpt? {
        guard settings.includeTranscript else { return nil }
        return transcript.excerpt(
            after: after,
            window: TimeInterval(max(1, settings.transcriptWindowMinutes) * 60),
            sourceName: sourceName
        )
    }
}

/// Decodes, evens out and transcribes audio packets off the main thread, and maps the
/// recognizer's audio time back to wall-clock time. Confined to `queue`.
final class AudioPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "tandem.audio.transcribe", qos: .userInitiated)
    var onLevel: ((Double) -> Void)?
    var onEvent: ((TranscriberEvent, Date, Date) -> Void)?

    private var decoders: [LiveAudioCodec: AudioFrameDecoder] = [:]
    private var normalizer = AudioGainNormalizer()
    private var timeline = AudioTimeline()
    private var transcriber: LiveSpeechTranscriber?
    private var lastLevelPost = 0.0
    private var peakSinceLevelPost = -120.0
    private var lastResultEnd = 0.0
    private let caughtUp = Locked(true)

    /// Silence below this (dBFS) doesn't count as speech for "caught up".
    static let speechFloor = -50.0

    func attach(_ transcriber: LiveSpeechTranscriber?) {
        queue.async {
            self.transcriber = transcriber
            self.timeline.reset()
            self.lastResultEnd = 0
            self.normalizer = AudioGainNormalizer()
            self.caughtUp.value = true
        }
    }

    /// Link queue: a packet from the Source. `capturedAt` is on this Mac's clock.
    func receive(_ packet: AudioPacket, capturedAt: Date) {
        queue.async { self.process(packet, capturedAt: capturedAt) }
    }

    private func process(_ packet: AudioPacket, capturedAt: Date) {
        // The recognizer is fed 16 kHz; that's all a Source sends.
        guard packet.sampleRate == LiveAudio.sampleRate else { return }
        if decoders[packet.codec] == nil || decoders[packet.codec]?.sampleRate != packet.sampleRate {
            decoders[packet.codec] = AudioFrameDecoder(codec: packet.codec, sampleRate: packet.sampleRate)
        }
        guard let decoder = decoders[packet.codec] else { return }
        var samples = decoder.decode(packet)
        guard !samples.isEmpty else { return }
        let decibels = AudioLevel.rmsDecibels(samples)
        peakSinceLevelPost = max(peakSinceLevelPost, decibels)
        let now = monotonicSeconds()
        if now - lastLevelPost > 0.1 {
            onLevel?(AudioLevel.meterValue(decibels: peakSinceLevelPost))
            lastLevelPost = now
            peakSinceLevelPost = -120
        }
        guard let transcriber else { return }
        samples = normalizer.process(samples)
        timeline.feed(sampleCount: samples.count, sampleRate: LiveAudio.sampleRate, capturedAt: capturedAt, isSilent: decibels < Self.speechFloor)
        updateCaughtUp()
        transcriber.append(samples)
    }

    /// Any thread: a recognizer result, mapped to dates and handed on in order.
    func deliver(_ event: TranscriberEvent) {
        queue.async {
            switch event {
            case .volatile(_, let start, let end), .final(_, let start, let end):
                self.lastResultEnd = max(self.lastResultEnd, end)
                self.updateCaughtUp()
                self.onEvent?(event, self.timeline.date(forAudioTime: start), self.timeline.date(forAudioTime: end))
            case .failed:
                self.onEvent?(event, Date(), Date())
            }
        }
    }

    private func updateCaughtUp() {
        guard let sound = timeline.lastSoundAt else {
            caughtUp.value = true
            return
        }
        caughtUp.value = lastResultEnd >= sound - 0.35 || timeline.fedSeconds - sound > 2.5
    }

    /// The recognizer has reported on everything up to the newest speech.
    var isCaughtUp: Bool { caughtUp.value }
}
