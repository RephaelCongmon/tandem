import Foundation
import Network

/// Whether macOS currently lets Tandem use the local network.
///
/// macOS can block an app while System Settings shows it allowed: it recognizes apps by their
/// executable's UUID, and after an app is replaced in place (an update) it sometimes keeps
/// checking against the old one until its rules are rebuilt. A connection to a Bonjour service
/// then just stays "preparing", so Tandem asks directly: a UDP flow to the router is checked
/// like any other local traffic, and opening one sends nothing.
public enum LocalNetworkAccess: String, Sendable, Equatable {
    case allowed
    case denied
    /// Nothing local to check against (no router), or no answer in time.
    case unknown

    public static func check(timeout: TimeInterval = 3) async -> LocalNetworkAccess {
        guard let router = await currentRouter(timeout: timeout) else { return .unknown }
        return await probe(router, timeout: timeout)
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

    /// The current network's router, preferring IPv4.
    static func currentRouter(timeout: TimeInterval) async -> NWEndpoint.Host? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "tandem.localnetwork.path")
            let monitor = NWPathMonitor()
            let once = Once()
            let finish: @Sendable (NWEndpoint.Host?) -> Void = { host in
                once.run {
                    monitor.cancel()
                    continuation.resume(returning: host)
                }
            }
            monitor.pathUpdateHandler = { path in
                let hosts = path.gateways.compactMap { endpoint -> NWEndpoint.Host? in
                    if case .hostPort(let host, _) = endpoint { return host }
                    return nil
                }
                finish(hosts.first { if case .ipv4 = $0 { return true } else { return false } } ?? hosts.first)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
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
