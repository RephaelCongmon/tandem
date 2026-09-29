import Foundation

/// Length-prefixed framing over a byte stream: `[UInt32 big-endian length][payload]`.
public enum FrameCodec {
    /// Upper bound on a single frame. Snapshots are chunked well below this, so
    /// anything larger means a corrupt or hostile stream.
    public static let maxFrameLength = 8 * 1024 * 1024

    public static func encode(_ payload: Data) -> Data {
        var framed = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }
}

public enum FrameDecoderError: Error, Equatable {
    case frameTooLarge(Int)
}

/// Incrementally splits a byte stream into frames. Amortized O(n): consumed bytes
/// are compacted away only once they dominate the buffer.
public struct FrameDecoder {
    private var buffer = Data()
    private var readOffset = 0
    private let maxFrameLength: Int

    public init(maxFrameLength: Int = FrameCodec.maxFrameLength) {
        self.maxFrameLength = maxFrameLength
    }

    /// Bytes received but not yet returned as part of a frame.
    public var pendingByteCount: Int { buffer.count - readOffset }

    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while true {
            let available = buffer.count - readOffset
            guard available >= 4 else { break }
            let base = buffer.startIndex + readOffset
            let length = Int(buffer[base]) << 24 | Int(buffer[base + 1]) << 16
                | Int(buffer[base + 2]) << 8 | Int(buffer[base + 3])
            guard length <= maxFrameLength else { throw FrameDecoderError.frameTooLarge(length) }
            guard available >= 4 + length else { break }
            frames.append(buffer.subdata(in: (base + 4)..<(base + 4 + length)))
            readOffset += 4 + length
        }
        compactIfNeeded()
        return frames
    }

    private mutating func compactIfNeeded() {
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count <= 1 << 20)
            readOffset = 0
        } else if readOffset > 64 * 1024 && readOffset * 2 > buffer.count {
            buffer = buffer.subdata(in: (buffer.startIndex + readOffset)..<buffer.endIndex)
            readOffset = 0
        }
    }
}
