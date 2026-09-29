import AppKit
import Foundation
import Network
import Observation
import os
@preconcurrency import TandemCore

/// A Mac seen nearby (over the network and/or Bluetooth) or remembered from pairing.
struct NearbyDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var model: String
    var role: PeerRole?
    var networkLinks: [LinkKind]
    var isOnNetwork: Bool
    var isOnBluetooth: Bool
    var bluetoothRSSI: Int?
    var isTrusted: Bool

    var identity: DeviceIdentity { DeviceIdentity(id: id, name: name, model: model) }
    var isReachable: Bool { isOnNetwork || isOnBluetooth }

    /// The best link to show as a badge before connecting.
    var primaryLink: LinkKind? {
        let order: [LinkKind] = [.thunderbolt, .ethernet, .wifi, .peerToPeerWiFi, .loopback, .other]
        if let link = order.first(where: networkLinks.contains) { return link }
        return isOnBluetooth ? .bluetooth : nil
    }
}

/// An incoming pairing request waiting for the local user's decision (Source side).
struct PairingRequest: Identifiable, Equatable {
    let id: UUID
    let code: String
    let peer: DeviceIdentity
}

/// Owns discovery, listening, and every `PeerLink`, and keeps the Studio connected
/// to the chosen Source (with backoff) across sleep, network changes and restarts.
@MainActor
@Observable
final class ConnectionManager {
    private(set) var role: AppRole?
    private(set) var nearby: [NearbyDevice] = []
    private(set) var connections: [PeerConnection] = []
    private(set) var listenerState: ListenerState = .stopped
    private(set) var browserState: BrowserState = .stopped
    private(set) var bluetoothState: BluetoothAvailability = .unknown
    private(set) var connectingDeviceIDs: Set<String> = []
    private(set) var pendingPairing: PairingRequest?
    /// The Source the Studio wants to stay connected to.
    private(set) var desiredSourceID: String?
    /// Last user-visible connection problem, per device.
    private(set) var lastFailure: (deviceID: String?, message: String)?
    private(set) var reconnectAt: Date?

    @ObservationIgnored var onEstablished: ((PeerConnection) -> Void)?
    @ObservationIgnored var onClosed: ((PeerConnection, PeerLinkCloseReason) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let trust: TrustedPeerStore
    @ObservationIgnored private(set) var identity: DeviceIdentity
    @ObservationIgnored private var listener: BonjourListener?
    @ObservationIgnored private var browser: BonjourBrowser?
    @ObservationIgnored private var advertiser: BluetoothAdvertiser?
    @ObservationIgnored private var bluetoothBrowser: BluetoothBrowser?
    @ObservationIgnored private let discoveryQueue = DispatchQueue(label: "tandem.discovery", qos: .userInitiated)
    @ObservationIgnored private let bluetoothQueue = DispatchQueue(label: "tandem.bluetooth", qos: .userInitiated)
    @ObservationIgnored private var networkDiscoveries: [String: NetworkDiscovery] = [:]
    @ObservationIgnored private var bluetoothDiscoveries: [String: BluetoothBrowser.Discovery] = [:]
    @ObservationIgnored private var routers: [UUID: LinkRouter] = [:]
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var maintenanceTimer: Timer?
    @ObservationIgnored private var pairingDeniedUntil: [String: Date] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Connections")

    static let maxIncomingSessions = 4

    init(settings: SettingsStore, trust: TrustedPeerStore, identity: DeviceIdentity) {
        self.settings = settings
        self.trust = trust
        self.identity = identity
        observeSystemEvents()
    }

    // MARK: Role lifecycle

    func activate(role: AppRole) {
        guard self.role != role else { return }
        deactivate()
        self.role = role
        switch role {
        case .source:
            startListening()
        case .studio:
            startBrowsing()
            if settings.autoConnect, let last = settings.lastSourceID, trust.isTrusted(last) {
                desiredSourceID = last
            }
        }
        startMaintenance()
    }

    func deactivate() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAt = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        for connection in connections { connection.close(reason: "Tandem changed modes.") }
        listener?.stop()
        listener = nil
        browser?.stop()
        browser = nil
        if let advertiser { bluetoothQueue.async { advertiser.stop() } }
        advertiser = nil
        if let bluetoothBrowser { bluetoothQueue.async { bluetoothBrowser.stopScanning() } }
        bluetoothBrowser = nil
        networkDiscoveries.removeAll()
        bluetoothDiscoveries.removeAll()
        nearby = []
        pendingPairing = nil
        desiredSourceID = nil
        role = nil
        listenerState = .stopped
        browserState = .stopped
    }

