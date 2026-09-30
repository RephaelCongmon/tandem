import Foundation
import TandemCore

/// Encodes captured audio for each listening Studio and sends it in ~100 ms packets. Runs on
/// the audio capture queue; links are only touched on their own queues.
final class AudioFanout: @unchecked Sendable {
    private final class Listener {
        let link: PeerLink
        let encoder: AudioFrameEncoder
        var packetizer: AudioPacketizer

        init(link: PeerLink, encoder: AudioFrameEncoder) {
            self.link = link
            self.encoder = encoder
            packetizer = AudioPacketizer(codec: encoder.codec)
        }
    }

    /// Most packets (about 5 s) that may wait in a link before new ones are dropped, so a
    /// stalled link can't build up a backlog of stale audio.
    static let maxQueuedPackets = 50

    private let queue: DispatchQueue
    private var listeners: [UUID: Listener] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// The first codec in `preferred` this Mac can encode.
    static func codec(for preferred: [LiveAudioCodec]) -> LiveAudioCodec? {
        preferred.first { AudioFrameEncoder(codec: $0) != nil }
    }

    /// Starts sending to `id` (or changes its codec); `codec == nil` stops.
    func setListener(id: UUID, link: PeerLink, codec: LiveAudioCodec?) {
        queue.async {
            guard let codec else {
                self.listeners[id] = nil
                return
            }
            if self.listeners[id]?.encoder.codec == codec, self.listeners[id]?.link === link { return }
            guard let encoder = AudioFrameEncoder(codec: codec) else {
                self.listeners[id] = nil
                return
            }
            self.listeners[id] = Listener(link: link, encoder: encoder)
        }
    }

    func removeAll() {
        queue.async { self.listeners.removeAll() }
    }

    /// Called on `queue` with captured samples.
    func submit(_ samples: [Int16], capturedAtNanos: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        for listener in listeners.values {
            let frames = listener.encoder.encode(samples)
            for (offset, frame) in frames.enumerated() {
                // Frames finish slightly after the samples they came from; timestamp each by its end.
                let end = capturedAtNanos &+ UInt64(Double(samples.count) / Double(LiveAudio.sampleRate) * 1e9)
                let frameStart = end &- UInt64(Double(frames.count - offset) * 0.02 * 1e9)
                guard let packet = listener.packetizer.append(frame, capturedAtNanos: frameStart) else { continue }
                send(packet, to: listener)
            }
        }
    }

    private func send(_ packet: AudioPacket, to listener: Listener) {
        let link = listener.link
        let maxQueued = Self.maxQueuedPackets
        link.queue.async {
            guard link.queuedAudioPackets < maxQueued else { return }
            link.send(.audioPacket(packet), priority: .audio)
        }
    }
}
