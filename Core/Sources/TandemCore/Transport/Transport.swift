import Foundation

/// The physical/logical link a connection runs over, shown to users as a badge.
public enum LinkKind: String, Codable, Sendable, CaseIterable {
    case wifi
    case peerToPeerWiFi
    case ethernet
    case thunderbolt
    case bluetooth
    case loopback
    case other

    public var displayName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .peerToPeerWiFi: return "Peer-to-Peer Wi-Fi"
        case .ethernet: return "Ethernet"
        case .thunderbolt: return "Thunderbolt Cable"
        case .bluetooth: return "Bluetooth"
        case .loopback: return "This Mac"
        case .other: return "Network"
        }
    }

    public var shortName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .peerToPeerWiFi: return "P2P Wi-Fi"
        case .ethernet: return "Ethernet"
        case .thunderbolt: return "Cable"
        case .bluetooth: return "Bluetooth"
        case .loopback: return "Local"
        case .other: return "Network"
        }
    }

    /// SF Symbol for the link.
    public var systemImage: String {
        switch self {
        case .wifi: return "wifi"
        case .peerToPeerWiFi: return "dot.radiowaves.left.and.right"
        case .ethernet: return "cable.connector.horizontal"
        case .thunderbolt: return "bolt.horizontal"
        case .bluetooth: return "wave.3.right"
        case .loopback: return "laptopcomputer"
        case .other: return "network"
        }
    }

    /// True for low-bandwidth links where the live preview must be scaled down hard.
    public var isConstrained: Bool { self == .bluetooth }
}

public enum TransportError: Error, Sendable, Hashable, LocalizedError {
    case connectionFailed(String)
    case connectionLost(String)
    case timedOut
    case unavailable(String)
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): return "Couldn't connect: \(reason)"
        case .connectionLost(let reason): return "Connection lost: \(reason)"
        case .timedOut: return "The connection timed out."
        case .unavailable(let reason): return reason
        case .protocolViolation(let reason): return "Protocol error: \(reason)"
        }
    }
}

public enum TransportState: Sendable, Equatable {
    case connecting
    case ready
    case failed(TransportError)
    case closed
}

/// An ordered, reliable byte stream between two Macs (TCP over any interface, or a
/// Bluetooth LE L2CAP channel). Framing, encryption and flow control live above this.
///
/// Threading: every callback is delivered on the `queue` the transport was created
/// with, and all methods must be called on that queue.
public protocol ByteTransport: AnyObject, Sendable {
    var queue: DispatchQueue { get }
    /// The link currently carrying the bytes. May be refined once the connection is ready.
    var linkKind: LinkKind { get }
    /// Human-readable remote endpoint (for diagnostics only).
    var remoteDescription: String { get }
    /// Roughly how many unacknowledged bytes may be queued before senders should back off.
    var preferredWindowBytes: Int { get }

    var onStateChange: ((TransportState) -> Void)? { get set }
    var onReceive: ((Data) -> Void)? { get set }

    func start()
    /// Enqueues bytes in order. `completion` fires on `queue` once the bytes have been
    /// handed to the OS (not necessarily delivered), or with an error.
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func close()
}
