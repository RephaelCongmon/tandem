import CoreBluetooth
import Foundation

/// Who is advertising: the identity a Source Mac publishes in its GATT info characteristic
/// (`BluetoothConstants.infoCharacteristicUUID`).
///
/// Wire format is compact JSON, e.g.
/// `{"id":"8C1E…","model":"MacBookPro18,1","name":"Rofel's MacBook Pro","v":1}`.
/// Use `encodedJSON(maxBytes:)` to produce a value that fits the characteristic and
/// `decode(from:)` to parse one. Decoding ignores unknown keys so newer Sources can add
/// fields without breaking older Studios.
public struct BluetoothPeerInfo: Codable, Hashable, Sendable {
    /// The info schema version this build writes.
    public static let currentVersion = 1

    /// Stable device identifier (a UUID string) used to match a discovery to a known Mac.
    /// Never truncated.
    public var id: String
    /// User-visible computer name. Truncated when the encoded value would be too large.
    public var name: String
    /// Hardware model identifier, e.g. `MacBookPro18,1`.
    public var model: String
    /// Schema version of this record.
    public var v: Int

    /// Creates a peer info record.
    public init(id: String, name: String, model: String, v: Int = BluetoothPeerInfo.currentVersion) {
        self.id = id
        self.name = name
        self.model = model
        self.v = v
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, model, v
    }

    /// Decodes a record, tolerating a missing `name`, `model` or `v`. Throws if `id` is
    /// missing or empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "The device id is empty.")
        }
        self.id = id
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.v = try container.decodeIfPresent(Int.self, forKey: .v) ?? BluetoothPeerInfo.currentVersion
    }

    /// Compact JSON for the info characteristic, guaranteed to be at most `maxBytes` long
    /// whenever that is achievable without touching `id`.
    ///
    /// If the full record is too large, `name` is shortened (on character boundaries, with
    /// trailing whitespace trimmed). If even an empty name doesn't fit, `model` is shortened
    /// as well. `id` is never modified, so a pathologically long id can still exceed the cap.
    public func encodedJSON(maxBytes: Int = BluetoothConstants.maxInfoBytes) -> Data {
        let full = Self.encode(self)
        if full.count <= maxBytes { return full }

        var candidate = self
        candidate.name = ""
        if Self.encode(candidate).count <= maxBytes {
            candidate.name = Self.longestFittingPrefix(of: name, maxBytes: maxBytes) { prefix in
                var trial = self
                trial.name = prefix
                return Self.encode(trial).count
            }
            return Self.encode(candidate)
        }

        candidate.model = ""
        if Self.encode(candidate).count <= maxBytes {
            candidate.model = Self.longestFittingPrefix(of: model, maxBytes: maxBytes) { prefix in
                var trial = candidate
                trial.model = prefix
                return Self.encode(trial).count
            }
        }
        return Self.encode(candidate)
    }

    /// Parses an info characteristic value.
    public static func decode(from data: Data) throws -> BluetoothPeerInfo {
        try JSONDecoder().decode(BluetoothPeerInfo.self, from: data)
    }

    /// `name` shortened to `BluetoothConstants.maxAdvertisedNameBytes` UTF-8 bytes for the
    /// advertisement's local name. Falls back to "Tandem" when the name is empty.
    public var advertisedName: String {
        let trimmed = Self.truncated(name, maxUTF8Bytes: BluetoothConstants.maxAdvertisedNameBytes)
        return trimmed.isEmpty ? "Tandem" : trimmed
    }

    // MARK: - Helpers

    private static func encode(_ info: BluetoothPeerInfo) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(info)
        } catch {
            // Encoding four plain fields cannot fail; keep a well-formed fallback anyway.
            BluetoothInternals.logger.fault("Couldn't encode peer info: \(error.localizedDescription, privacy: .public)")
            return Data("{}".utf8)
        }
    }

    /// Longest prefix of `string` (whole characters) whose encoded size, as measured by
    /// `size`, is at most `maxBytes`. Encoded size grows monotonically with prefix length,
    /// so a binary search finds it in O(log n) encodes.
    private static func longestFittingPrefix(
        of string: String, maxBytes: Int, size: (String) -> Int
    ) -> String {
        let characters = Array(string)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if size(String(characters[0..<mid])) <= maxBytes {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return trimmingTrailingWhitespace(String(characters[0..<low]))
    }

    /// `string` cut to at most `maxUTF8Bytes` bytes on a character boundary.
    static func truncated(_ string: String, maxUTF8Bytes: Int) -> String {
        guard string.utf8.count > maxUTF8Bytes else { return string }
        var result = ""
        var used = 0
        for character in string {
            let length = character.utf8.count
            if used + length > maxUTF8Bytes { break }
            result.append(character)
            used += length
        }
        return trimmingTrailingWhitespace(result)
    }

    private static func trimmingTrailingWhitespace(_ string: String) -> String {
        var result = string
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }
}

/// Whether Bluetooth LE can be used right now, as reported by CoreBluetooth.
public enum BluetoothAvailability: Sendable, Equatable {
    /// CoreBluetooth hasn't reported a state yet, or is resetting.
    case unknown
    /// Bluetooth is turned off.
    case poweredOff
    /// The user denied Tandem access to Bluetooth.
    case unauthorized
    /// This Mac doesn't support Bluetooth LE.
    case unsupported
    /// Bluetooth is on and usable.
    case ready

    /// Maps a CoreBluetooth manager state.
    public init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .ready
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .unknown, .resetting: self = .unknown
        @unknown default: self = .unknown
        }
    }

    /// A short, user-facing explanation of why Bluetooth can't be used (empty when ready).
    public var localizedDescription: String {
        switch self {
        case .unknown: return "Bluetooth isn't available yet."
        case .poweredOff: return "Bluetooth is turned off."
        case .unauthorized: return "Tandem doesn't have permission to use Bluetooth."
        case .unsupported: return "This Mac doesn't support Bluetooth LE."
        case .ready: return ""
        }
    }
}
