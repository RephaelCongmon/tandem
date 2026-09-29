import Foundation
import Network
import os
import SystemConfiguration

/// Shared Network.framework configuration for Tandem connections.
public enum TandemNetwork {
    /// Bonjour service type (must also be listed under `NSBonjourServices`).
    public static let serviceType = "_tandem._tcp"
    /// Preferred fixed port so users can connect by address when Bonjour is blocked.
    public static let preferredPort: UInt16 = 47_623

    /// TCP tuned for interactive video: Nagle off, quick keepalives, peer-to-peer
    /// Wi-Fi (AWDL) allowed so two Macs connect even without a shared network.
    public static func parameters(peerToPeer: Bool = true) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 4
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        tcp.connectionDropTime = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = peerToPeer
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    /// Classifies the interface a path runs over into a user-facing link kind.
    public static func linkKind(for path: NWPath?) -> LinkKind {
        guard let path else { return .other }
        let interface = path.availableInterfaces.first { path.usesInterfaceType($0.type) } ?? path.availableInterfaces.first
        guard let interface else { return .other }
        return linkKind(interfaceName: interface.name, type: interface.type)
    }

    public static func linkKind(interfaceName name: String, type: NWInterface.InterfaceType) -> LinkKind {
        if name.hasPrefix("lo") || type == .loopback { return .loopback }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .peerToPeerWiFi }
        if name.hasPrefix("bridge") || InterfaceNames.isThunderbolt(bsdName: name) { return .thunderbolt }
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .ethernet
        case .loopback: return .loopback
        default: return .other
        }
    }
}

/// Resolves BSD interface names ("en5") to SystemConfiguration display names
/// ("Thunderbolt Bridge", "Thunderbolt 2") so cable links get the right badge.
enum InterfaceNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func isThunderbolt(bsdName: String) -> Bool {
        displayName(bsdName: bsdName)?.localizedCaseInsensitiveContains("thunderbolt") == true
    }

    static func displayName(bsdName: String) -> String? {
        lock.lock()
        if let cached = cache[bsdName] {
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()
        var found = ""
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                if let name = SCNetworkInterfaceGetBSDName(interface) as String?, name == bsdName {
                    found = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? ""
                    break
                }
            }
        }
        lock.lock()
        cache[bsdName] = found
        lock.unlock()
        return found.isEmpty ? nil : found
    }
}

/// `ByteTransport` over an `NWConnection` (TCP on Wi-Fi, peer-to-peer Wi-Fi,
/// Ethernet, Thunderbolt Bridge, or loopback).
public final class NetworkTransport: ByteTransport {
    public let queue: DispatchQueue
    public private(set) var linkKind: LinkKind = .other
    public var remoteDescription: String { "\(connection.endpoint)" }
    public var preferredWindowBytes: Int { linkKind.isConstrained ? 64 * 1024 : 1024 * 1024 }

    public var onStateChange: ((TransportState) -> Void)?
    public var onReceive: ((Data) -> Void)?

    private let connection: NWConnection
    private var isClosed = false
    private var didReportTerminal = false
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Network")

    /// Wraps an existing connection (e.g. accepted by a listener).
    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Creates an outgoing connection to `endpoint`.
    public convenience init(endpoint: NWEndpoint, queue: DispatchQueue, requiredInterfaceType: NWInterface.InterfaceType? = nil) {
        let parameters = TandemNetwork.parameters()
        if let requiredInterfaceType { parameters.requiredInterfaceType = requiredInterfaceType }
        self.init(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.linkKind = TandemNetwork.linkKind(for: path)
        }
        connection.start(queue: queue)
    }

    public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard !isClosed else {
            completion(TransportError.connectionLost("closed"))
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error.map { TransportError.connectionLost($0.localizedDescription) })
        })
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .setup, .preparing:
            onStateChange?(.connecting)
        case .waiting(let error):
            // Waiting means no usable path yet (e.g. local-network permission pending).
            log.info("Connection waiting: \(error.localizedDescription, privacy: .public)")
            onStateChange?(.connecting)
        case .ready:
            linkKind = TandemNetwork.linkKind(for: connection.currentPath)
            onStateChange?(.ready)
            receiveNext()
        case .failed(let error):
            reportTerminal(.failed(.connectionFailed(error.localizedDescription)))
        case .cancelled:
            reportTerminal(.closed)
        @unknown default:
            break
        }
    }

    private func reportTerminal(_ state: TransportState) {
        guard !didReportTerminal else { return }
        didReportTerminal = true
        isClosed = true
        onStateChange?(state)
        onStateChange = nil
        onReceive = nil
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.onReceive?(content)
            }
            if let error {
                self.reportTerminal(.failed(.connectionLost(error.localizedDescription)))
                self.connection.cancel()
                return
            }
            if isComplete {
                self.reportTerminal(.closed)
                self.connection.cancel()
                return
            }
            if !self.isClosed { self.receiveNext() }
        }
    }
}
