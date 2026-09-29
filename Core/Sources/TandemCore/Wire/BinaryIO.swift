import Foundation

/// Appends big-endian primitives to a byte buffer.
public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func write(_ value: UInt8) { data.append(value) }

    public mutating func write(_ value: UInt16) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ uuid: UUID) {
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
    }

    /// Raw bytes with no length prefix.
    public mutating func write(raw bytes: Data) { data.append(bytes) }

    /// Bytes prefixed by a UInt16 length. Precondition: `bytes.count <= UInt16.max`.
    public mutating func writeShortBlob(_ bytes: Data) {
        precondition(bytes.count <= Int(UInt16.max), "blob too large for a 16-bit length")
        write(UInt16(bytes.count))
        data.append(bytes)
    }
}

/// Reads big-endian primitives from a byte buffer; every read is bounds-checked.
public struct ByteReader {
    public enum ReadError: Error, Equatable { case truncated }

    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }
    public var isAtEnd: Bool { remaining == 0 }

    public mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw ReadError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func readUInt16() throws -> UInt16 {
        UInt16(truncatingIfNeeded: try readInteger(bytes: 2))
    }

    public mutating func readUInt32() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try readInteger(bytes: 4))
    }

    public mutating func readUInt64() throws -> UInt64 {
        try readInteger(bytes: 8)
    }

    public mutating func readUUID() throws -> UUID {
        let bytes = try readBytes(16)
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UUID in
            UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                        raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
        }
    }

    public mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw ReadError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    public mutating func readShortBlob() throws -> Data {
        try readBytes(Int(try readUInt16()))
    }

    /// Everything that hasn't been read yet.
    public mutating func readRemaining() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }

    private mutating func readInteger(bytes count: Int) throws -> UInt64 {
        guard remaining >= count else { throw ReadError.truncated }
        var value: UInt64 = 0
        for index in offset..<(offset + count) {
            value = (value << 8) | UInt64(data[index])
        }
        offset += count
        return value
    }
}