    /// Call when the device name or Bluetooth preference changes.
    func updateIdentity(_ identity: DeviceIdentity) {
        self.identity = identity
        listener?.update(identity: identity, role: role?.peerRole ?? .source)
        if let advertiser {
            let info = BluetoothPeerInfo(id: identity.id, name: identity.name, model: identity.model)
            bluetoothQueue.async { advertiser.updateInfo(info) }
        }
    }

    func applyBluetoothPreference() {
        guard let role else { return }
        if role == .source {
            if settings.bluetoothEnabled, advertiser == nil { startAdvertisingBluetooth() }
            if !settings.bluetoothEnabled, let advertiser {
                bluetoothQueue.async { advertiser.stop() }
                self.advertiser = nil
            }
        } else {
            if settings.bluetoothEnabled, bluetoothBrowser == nil { startBluetoothBrowsing() }
            if !settings.bluetoothEnabled, let bluetoothBrowser {
                bluetoothQueue.async { bluetoothBrowser.stopScanning() }
                self.bluetoothBrowser = nil
                bluetoothDiscoveries.removeAll()
                rebuildNearby()
            }
        }
    }

    // MARK: Queries

    var establishedConnections: [PeerConnection] { connections.filter(\.isConnected) }

    /// The Studio's live connection to its Source.
    var activeSourceConnection: PeerConnection? {
        connections.first { $0.direction == .outgoing && $0.isConnected }
    }

    func connection(for deviceID: String) -> PeerConnection? {
        connections.first { $0.peer?.id == deviceID && $0.phase.isLive }
    }

    func isConnecting(to deviceID: String) -> Bool {
        connectingDeviceIDs.contains(deviceID) || connections.contains {
            $0.peer?.id == deviceID && !$0.isConnected && $0.phase.isLive
        }
    }

    var localAddresses: [String] {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return Array(Set(addresses)).sorted()
    }

    // MARK: Studio actions

    /// Connects to a Source, pairing first if needed.
    func connect(to deviceID: String, forcePairing: Bool = false) {
        guard role == .studio else { return }
        lastFailure = nil
        desiredSourceID = deviceID
        settings.lastSourceID = deviceID
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectAt = nil
        // One Source at a time.
        for connection in connections where connection.peer?.id != deviceID {
            connection.close(reason: "Switched to another Mac.")
        }
        openConnection(to: deviceID, forcePairing: forcePairing)
    }

