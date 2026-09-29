import Foundation
import Network
import os

/// Keys in the Bonjour TXT record.
enum TXTKey {
    static let deviceID = "id"
    static let model = "model"
    static let role = "role"
    static let version = "v"
}

public enum ListenerState: Sendable, Equatable {
    case starting
    case ready(port: UInt16)
    /// Local Network permission hasn't been granted yet (or was denied).
    case waitingForPermission(String)
    case failed(String)
    case stopped
}

/// Accepts incoming TCP connections and advertises this Mac over Bonjour on every
/// interface, including peer-to-peer Wi-Fi.
public final class NetworkListener {
    public var onIncomingTransport: ((NetworkTransport) -> Void)?
    public var onStateChange: ((ListenerState) -> Void)?

    private let queue: DispatchQueue
    private var identity: DeviceIdentity
    private var role: PeerRole
    private var listener: NWListener?
    private var triedPreferredPort = false
    private var restartWorkItem: DispatchWorkItem?
    private var isRunning = false
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Network")

    public private(set) var port: UInt16?

    public init(identity: DeviceIdentity, role: PeerRole, queue: DispatchQueue) {
        self.identity = identity
        self.role = role
        self.queue = queue
    }

    public func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            triedPreferredPort = false
            startListener()
        }
    }

    public func stop() {
        queue.async { [self] in
            isRunning = false
            restartWorkItem?.cancel()
            listener?.cancel()
            listener = nil
            port = nil
            onStateChange?(.stopped)
        }
    }

    public func update(identity: DeviceIdentity, role: PeerRole) {
        queue.async { [self] in
            self.identity = identity
            self.role = role
            listener?.service = makeService()
        }
    }

    private func makeService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt[TXTKey.deviceID] = identity.id
        txt[TXTKey.model] = identity.model
        txt[TXTKey.role] = role.rawValue
        txt[TXTKey.version] = String(tandemProtocolVersion)
        // Bonjour instance names are limited to 63 bytes.
        let name = Self.truncated(identity.name, maxUTF8Bytes: 63)
        return NWListener.Service(name: name, type: TandemNetwork.serviceType, domain: nil, txtRecord: txt)
    }

    static func truncated(_ string: String, maxUTF8Bytes: Int) -> String {
        var result = ""
        var used = 0
        for character in string {
            let size = String(character).utf8.count
            if used + size > maxUTF8Bytes { break }
            result.append(character)
            used += size
        }
        return result
    }

    private func startListener() {
        let parameters = TandemNetwork.parameters()
        parameters.allowLocalEndpointReuse = true
        // Try the well-known port first (so "connect by address" works); if it's
        // taken the listener fails with EADDRINUSE and we retry on any port.
        if !triedPreferredPort, let port = NWEndpoint.Port(rawValue: TandemNetwork.preferredPort),
           let listener = try? NWListener(using: parameters, on: port) {
            triedPreferredPort = true
            configure(listener)
            return
        }
        triedPreferredPort = true
        do {
            configure(try NWListener(using: parameters))
        } catch {
            onStateChange?(.failed(error.localizedDescription))
            scheduleRestart()
        }
    }

    private func configure(_ listener: NWListener) {
        self.listener = listener
        listener.service = makeService()
        listener.newConnectionLimit = 8
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            self.handle(state, listener: listener)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let transport = NetworkTransport(connection: connection, queue: DispatchQueue(label: "tandem.link", qos: .userInteractive))
            self.onIncomingTransport?(transport)
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if case .add(let endpoint) = change {
                self?.log.info("Advertising as \(String(describing: endpoint), privacy: .public)")
            }
        }
        onStateChange?(.starting)
        listener.start(queue: queue)
    }

    private func handle(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            port = listener.port?.rawValue
            onStateChange?(.ready(port: port ?? 0))
        case .waiting(let error):
            onStateChange?(.waitingForPermission(error.localizedDescription))
        case .failed(let error):
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            listener.cancel()
            self.listener = nil
            if case .posix(let code) = error, code == .EADDRINUSE {
                startListener()
                return
            }
            onStateChange?(.failed(error.localizedDescription))
            scheduleRestart()
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private func scheduleRestart() {
        guard isRunning else { return }
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.listener == nil else { return }
            self.triedPreferredPort = false
            self.startListener()
        }
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + 3, execute: item)
    }
}

/// A Tandem instance found via Bonjour.
public struct NetworkDiscovery: Hashable, Sendable {
    public var deviceID: String
    public var name: String
    public var model: String
    public var role: PeerRole?
    public var protocolVersion: Int?
    public var endpoint: NWEndpoint
    public var links: [LinkKind]

    public var identity: DeviceIdentity { DeviceIdentity(id: deviceID, name: name, model: model) }
}

public enum BrowserState: Sendable, Equatable {
    case starting
    case ready
    case waitingForPermission(String)
    case failed(String)
    case stopped
}

/// Browses for other Tandem instances (Wi-Fi, Ethernet, Thunderbolt, peer-to-peer Wi-Fi).
public final class NetworkBrowser {
    public var onChange: (([NetworkDiscovery]) -> Void)?
    public var onStateChange: ((BrowserState) -> Void)?

    private let queue: DispatchQueue
    private let ownDeviceID: String
    private var browser: NWBrowser?
    private var isRunning = false
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Network")

    public init(ownDeviceID: String, queue: DispatchQueue) {
        self.ownDeviceID = ownDeviceID
        self.queue = queue
    }

    public func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            startBrowser()
        }
    }

    public func stop() {
        queue.async { [self] in
            isRunning = false
            browser?.cancel()
            browser = nil
            onStateChange?(.stopped)
        }
    }

    /// Restarts browsing (e.g. after the network changed or permission was granted).
    public func refresh() {
        queue.async { [self] in
            guard isRunning else { return }
            browser?.cancel()
            browser = nil
            startBrowser()
        }
    }

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: TandemNetwork.serviceType, domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, browser === self.browser else { return }
            switch state {
            case .ready: self.onStateChange?(.ready)
            case .waiting(let error): self.onStateChange?(.waitingForPermission(error.localizedDescription))
            case .failed(let error):
                self.log.error("Browser failed: \(error.localizedDescription, privacy: .public)")
                self.onStateChange?(.failed(error.localizedDescription))
                browser.cancel()
                self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.isRunning, self.browser == nil else { return }
                    self.startBrowser()
                }
            case .setup, .cancelled: break
            @unknown default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, browser === self.browser else { return }
            self.onChange?(self.discoveries(from: results))
        }
        onStateChange?(.starting)
        browser.start(queue: queue)
    }

    private func discoveries(from results: Set<NWBrowser.Result>) -> [NetworkDiscovery] {
        var output: [NetworkDiscovery] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                txt = record.dictionary
            }
            guard let id = txt[TXTKey.deviceID], UUID(uuidString: id) != nil, id != ownDeviceID else { continue }
            let links = Array(Set(result.interfaces.map { TandemNetwork.linkKind(interfaceName: $0.name, type: $0.type) }))
                .sorted { $0.rawValue < $1.rawValue }
            output.append(NetworkDiscovery(
                deviceID: id,
                name: name,
                model: txt[TXTKey.model] ?? "Mac",
                role: txt[TXTKey.role].flatMap(PeerRole.init(rawValue:)),
                protocolVersion: txt[TXTKey.version].flatMap(Int.init),
                endpoint: result.endpoint,
                links: links
            ))
        }
        return output
    }
}

// Queue-confined; safe to hand across isolation domains.
extension NetworkListener: @unchecked Sendable {}
extension NetworkBrowser: @unchecked Sendable {}
