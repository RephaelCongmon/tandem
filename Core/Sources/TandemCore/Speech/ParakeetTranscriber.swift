import FluidAudio
import Foundation
import os

/// Where the Parakeet model lives on this Mac, and how it gets there: first from Tandem's own
/// release mirror (a pinned copy), otherwise from FluidAudio's Hugging Face repository.
public actor ParakeetModelStore {
    /// Downloads the model folder's contents into `destination`, reporting 0…1. Supplied by the
    /// app (it reaches Tandem's GitHub releases); throwing falls back to Hugging Face.
    public typealias MirrorDownload = @Sendable (_ destination: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void

    public static let folderName = "parakeet-tdt-0.6b-v2"

    /// Tandem's pinned copy of the model: a pre-release in the app's own repository, so every
    /// build loads exactly the files it was tested with (and a network that blocks Hugging Face
    /// still works).
    public enum Mirror {
        public static let releaseTag = "speech-models-1"
        public static let assetName = "parakeet-tdt-0.6b-v2.zip"
        public static let sha256 = "610d51b46bbaf1244fb8134a75915734e2bf9f7cb531c7b04cc1f73547cdfcdd"
        /// Download size in bytes.
        public static let size = 451_022_288
    }

    /// The model folder (`…/parakeet-tdt-0.6b-v2`).
    public nonisolated let directory: URL
    private let mirror: MirrorDownload?
    private var installing: Task<Void, Error>?
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Speech")

    public init(modelsDirectory: URL, mirror: MirrorDownload?) {
        directory = modelsDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        self.mirror = mirror
    }

    public nonisolated var isInstalled: Bool {
        AsrModels.modelsExist(at: directory, version: .v2)
    }

    /// Makes sure the model is on disk. Concurrent callers share one download.
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled { return }
        if let installing { return try await installing.value }
        let task = Task { [directory, mirror, log] in
            let parent = directory.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if let mirror {
                let staging = parent.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                do {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    try await mirror(staging, progress)
                    // The archive holds the model folder itself, or just its contents.
                    let nested = staging.appendingPathComponent(Self.folderName, isDirectory: true)
                    let staged = FileManager.default.fileExists(atPath: nested.path) ? nested : staging
                    guard AsrModels.modelsExist(at: staged, version: .v2) else { throw TranscriberError.modelDownloadFailed("the download was incomplete") }
                    try? FileManager.default.removeItem(at: directory)
                    try FileManager.default.moveItem(at: staged, to: directory)
                    log.info("Speech model installed from Tandem's releases")
                    return
                } catch {
                    log.error("Tandem's model mirror failed (\(error.localizedDescription, privacy: .public)); trying Hugging Face")
                }
            }
            do {
                try await AsrModels.download(to: directory, version: .v2) { update in progress(update.fractionCompleted) }
            } catch {
                throw TranscriberError.modelDownloadFailed(error.localizedDescription)
            }
            guard AsrModels.modelsExist(at: directory, version: .v2) else { throw TranscriberError.modelDownloadFailed("the download was incomplete") }
            log.info("Speech model installed from Hugging Face")
        }
        installing = task
        defer { installing = nil }
        try await task.value
    }

    /// Loads the model once and runs a short pass, so Core ML compiles it for this Mac's Neural
    /// Engine now (it caches the result) rather than when someone turns on Listen.
    public func warmUp() async {
        guard isInstalled else { return }
        let started = Date()
        do {
            let models = try await AsrModels.load(from: directory, version: .v2)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            var state = try TdtDecoderState()
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            await manager.cleanup()
            log.info("Speech model warmed up in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
        } catch {
            log.error("Couldn't warm up the speech model: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the model (Settings › Listening).
    public func remove() throws {
        installing?.cancel()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

/// Live transcription with NVIDIA Parakeet TDT 0.6B v2 (English) on the Neural Engine, through
/// FluidAudio. Parakeet reads whole clips, so `UtteranceSegmenter` cuts the stream into
/// utterances: while someone talks, the utterance so far is transcribed about once a second
/// (a few tens of milliseconds each time), and a pause finishes it with a final pass.
final class ParakeetTranscriber: LiveSpeechTranscriber, @unchecked Sendable {
    let engineName = "Parakeet"

    private enum Command {
        case samples([Int16])
        case flush(CheckedContinuation<Void, Never>)
    }

    private let store: ParakeetModelStore
    private let lock = NSLock()
    private var input: AsyncStream<Command>.Continuation?
    private var worker: Task<Void, Never>?
    private var manager: AsrManager?
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Speech")

    init(store: ParakeetModelStore) {
        self.store = store
    }

    func start(onEvent: @escaping @Sendable (TranscriberEvent) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await store.install(progress: progress)
        let started = Date()
        let manager = AsrManager(config: .default)
        do {
            let models = try await AsrModels.load(from: store.directory, version: .v2)
            try await manager.loadModels(models)
            // The first pass compiles the model for the Neural Engine; do it before real audio.
            var state = try TdtDecoderState()
            _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
        } catch {
            throw TranscriberError.unavailable("The speech model couldn't be loaded: \(error.localizedDescription)")
        }
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        let log = self.log
        let worker = Task {
            var segmenter = UtteranceSegmenter()
            // Set after an utterance was cut mid-speech: the next one may repeat its last words.
            var continuing: String?
            func run(_ actions: [UtteranceSegmenter.Action]) async {
                for action in actions {
                    switch action {
                    case .live(let samples, let start, let end):
                        if var text = await Self.transcribe(samples, with: manager, log: log) {
                            if let continuing { text = UtteranceSegmenter.removingOverlap(text, after: continuing) }
                            onEvent(.volatile(text: text, start: start, end: end))
                        }
                    case .final(let samples, let start, let end, let isCut):
                        var text = await Self.transcribe(samples, with: manager, log: log) ?? ""
                        if let previous = continuing { text = UtteranceSegmenter.removingOverlap(text, after: previous) }
                        continuing = isCut ? text : nil
                        onEvent(.final(text: text, start: start, end: end))
                    case .discard:
                        continuing = nil
                        onEvent(.volatile(text: "", start: segmenter.time, end: segmenter.time))
                    }
                }
            }
            for await command in stream {
                switch command {
                case .samples(let samples):
                    var actions = segmenter.append(samples.map { Float($0) / 32768 })
                    // Behind real time (a slow Mac): skip stale live passes, never final ones.
                    if actions.count > 1 {
                        let lastLive = actions.lastIndex { if case .live = $0 { return true } else { return false } }
                        actions = actions.enumerated().filter { index, action in
                            if case .live = action { return index == lastLive }
                            return true
                        }.map(\.element)
                    }
                    await run(actions)
                case .flush(let done):
                    await run(segmenter.flush())
                    done.resume()
                }
            }
        }
        lock.withLock {
            self.input = continuation
            self.worker = worker
            self.manager = manager
        }
        log.info("Parakeet listening (loaded in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms)")
    }

    private static func transcribe(_ samples: [Float], with manager: AsrManager, log: Logger) async -> String? {
        guard samples.count >= 16_000 * 3 / 10 else { return nil }
        do {
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &state)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log.error("Parakeet couldn't transcribe: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty, let input = lock.withLock({ self.input }) else { return }
        input.yield(.samples(samples))
    }

    func flush() async {
        guard let input = lock.withLock({ self.input }) else { return }
        await withCheckedContinuation { continuation in
            if case .terminated = input.yield(.flush(continuation)) { continuation.resume() }
        }
    }

    func stop() async {
        let (input, worker, manager) = lock.withLock { () -> (AsyncStream<Command>.Continuation?, Task<Void, Never>?, AsrManager?) in
            defer {
                self.input = nil
                self.worker = nil
                self.manager = nil
            }
            return (self.input, self.worker, self.manager)
        }
        input?.finish()
        await worker?.value
        await manager?.cleanup()
    }
}
