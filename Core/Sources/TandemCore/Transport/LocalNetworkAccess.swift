import Foundation
import Network
import SystemConfiguration

/// Whether macOS currently lets Tandem use the local network.
///
/// macOS can block an app while System Settings shows it allowed: it recognizes apps by their
/// executable's UUID, and after an app is replaced in place (an update) it sometimes keeps
/// checking against the old one until its rules are rebuilt. A connection to a Bonjour service
/// then just stays "preparing", so Tandem asks directly: a UDP flow to an address on the local
/// network is checked like any other local traffic, and opening one sends nothing.
///
/// The address must be one macOS doesn't wave through: traffic to the DNS server or a proxy
/// never needs permission, and the router is usually the DNS server. So Tandem picks another
/// host on the same subnet (it needn't exist).
public enum LocalNetworkAccess: String, Sendable, Equatable {
    case allowed
    case denied
    /// No local network to check against, or no answer in time.
    case unknown

    public static func check(timeout: TimeInterval = 3) async -> LocalNetworkAccess {
        guard let target = probeTarget() else { return .unknown }
        return await probe(.ipv4(target), timeout: timeout)
    }

    /// What a probe connection's state says, or nil while it's still undecided.
    static func interpret(_ state: NWConnection.State, unsatisfiedReason: NWPath.UnsatisfiedReason?) -> LocalNetworkAccess? {
        switch state {
        case .ready: return .allowed
        case .waiting: return unsatisfiedReason == .localNetworkDenied ? .denied : .unknown
        case .failed, .cancelled: return .unknown
        case .setup, .preparing: return nil
        @unknown default: return nil
        }
    }

    /// A host on this Mac's local network that isn't exempt from local network privacy.
    static func probeTarget() -> IPv4Address? {
        let exempt = exemptAddresses()
        for network in localNetworks() {
            if let host = probeAddress(address: network.address, netmask: network.netmask, avoiding: exempt) {
                return IPv4Address(host)
            }
        }
        return nil
    }

    /// Picks a host on the subnet of `address`/`netmask`, from the top down, that isn't
    /// `address` itself, the network or broadcast address, or one of `avoiding`. Nil when the
    /// subnet is too small to have one.
    static func probeAddress(address: UInt32, netmask: UInt32, avoiding: Set<UInt32>) -> UInt32? {
        let network = address & netmask
        let broadcast = network | ~netmask
        guard broadcast > network + 2 else { return nil }
        let top = (1...8).map { broadcast - $0 }
        let bottom = (1...8).map { network + $0 }
        return (top + bottom).first { candidate in
            candidate > network && candidate < broadcast && candidate != address && !avoiding.contains(candidate)
        }
    }

    /// IPv4 address and netmask of each broadcast-capable interface that's up (Wi-Fi, Ethernet,
    /// Thunderbolt Bridge), primary interface first. Host byte order.
    static func localNetworks() -> [(name: String, address: UInt32, netmask: UInt32)] {
        var result: [(name: String, address: UInt32, netmask: UInt32)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let host = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append((String(cString: entry.pointee.ifa_name), host, netmask))
        }
        let primary = globalState("State:/Network/Global/IPv4")?["PrimaryInterface"] as? String
        return result.sorted { ($0.name == primary ? 0 : 1) < ($1.name == primary ? 0 : 1) }
    }

    /// Routers, DNS servers and proxies: macOS lets any app reach those.
    static func exemptAddresses() -> Set<UInt32> {
        var strings: [String] = []
        if let router = globalState("State:/Network/Global/IPv4")?["Router"] as? String { strings.append(router) }
        if let servers = globalState("State:/Network/Global/DNS")?["ServerAddresses"] as? [String] { strings += servers }
        if let proxies = globalState("State:/Network/Global/Proxies") {
            strings += ["HTTPProxy", "HTTPSProxy", "SOCKSProxy", "FTPProxy", "RTSPProxy", "GopherProxy"].compactMap { proxies[$0] as? String }
        }
        return Set(strings.compactMap { IPv4Address($0).map(hostOrder) })
    }

    static func hostOrder(_ address: IPv4Address) -> UInt32 {
        address.rawValue.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func globalState(_ key: String) -> [String: Any]? {
        guard let store = SCDynamicStoreCreate(nil, "Tandem" as CFString, nil, nil) else { return nil }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    static func probe(_ host: NWEndpoint.Host, timeout: TimeInterval) async -> LocalNetworkAccess {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "tandem.localnetwork.probe")
            // The discard port; nothing is ever sent.
            let connection = NWConnection(host: host, port: 9, using: .udp)
            let once = Once()
            let finish: @Sendable (LocalNetworkAccess) -> Void = { result in
                once.run {
                    connection.cancel()
                    continuation.resume(returning: result)
                }
            }
            connection.stateUpdateHandler = { state in
                if let result = interpret(state, unsatisfiedReason: connection.currentPath?.unsatisfiedReason) {
                    finish(result)
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.unknown) }
        }
    }
}

private extension IPv4Address {
    init?(_ host: UInt32) {
        self.init(Data([UInt8(host >> 24), UInt8(host >> 16 & 0xFF), UInt8(host >> 8 & 0xFF), UInt8(host & 0xFF)]))
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}
