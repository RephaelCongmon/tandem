import Foundation

/// A fully received snapshot.
public struct ReceivedSnapshot: Sendable, Hashable {
    public var header: SnapshotHeader
    public var data: Data
    /// Seconds between the header and the last chunk arriving.
    public var transferSeconds: Double
}

/// Reassembles chunked snapshots on the receiving side. Tolerates interleaving of
/// several snapshots, drops incomplete ones after a timeout, and caps memory.
public struct SnapshotAssembler {
    public struct Progress: Sendable, Hashable {
        public var id: UUID
        public var receivedBytes: Int
        public var totalBytes: Int
        public var fraction: Double { totalBytes == 0 ? 0 : Double(receivedBytes) / Double(totalBytes) }
    }

    private struct Pending {
        var header: SnapshotHeader
        var chunks: [Data?]
        var receivedCount = 0
        var receivedBytes = 0
        var startedAt: Double
        var lastActivity: Double
    }

    private var pending: [UUID: Pending] = [:]
    private let maxSnapshotBytes: Int
    private let staleAfter: Double

    public init(maxSnapshotBytes: Int = 64 * 1024 * 1024, staleAfter: Double = 60) {
        self.maxSnapshotBytes = maxSnapshotBytes
        self.staleAfter = staleAfter
    }

    public enum Event: Sendable, Hashable {
        case progress(Progress)
        case completed(ReceivedSnapshot)
        case rejected(id: UUID, reason: String)
    }

    public var inProgress: [Progress] {
        pending.values.map { Progress(id: $0.header.id, receivedBytes: $0.receivedBytes, totalBytes: $0.header.byteCount) }
    }

    public mutating func begin(_ header: SnapshotHeader, now: Double = monotonicSeconds()) -> Event? {
        guard header.byteCount > 0, header.byteCount <= maxSnapshotBytes,
              header.chunkCount > 0, header.chunkCount <= 65_536 else {
            return .rejected(id: header.id, reason: "invalid snapshot size")
        }
        pending[header.id] = Pending(
            header: header,
            chunks: Array(repeating: nil, count: header.chunkCount),
            startedAt: now,
            lastActivity: now
        )
        return .progress(Progress(id: header.id, receivedBytes: 0, totalBytes: header.byteCount))
    }

    public mutating func receive(_ chunk: SnapshotChunk, now: Double = monotonicSeconds()) -> Event? {
        guard var entry = pending[chunk.snapshotID] else { return nil }
        guard chunk.count == entry.header.chunkCount, chunk.index < entry.chunks.count else {
            pending[chunk.snapshotID] = nil
            return .rejected(id: chunk.snapshotID, reason: "chunk mismatch")
        }
        if entry.chunks[chunk.index] == nil {
            entry.chunks[chunk.index] = chunk.data
            entry.receivedCount += 1
            entry.receivedBytes += chunk.data.count
        }
        entry.lastActivity = now
        guard entry.receivedBytes <= entry.header.byteCount else {
            pending[chunk.snapshotID] = nil
            return .rejected(id: chunk.snapshotID, reason: "too much data")
        }
        if entry.receivedCount == entry.chunks.count {
            pending[chunk.snapshotID] = nil
            var data = Data(capacity: entry.header.byteCount)
            for part in entry.chunks { if let part { data.append(part) } }
            guard data.count == entry.header.byteCount else {
                return .rejected(id: chunk.snapshotID, reason: "size mismatch")
            }
            return .completed(ReceivedSnapshot(header: entry.header, data: data, transferSeconds: now - entry.startedAt))
        }
        pending[chunk.snapshotID] = entry
        return .progress(Progress(id: chunk.snapshotID, receivedBytes: entry.receivedBytes, totalBytes: entry.header.byteCount))
    }

    /// Drops snapshots that stopped making progress; returns their ids.
    public mutating func expireStale(now: Double = monotonicSeconds()) -> [UUID] {
        let stale = pending.filter { now - $0.value.lastActivity > staleAfter }.map(\.key)
        for id in stale { pending[id] = nil }
        return stale
    }

    public mutating func reset() {
        pending.removeAll()
    }
}
