import Foundation

/// Splits a live stream of 16 kHz samples into utterances for a model that transcribes whole
/// clips (Parakeet). While someone speaks it asks for a fresh transcript of the utterance so far
/// every `decodeInterval` (the live caption); a pause, or an utterance reaching `maxUtterance`,
/// finishes it with one last transcript. Pure logic, so it's testable without a model.
struct UtteranceSegmenter {
    struct Configuration {
        var sampleRate = 16_000
        var frameSamples = 320
        /// Audio kept from just before speech starts, so the first word isn't clipped.
        var preRoll: Double = 0.3
        /// Silence that ends an utterance.
        var pauseToFinish: Double = 0.6
        /// Longest utterance; the model reads up to 15 s in one pass.
        var maxUtterance: Double = 14
        /// How often the live transcript is refreshed while speaking.
        var decodeInterval: Double = 0.8
        /// Speech needed before an utterance is worth transcribing.
        var minimumSpeech: Double = 0.25
        /// Trailing silence kept when finishing.
        var trailingSilence: Double = 0.2
    }

    enum Action: Equatable {
        /// Transcribe `samples` (starting at audio time `start`) as the live, unfinished text.
        case live(samples: [Float], start: Double, end: Double)
        /// Transcribe `samples` as a finished segment.
        case final(samples: [Float], start: Double, end: Double)
        /// The utterance turned out to be noise; clear any live text.
        case discard
    }

    let configuration: Configuration
    /// Audio time consumed so far, in seconds.
    private(set) var time: Double = 0
    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var utterance: [Float] = []
    private var frameLevels: [Double] = []
    private var utteranceStart: Double?
    private var speechSeconds: Double = 0
    private var silenceRun: Double = 0
    private var lastLiveLength: Double = 0
    private var noiseFloor: Double = -70

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var isInUtterance: Bool { utteranceStart != nil }

    private var frameSeconds: Double { Double(configuration.frameSamples) / Double(configuration.sampleRate) }
    private func seconds(_ count: Int) -> Double { Double(count) / Double(configuration.sampleRate) }

    mutating func append(_ samples: [Float]) -> [Action] {
        pending.append(contentsOf: samples)
        var actions: [Action] = []
        let size = configuration.frameSamples
        var offset = 0
        while pending.count - offset >= size {
            actions += process(Array(pending[offset..<(offset + size)]))
            offset += size
        }
        pending.removeFirst(offset)
        return actions
    }

    /// Finishes the current utterance now (the audio paused or stopped).
    mutating func flush() -> [Action] {
        guard let start = utteranceStart else { return [] }
        return [finish(upTo: utterance.count, start: start)]
    }

    private mutating func process(_ frame: [Float]) -> [Action] {
        let level = Self.decibels(frame)
        // The noise floor follows quiet stretches down at once and creeps up slowly (1 dB/s),
        // so steady background noise isn't mistaken for speech.
        noiseFloor = level < noiseFloor ? level : noiseFloor + 0.02
        let isSpeech = level > max(noiseFloor + 10, -50)
        time += frameSeconds

        guard let start = utteranceStart else {
            preRoll.append(contentsOf: frame)
            let keep = Int(configuration.preRoll * Double(configuration.sampleRate))
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            guard isSpeech else { return [] }
            utterance = preRoll
            frameLevels = Array(repeating: -90, count: preRoll.count / configuration.frameSamples)
            frameLevels[frameLevels.count - 1] = level
            utteranceStart = time - seconds(preRoll.count)
            speechSeconds = frameSeconds
            silenceRun = 0
            lastLiveLength = 0
            preRoll.removeAll()
            return []
        }

        utterance.append(contentsOf: frame)
        frameLevels.append(level)
        if isSpeech {
            speechSeconds += frameSeconds
            silenceRun = 0
        } else {
            silenceRun += frameSeconds
        }
        let length = seconds(utterance.count)

        if silenceRun >= configuration.pauseToFinish {
            let keep = utterance.count - Int((silenceRun - configuration.trailingSilence) * Double(configuration.sampleRate))
            return [finish(upTo: max(keep, 0), start: start)]
        }
        if length >= configuration.maxUtterance {
            // Cut at the quietest moment of the last 2.5 s so a word isn't split in half.
            let window = Int(2.5 / frameSeconds)
            let firstCandidate = max(frameLevels.count - window, 1)
            let quietest = (firstCandidate..<frameLevels.count).min { frameLevels[$0] < frameLevels[$1] } ?? frameLevels.count
            let cut = quietest * configuration.frameSamples
            let rest = Array(utterance[cut...])
            let restLevels = Array(frameLevels[quietest...])
            let action = finish(upTo: cut, start: start)
            // What follows the cut starts the next utterance right away.
            utterance = rest
            frameLevels = restLevels
            utteranceStart = start + seconds(cut)
            speechSeconds = Double(restLevels.filter { $0 > max(noiseFloor + 10, -50) }.count) * frameSeconds
            silenceRun = 0
            lastLiveLength = 0
            return [action]
        }
        if speechSeconds >= configuration.minimumSpeech, length - lastLiveLength >= configuration.decodeInterval {
            lastLiveLength = length
            return [.live(samples: utterance, start: start, end: start + length)]
        }
        return []
    }

    private mutating func finish(upTo count: Int, start: Double) -> Action {
        let samples = Array(utterance.prefix(count))
        let hadSpeech = speechSeconds >= configuration.minimumSpeech
        // The frames after the cut become the pre-roll of whatever comes next.
        let keep = Int(configuration.preRoll * Double(configuration.sampleRate))
        preRoll = Array(utterance.suffix(min(keep, max(utterance.count - count, 0))))
        utterance.removeAll()
        frameLevels.removeAll()
        utteranceStart = nil
        speechSeconds = 0
        silenceRun = 0
        lastLiveLength = 0
        guard hadSpeech, !samples.isEmpty else { return .discard }
        return .final(samples: samples, start: start, end: start + seconds(samples.count))
    }

    static func decibels(_ frame: [Float]) -> Double {
        guard !frame.isEmpty else { return -120 }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        let rms = (sum / Float(frame.count)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(Double(rms))) : -120
    }
}
