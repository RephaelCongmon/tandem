import CryptoKit
import Foundation

public enum RecordError: Error, Equatable {
    case authenticationFailed
    case malformed
    case exhausted
}

/// ChaCha20-Poly1305 protection for one direction of a session. Nonces are an
/// implicit 64-bit record counter, so records must be opened in the order they
/// were sealed (guaranteed by the ordered transports underneath). Any replayed,
/// dropped, reordered or modified record fails authentication.
public struct RecordProtector {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    private static let tagLength = 16

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Returns `ciphertext || tag`.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard counter < UInt64.max else { throw RecordError.exhausted }
        let nonce = try ChaChaPoly.Nonce(data: Self.nonceBytes(counter))
        counter += 1
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        var record = box.ciphertext
        record.append(box.tag)
        return record
    }

    public mutating func open(_ record: Data) throws -> Data {
        guard record.count >= Self.tagLength else { throw RecordError.malformed }
        guard counter < UInt64.max else { throw RecordError.exhausted }
        let nonce = try ChaChaPoly.Nonce(data: Self.nonceBytes(counter))
        let split = record.endIndex - Self.tagLength
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: record[record.startIndex..<split],
                tag: record[split..<record.endIndex]
            )
            let plaintext = try ChaChaPoly.open(box, using: key)
            counter += 1
            return plaintext
        } catch {
            throw RecordError.authenticationFailed
        }
    }

    private static func nonceBytes(_ counter: UInt64) -> Data {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }
}