    /// Connects by address when discovery isn't possible (e.g. client-isolated Wi-Fi).
    func connect(host: String, port: UInt16) {
        guard role == .studio, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        lastFailure = nil
        let transport = NetworkTransport(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort), queue: Self.makeLinkQueue())
        startOutgoing(transport: transport, expectedPeer: nil, mode: .session, manualAddress: (host, port))
    }

    func disconnect() {
        desiredSourceID = nil
        reconnectTask?.cancel()
        reconnectAt = nil
        for connection in connections where connection.direction == .outgoing {
            connection.close(reason: "Disconnected by the other Mac's user.")
        }
    }

    func disconnect(_ connection: PeerConnection) {
        if connection.direction == .outgoing { desiredSourceID = nil }
        connection.close(reason: "Disconnected by the other Mac's user.")
    }

    func cancelPairing() {
        desiredSourceID = nil
        for connection in connections where connection.isPairingAttempt && !connection.isConnected {
            connection.close(reason: "Pairing cancelled.")
        }
    }

    func forget(_ deviceID: String) {
        if desiredSourceID == deviceID { desiredSourceID = nil }
        for connection in connections where connection.peer?.id == deviceID {
            connection.close(reason: "This Mac was unpaired.")
        }
        trust.forget(deviceID)
        if settings.lastSourceID == deviceID { settings.lastSourceID = nil }
        rebuildNearby()
    }

    // MARK: Source actions

    func respondToPairing(accept: Bool) {
        guard let request = pendingPairing else { return }
        pendingPairing = nil
        guard let connection = connections.first(where: { $0.id == request.id }) else { return }
        if !accept { pairingDeniedUntil[request.peer.id] = Date().addingTimeInterval(10) }
        connection.decidePairing(accept: accept)
    }

    // MARK: Listening (Source)

    private func startListening() {
        let listener = BonjourListener(identity: identity, role: .source, queue: discoveryQueue)
        listener.onStateChange = { [weak self] state in onMain { self?.listenerState = state } }
        listener.onIncomingTransport = { [weak self] transport in
            onMain { self?.acceptIncoming(transport) }
        }
        self.listener = listener
        listener.start()
        if settings.bluetoothEnabled { startAdvertisingBluetooth() }
    }

    private func startAdvertisingBluetooth() {
        let info = BluetoothPeerInfo(id: identity.id, name: identity.name, model: identity.model)
        let advertiser = BluetoothAdvertiser(queue: bluetoothQueue, info: info)
        advertiser.onStateChange = { [weak self] state in onMain { self?.bluetoothState = state } }
        advertiser.onIncomingTransport = { [weak self] transport in
            onMain { self?.acceptIncoming(transport) }
        }
        self.advertiser = advertiser
        bluetoothQueue.async { advertiser.start() }
    }

    private func acceptIncoming(_ transport: ByteTransport) {
        guard role == .source else {
            transport.queue.async { transport.close() }
            return
        }
        let live = connections.filter(\.phase.isLive).count
        guard live < Self.maxIncomingSessions + 2 else {
            transport.queue.async { transport.close() }
            return
        }
        let policy = ResponderPolicy(
            acceptsPairing: settings.acceptPairingRequests,
            isBusy: pendingPairing != nil
        )
        let session = SecureSession(role: .responder(policy: policy), identity: identity, keyStore: trust.keyStore)
        let link = PeerLink(transport: transport, session: session)
        let connection = makeConnection(link: link, direction: .incoming, isPairingAttempt: false, expectedPeer: nil)
        transport.queue.async { link.start() }
        _ = connection
    }

    // MARK: Browsing (Studio)

    private func startBrowsing() {
        let browser = BonjourBrowser(ownDeviceID: identity.id, queue: discoveryQueue)
        browser.onStateChange = { [weak self] state in onMain { self?.browserState = state } }
        browser.onChange = { [weak self] discoveries in
            onMain { self?.updateNetworkDiscoveries(discoveries) }
        }
        self.browser = browser
        browser.start()
        if settings.bluetoothEnabled { startBluetoothBrowsing() }
    }

    private func startBluetoothBrowsing() {
        let browser = BluetoothBrowser(queue: bluetoothQueue)
        browser.onStateChange = { [weak self] state in onMain { self?.bluetoothState = state } }
        browser.onDiscoveriesChanged = { [weak self] discoveries in
            onMain { self?.updateBluetoothDiscoveries(discoveries) }
        }
        bluetoothBrowser = browser
        bluetoothQueue.async { browser.startScanning() }
    }

    private func updateNetworkDiscoveries(_ discoveries: [NetworkDiscovery]) {
        var byID: [String: NetworkDiscovery] = [:]
        for discovery in discoveries where discovery.role != .studio {
            if var existing = byID[discovery.deviceID] {
                existing.links = Array(Set(existing.links + discovery.links))
                byID[discovery.deviceID] = existing
            } else {
                byID[discovery.deviceID] = discovery
            }
        }
        networkDiscoveries = byID
        rebuildNearby()
        if AppEnvironment.autoPair, desiredSourceID == nil, connections.isEmpty, let first = byID.keys.sorted().first {
            connect(to: first)
        }
        maybeAutoConnect()
    }

    private func updateBluetoothDiscoveries(_ discoveries: [BluetoothBrowser.Discovery]) {
        var byID: [String: BluetoothBrowser.Discovery] = [:]
        for discovery in discoveries where discovery.info.id != identity.id {
            byID[discovery.info.id] = discovery
        }
        bluetoothDiscoveries = byID
        rebuildNearby()
        maybeAutoConnect()
    }

    private func rebuildNearby() {
        var devices: [String: NearbyDevice] = [:]
        for (id, discovery) in networkDiscoveries {
            devices[id] = NearbyDevice(
                id: id, name: discovery.name, model: discovery.model, role: discovery.role,
                networkLinks: discovery.links, isOnNetwork: true, isOnBluetooth: false,
                bluetoothRSSI: nil, isTrusted: trust.isTrusted(id)
            )
        }
        for (id, discovery) in bluetoothDiscoveries {
            if devices[id] != nil {
                devices[id]?.isOnBluetooth = true
                devices[id]?.bluetoothRSSI = discovery.rssi
            } else {
                devices[id] = NearbyDevice(
                    id: id, name: discovery.info.name, model: discovery.info.model, role: .source,
                    networkLinks: [], isOnNetwork: false, isOnBluetooth: true,
                    bluetoothRSSI: discovery.rssi, isTrusted: trust.isTrusted(id)
                )
            }
        }
        // Paired Macs that aren't around right now still show up (as offline).
        for peer in trust.peers where devices[peer.id] == nil {
            devices[peer.id] = NearbyDevice(
                id: peer.id, name: peer.name, model: peer.model, role: nil,
                networkLinks: [], isOnNetwork: false, isOnBluetooth: false,
                bluetoothRSSI: nil, isTrusted: true
            )
        }
        nearby = devices.values.sorted {
            if $0.isTrusted != $1.isTrusted { return $0.isTrusted }
            if $0.isReachable != $1.isReachable { return $0.isReachable }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Outgoing connections

    private static func makeLinkQueue() -> DispatchQueue {
        DispatchQueue(label: "tandem.link", qos: .userInteractive)
    }

    private func openConnection(to deviceID: String, forcePairing: Bool) {
        guard connection(for: deviceID) == nil, !connectingDeviceIDs.contains(deviceID) else { return }
        let mode: HandshakeMode = forcePairing || !trust.isTrusted(deviceID) ? .pair : .session
        let expected = nearby.first { $0.id == deviceID }?.identity ?? trust.peer(deviceID)?.identity
        let preference = settings.linkPreference

        if preference != .bluetoothOnly, let discovery = networkDiscoveries[deviceID] {
            let transport = NetworkTransport(endpoint: discovery.endpoint, queue: Self.makeLinkQueue())
            startOutgoing(transport: transport, expectedPeer: expected ?? discovery.identity, mode: mode)
            return
        }
        guard preference != .networkOnly, settings.bluetoothEnabled, let bluetoothBrowser else {
            lastFailure = (deviceID, "\(expected?.name ?? "That Mac") isn't reachable right now. Make sure Tandem is open on it.")
            scheduleReconnectIfNeeded(for: deviceID)
            return
        }
        connectingDeviceIDs.insert(deviceID)
        bluetoothQueue.async {
            bluetoothBrowser.connect(toDeviceID: deviceID) { [weak self] result in
                onMain {
                    guard let self else { return }
                    self.connectingDeviceIDs.remove(deviceID)
                    switch result {
                    case .success(let transport):
                        guard self.role == .studio, self.desiredSourceID == deviceID else {
                            transport.queue.async { transport.close() }
                            return
                        }
                        self.startOutgoing(transport: transport, expectedPeer: expected, mode: mode)
                    case .failure(let error):
                        self.lastFailure = (deviceID, error.localizedDescription)
                        self.scheduleReconnectIfNeeded(for: deviceID)
                    }
                }
            }
        }
    }

    private func startOutgoing(transport: ByteTransport, expectedPeer: DeviceIdentity?, mode: HandshakeMode, manualAddress: (String, UInt16)? = nil) {
        let session = SecureSession(
            role: .initiator(mode: mode, expectedPeerID: expectedPeer?.id),
            identity: identity,
            keyStore: trust.keyStore
        )
        let link = PeerLink(transport: transport, session: session)
        let connection = makeConnection(link: link, direction: .outgoing, isPairingAttempt: mode == .pair, expectedPeer: expectedPeer)
        if let manualAddress, mode == .session {
            manualRetry[connection.id] = manualAddress
        }
        transport.queue.async { link.start() }
    }

    @ObservationIgnored private var manualRetry: [UUID: (String, UInt16)] = [:]

    private func makeConnection(link: PeerLink, direction: PeerConnection.Direction, isPairingAttempt: Bool, expectedPeer: DeviceIdentity?) -> PeerConnection {
        let connection = PeerConnection(link: link, direction: direction, isPairingAttempt: isPairingAttempt, expectedPeer: expectedPeer)
        let router = LinkRouter()
        routers[connection.id] = router
        connections.append(connection)

        link.queue.async { [weak self] in
            link.onStateChange = { state in
                let kind = link.linkKind
                let peer = link.peer
                let fresh = link.newlyPaired
                onMain { self?.handle(state, connection: connection, linkKind: kind, peer: peer, newlyPaired: fresh) }
            }
            link.onPairingCode = { code, peer in
                onMain { self?.handlePairingCode(code, peer: peer, connection: connection) }
            }
            link.onMessage = { message in router.route(message, connection: connection) }
            link.onStats = { stats in
                let kind = link.linkKind
                router.expireStale(connection: connection)
                onMain { connection.update(stats: stats, linkKind: kind) }
            }
        }
        return connection
    }

    private func handle(_ state: PeerLinkState, connection: PeerConnection, linkKind: LinkKind, peer: DeviceIdentity?, newlyPaired: Bool) {
        connection.update(stats: connection.stats, linkKind: linkKind)
        switch state {
        case .connecting:
            connection.update(phase: .connecting)
        case .handshaking:
            connection.update(phase: .handshaking)
        case .pairing(let code):
            connection.update(phase: .pairing(code: code))
        case .established:
            guard let peer else { return }
            connection.update(peer: peer, newlyPaired: newlyPaired)
            connection.update(phase: .connected)
            established(connection, peer: peer, linkKind: linkKind)
        case .closed(let reason):
            connection.update(phase: .closed(reason))
            closed(connection, reason: reason)
        }
    }

    private func handlePairingCode(_ code: String, peer: DeviceIdentity, connection: PeerConnection) {
        connection.update(peer: peer)
        connection.update(phase: .pairing(code: code))
        guard connection.direction == .incoming else { return }
        if let until = pairingDeniedUntil[peer.id], until > Date() {
            connection.decidePairing(accept: false)
            return
        }
        if AppEnvironment.autoApprovePairing {
            connection.decidePairing(accept: true)
            return
        }
        pendingPairing = PairingRequest(id: connection.id, code: code, peer: peer)
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func established(_ connection: PeerConnection, peer: DeviceIdentity, linkKind: LinkKind) {
        trust.recordConnection(with: peer, link: linkKind)
        manualRetry[connection.id] = nil
        if pendingPairing?.id == connection.id { pendingPairing = nil }
        // A fresh session supersedes any older one with the same Mac.
        for other in connections where other.id != connection.id && other.peer?.id == peer.id {
            other.close(reason: "Replaced by a newer connection.")
        }
        if connection.direction == .outgoing {
            reconnectAttempt = 0
            reconnectAt = nil
            desiredSourceID = peer.id
            settings.lastSourceID = peer.id
            lastFailure = nil
        }
        rebuildNearby()
        connection.send(.control(.hello(PeerHello(role: role?.peerRole ?? .studio, appVersion: AppEnvironment.shortVersion))))
        log.info("Connected to \(peer.name, privacy: .private) over \(linkKind.displayName, privacy: .public)")
        onEstablished?(connection)
    }

    private func closed(_ connection: PeerConnection, reason: PeerLinkCloseReason) {
        connections.removeAll { $0.id == connection.id }
        routers[connection.id] = nil
        if pendingPairing?.id == connection.id { pendingPairing = nil }
        let deviceID = connection.peer?.id
        onClosed?(connection, reason)

        // Manual address: the Source didn't know us — pair instead.
        if let address = manualRetry.removeValue(forKey: connection.id), reason == .handshake(.notPaired) {
            let transport = NetworkTransport(
                endpoint: .hostPort(host: NWEndpoint.Host(address.0), port: NWEndpoint.Port(rawValue: address.1) ?? 0),
                queue: Self.makeLinkQueue()
            )
            startOutgoing(transport: transport, expectedPeer: nil, mode: .pair)
            return
        }

        switch reason {
        case .handshake(.authenticationFailed), .handshake(.notPaired):
            if let deviceID, trust.isTrusted(deviceID) {
                trust.forget(deviceID)
                lastFailure = (deviceID, "The pairing with \(connection.peer?.name ?? "that Mac") is no longer valid. Pair again to reconnect.")
            } else if connection.direction == .outgoing {
                lastFailure = (deviceID, reason.userMessage)
            }
            if connection.direction == .outgoing, desiredSourceID == deviceID { desiredSourceID = nil }
        case .closedLocally:
            break
        default:
            if connection.direction == .outgoing, connection.establishedAt == nil || !reason.isRecoverable {
                lastFailure = (deviceID, reason.userMessage)
            }
            if case .handshake = reason, connection.direction == .outgoing, !reason.isRecoverable {
                if desiredSourceID == deviceID { desiredSourceID = nil }
            }
        }
        rebuildNearby()
        if connection.direction == .outgoing, let deviceID, reason.isRecoverable {
            scheduleReconnectIfNeeded(for: deviceID)
        }
    }

    // MARK: Reconnect

    private func maybeAutoConnect() {
        guard role == .studio, let target = desiredSourceID, reconnectTask == nil,
              trust.isTrusted(target), connection(for: target) == nil, !connectingDeviceIDs.contains(target) else { return }
        let reachable = networkDiscoveries[target] != nil || (settings.bluetoothEnabled && bluetoothDiscoveries[target] != nil)
        if reachable { openConnection(to: target, forcePairing: false) }
    }

    private func scheduleReconnectIfNeeded(for deviceID: String) {
        guard role == .studio, desiredSourceID == deviceID, trust.isTrusted(deviceID) else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2, Double(min(reconnectAttempt, 5))) * 0.5, 15)
        reconnectAt = Date().addingTimeInterval(delay)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.reconnectAt = nil
            guard self.desiredSourceID == deviceID, self.connection(for: deviceID) == nil else { return }
            self.openConnection(to: deviceID, forcePairing: false)
        }
    }

    /// Retry immediately (e.g. after wake or a network change).
    func retryNow() {
        guard role == .studio, let target = desiredSourceID else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAt = nil
        reconnectAttempt = 0
        browser?.refresh()
        if connection(for: target) == nil { openConnection(to: target, forcePairing: false) }
    }

    private func startMaintenance() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pairingDeniedUntil = self.pairingDeniedUntil.filter { $0.value > Date() }
                self.maybeAutoConnect()
            }
        }
    }

    @ObservationIgnored private var lastPathStatus: NWPath.Status?

    private func handlePathChange(_ status: NWPath.Status) {
        defer { lastPathStatus = status }
        // Ignore the initial report; react to real changes once the network is usable.
        guard lastPathStatus != nil, status == .satisfied else { return }
        browser?.refresh()
        maybeAutoConnect()
    }

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryNow() }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            onMain { self?.handlePathChange(status) }
        }
        monitor.start(queue: discoveryQueue)
        pathMonitor = monitor
    }
}
