import CoreBluetooth
import Foundation
import os

/// Identifiers and wire formats shared by the Bluetooth LE advertiser (Source Mac) and
/// browser (Studio Mac).
///
/// The Source publishes an L2CAP connection-oriented channel and a small GATT service
/// that tells the Studio which PSM to open and who is on the other end:
///
/// | UUID                                   | Contents                                        |
/// |----------------------------------------|-------------------------------------------------|
/// | `7A4D0001-3C1B-4F5E-9A8D-54414E44454D` | Primary service (advertised)                    |
/// | `7A4D0002-3C1B-4F5E-9A8D-54414E44454D` | PSM characteristic, read, `UInt16` little-endian |
/// | `7A4D0003-3C1B-4F5E-9A8D-54414E44454D` | Info characteristic, read, JSON `BluetoothPeerInfo` |
public enum BluetoothConstants {
    /// The primary GATT service a Source Mac advertises and a Studio Mac scans for.
    public static let serviceUUID = CBUUID(string: "7A4D0001-3C1B-4F5E-9A8D-54414E44454D")

    /// Read-only characteristic holding the published L2CAP PSM as a little-endian `UInt16`.
    public static let psmCharacteristicUUID = CBUUID(string: "7A4D0002-3C1B-4F5E-9A8D-54414E44454D")

    /// Read-only characteristic holding the Source's `BluetoothPeerInfo` as compact JSON.
    public static let infoCharacteristicUUID = CBUUID(string: "7A4D0003-3C1B-4F5E-9A8D-54414E44454D")

    /// Upper bound (inclusive) for the encoded info characteristic value. Kept below 180
    /// bytes so a single long read always succeeds, whatever ATT MTU was negotiated.
    public static let maxInfoBytes = 179

    /// Upper bound (inclusive) for the UTF-8 length of the advertised local name. The name
    /// travels in the scan response next to a 128-bit service UUID, so it has to stay short.
    public static let maxAdvertisedNameBytes = 20

    /// Encodes an L2CAP PSM the way it is stored in the PSM characteristic
    /// (two bytes, little-endian).
    public static func encodePSM(_ psm: CBL2CAPPSM) -> Data {
        Data([UInt8(truncatingIfNeeded: psm), UInt8(truncatingIfNeeded: psm >> 8)])
    }

    /// Decodes a PSM characteristic value. Returns `nil` unless `data` is exactly two bytes
    /// holding a non-zero PSM.
    public static func decodePSM(_ data: Data) -> CBL2CAPPSM? {
        guard data.count == 2 else { return nil }
        let low = CBL2CAPPSM(data[data.startIndex])
        let high = CBL2CAPPSM(data[data.startIndex + 1])
        let psm = low | (high << 8)
        return psm == 0 ? nil : psm
    }
}

/// Shared internals for the Bluetooth transport files.
enum BluetoothInternals {
    static let logger = Logger(subsystem: "com.rofel.tandem", category: "Bluetooth")

    /// Debug-only check that a queue-confined API is being used on its queue.
    @inline(__always)
    static func assertOnQueue(_ queue: DispatchQueue) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }
}
