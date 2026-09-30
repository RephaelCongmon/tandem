import Foundation

/// Collects the chunks of an update package the Studio sends, and checks it's complete and
/// intact before anything is unpacked.
public struct UpdatePackageAssembler: Sendable {
    public enum Event: Sendable, Equatable {
        case progress(Double)
        case completed(Data)
        case failed(String)
    }

    public static let maxBytes = 300 * 1024 * 1024

    public private(set) var offer: UpdateOffer?
    private var chunks: [Data?] = []
    private var received = 0
    private var receivedBytes = 0
    private var lastReported = -1.0

    public init() {}

    public var isBusy: Bool { offer != nil }

    /// Starts collecting `offer`. Returns why it can't be accepted, if it can't.
    public mutating func begin(_ offer: UpdateOffer) -> String? {
        guard self.offer == nil else { return "Another update is already arriving." }
        guard offer.byteCount > 0, offer.byteCount <= Self.maxBytes else { return "The update is too large." }
        guard offer.sha256.count == 64, offer.sha256.allSatisfy(\.isHexDigit) else { return "The update has no valid checksum." }
        self.offer = offer
        chunks = []
        received = 0
        receivedBytes = 0
        lastReported = -1
        return nil
    }

    public mutating func receive(_ chunk: UpdateChunk) -> Event? {
        guard let offer, chunk.offerID == offer.id else { return nil }
        if chunks.isEmpty {
            guard chunk.count <= 65_536 else { return fail("The update was split into too many pieces.") }
            chunks = Array(repeating: nil, count: chunk.count)
        }
        guard chunk.count == chunks.count, chunk.index < chunks.count else { return fail("The update arrived garbled.") }
        if chunks[chunk.index] == nil {
            chunks[chunk.index] = chunk.data
            received += 1
            receivedBytes += chunk.data.count
        }
        guard receivedBytes <= offer.byteCount else { return fail("The update was larger than announced.") }
        guard received == chunks.count else {
            let fraction = Double(receivedBytes) / Double(offer.byteCount)
            // Report every 5 %.
            guard fraction - lastReported >= 0.05 else { return nil }
            lastReported = fraction
            return .progress(fraction)
        }
        var data = Data(capacity: offer.byteCount)
        for part in chunks { if let part { data.append(part) } }
        reset()
        guard data.count == offer.byteCount else { return .failed("The update arrived incomplete.") }
        guard FileTools.sha256(of: data) == offer.sha256 else { return .failed("The update was damaged on the way (checksum mismatch).") }
        return .completed(data)
    }

    public mutating func reset() {
        offer = nil
        chunks = []
        received = 0
        receivedBytes = 0
    }

    private mutating func fail(_ reason: String) -> Event {
        reset()
        return .failed(reason)
    }
}
