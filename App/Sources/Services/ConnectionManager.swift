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
    /// Devices whose pending attempt is over Bluetooth; a network path that appears meanwhile
    /// is tried at once instead of waiting for Bluetooth to time out.
    @ObservationIgnored private var bluetoothAttempts: Set<String> = []
    @ObservationIgnored private var networkReachableTargets: Set<String> = []
    private(set) var pendingPairing: PairingRequest?
    /// The Source the Studio wants to stay connected to.
    private(set) var desiredSourceID: String?
    /// Last user-visible connection problem, per device.
    private(set) var lastFailure: (deviceID: String?, message: String)?
    private(set) var reconnectAt: Date?
    /// macOS is keeping Tandem off the local network even if System Settings shows it allowed
    /// (see `LocalNetworkAccess`); switching Tandem off and on under Local Network fixes it.
    private(set) var localNetworkBlocked = false

    @ObservationIgnored var onEstablished: ((PeerConnection) -> Void)?
    @ObservationIgnored var onClosed: ((PeerConnection, PeerLinkCloseReason) -> Void)?
    /// A pairing request is waiting for someone at this Mac.
    @ObservationIgnored var onNeedsDecision: (() -> Void)?

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
    /// Studios the Source user sent away; their reconnects are refused for a while.
    @ObservationIgnored private var sessionDeniedUntil: [String: Date] = [:]
    @ObservationIgnored private var reachableTargets: Set<String> = []
    @ObservationIgnored private var localNetworkCheck: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Connections")

    static let maxIncomingSessions = 4

    static let localNetworkBlockedMessage = "macOS isn't letting Tandem use the local network, so it can't reach your other Mac. Allow Tandem in Privacy & Security › Local Network. If it's already on, switch it off and back on."
    static let localNetworkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

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
        checkLocalNetwork()
    }

    func deactivate() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAt = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        localNetworkCheck?.cancel()
        localNetworkCheck = nil
        localNetworkBlocked = false
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
        connectingDeviceIDs.removeAll()
        bluetoothAttempts.removeAll()
        reachableTargets.removeAll()
        networkReachableTargets.removeAll()
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
                // Pending Bluetooth connects die with the browser.
                connectingDeviceIDs.removeAll()
                bluetoothAttempts.removeAll()
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

    /// The live (not closing) connection with a device.
    func connection(for deviceID: String) -> PeerConnection? {
        connections.first { $0.peer?.id == deviceID && $0.phase.isLive && !$0.isClosing }
    }

    func isConnecting(to deviceID: String) -> Bool {
        connectingDeviceIDs.contains(deviceID) || connections.contains {
            $0.peer?.id == deviceID && !$0.isConnected && $0.phase.isLive && !$0.isClosing
        }
    }

    func needsRepair(_ deviceID: String) -> Bool { trust.needsRepair(deviceID) }

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
        // One Source at a time; re-pairing replaces the current session too.
        for connection in connections where connection.peer?.id != deviceID || forcePairing {
            connection.close(reason: forcePairing ? "Pairing again." : "Switched to another Mac.")
        }
        openConnection(to: deviceID, forcePairing: forcePairing || trust.needsRepair(deviceID))
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

    /// Ends a session on purpose. From the Source this tells the Studio not to
    /// reconnect, and briefly refuses its reconnects.
    func disconnect(_ connection: PeerConnection) {
        if connection.direction == .outgoing {
            desiredSourceID = nil
            connection.close(reason: "Disconnected by the other Mac's user.")
        } else {
            if let id = connection.peer?.id { sessionDeniedUntil[id] = Date().addingTimeInterval(15) }
            connection.close(reason: "\(identity.name) ended the session.", dismiss: true)
        }
    }

    /// Source: refuse this Studio's sessions for a while (after "Don't Allow").
    func denySessions(from deviceID: String, for seconds: TimeInterval = 30) {
        sessionDeniedUntil[deviceID] = Date().addingTimeInterval(seconds)
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
        guard connection(for: deviceID) == nil else { return }
        let networkPreempts = bluetoothAttempts.contains(deviceID) && networkDiscoveries[deviceID] != nil && settings.linkPreference != .bluetoothOnly
        guard !connectingDeviceIDs.contains(deviceID) || networkPreempts else { return }
        let forcePairing = forcePairing || trust.needsRepair(deviceID)
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
        bluetoothAttempts.insert(deviceID)
        // Belt and braces: never leave a device stuck in "connecting".
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.connectingDeviceIDs.remove(deviceID) != nil else { return }
            self.bluetoothAttempts.remove(deviceID)
            self.lastFailure = (deviceID, "Couldn't reach that Mac over Bluetooth.")
            self.scheduleReconnectIfNeeded(for: deviceID)
        }
        bluetoothQueue.async {
            bluetoothBrowser.connect(toDeviceID: deviceID) { [weak self] result in
                onMain {
                    guard let self else { return }
                    self.connectingDeviceIDs.remove(deviceID)
                    self.bluetoothAttempts.remove(deviceID)
                    switch result {
                    case .success(let transport):
                        // A network connection that started meanwhile wins.
                        guard self.role == .studio, self.desiredSourceID == deviceID, self.connection(for: deviceID) == nil else {
                            transport.queue.async { transport.close() }
                            return
                        }
                        self.startOutgoing(transport: transport, expectedPeer: expected, mode: mode)
                    case .failure(let error):
                        guard self.connection(for: deviceID) == nil else { return }
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
        // One pairing prompt at a time; a second concurrent request is declined.
        if let pending = pendingPairing, pending.id != connection.id,
           connections.contains(where: { $0.id == pending.id && $0.phase.isLive }) {
            connection.decidePairing(accept: false)
            return
        }
        if let until = pairingDeniedUntil[peer.id], until > Date() {
            connection.decidePairing(accept: false)
            return
        }
        if AppEnvironment.autoApprovePairing {
            connection.decidePairing(accept: true)
            return
        }
        pendingPairing = PairingRequest(id: connection.id, code: code, peer: peer)
        onNeedsDecision?()
    }

    private func established(_ connection: PeerConnection, peer: DeviceIdentity, linkKind: LinkKind) {
        if connection.direction == .incoming, let until = sessionDeniedUntil[peer.id], until > Date() {
            connection.close(reason: "\(identity.name) isn't accepting this Mac right now.", dismiss: true)
            return
        }
        trust.recordConnection(with: peer, link: linkKind)
        manualRetry[connection.id] = nil
        if pendingPairing?.id == connection.id { pendingPairing = nil }
        // A fresh session supersedes any older one with the same Mac.
        for other in connections where other.id != connection.id && other.peer?.id == peer.id {
            other.close(reason: "Replaced by a newer connection.")
        }
        if connection.direction == .outgoing {
            reconnectAt = nil
            desiredSourceID = peer.id
            settings.lastSourceID = peer.id
            lastFailure = nil
        }
        rebuildNearby()
        connection.send(.control(.hello(PeerHello(role: role?.peerRole ?? .studio, appVersion: AppEnvironment.shortVersion, capabilities: [PeerHello.Capability.audio, PeerHello.Capability.peerUpdate, PeerHello.Capability.regionSnapshots, PeerHello.Capability.regionTool]))))
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

        // A session that stayed up for a while resets the backoff.
        if let established = connection.establishedAt, Date().timeIntervalSince(established) > 30 {
            reconnectAttempt = 0
        }
        let name = connection.peer?.name ?? "That Mac"
        switch reason {
        case .handshake(.authenticationFailed), .handshake(.notPaired):
            // Never delete keys automatically: these failures can be spoofed or
            // transient. Ask the user to pair again instead.
            if let deviceID, trust.isTrusted(deviceID), connection.direction == .outgoing {
                trust.markNeedsRepair(deviceID)
                lastFailure = (deviceID, "\(name) no longer recognizes this pairing. Pair again to reconnect.")
            } else if connection.direction == .outgoing {
                lastFailure = (deviceID, reason.userMessage)
            }
            if connection.direction == .outgoing, desiredSourceID == deviceID { desiredSourceID = nil }
        case .dismissedByPeer(let message):
            if connection.direction == .outgoing {
                if desiredSourceID == deviceID { desiredSourceID = nil }
                lastFailure = (deviceID, message ?? "\(name) ended the session.")
            }
        case .closedLocally:
            break
        default:
            if connection.direction == .outgoing, connection.establishedAt == nil || !reason.isRecoverable {
                lastFailure = (deviceID, failureMessage(for: connection, reason: reason))
            }
            if case .handshake = reason, connection.direction == .outgoing, !reason.isRecoverable {
                if desiredSourceID == deviceID { desiredSourceID = nil }
            }
        }
        rebuildNearby()
        // A network attempt that never got through may be macOS blocking Tandem.
        if connection.direction == .outgoing, connection.isNetwork, !connection.reachedPeer, reason != .closedLocally {
            checkLocalNetwork()
        }
        if connection.direction == .outgoing, let deviceID, reason.isRecoverable {
            scheduleReconnectIfNeeded(for: deviceID)
        }
    }

    /// What to tell the user about a session that didn't come up (or dropped).
    private func failureMessage(for connection: PeerConnection, reason: PeerLinkCloseReason) -> String {
        guard connection.establishedAt == nil, connection.isNetwork else { return reason.userMessage }
        let name = connection.peer?.name ?? "The other Mac"
        if localNetworkBlocked { return Self.localNetworkBlockedMessage }
        switch reason {
        case .timedOut where connection.reachedPeer:
            // The Mac took the connection, but Tandem there never answered.
            return "\(name) took the connection, but Tandem on it isn't answering. If this keeps happening, quit and reopen Tandem on \(name)."
        case .timedOut, .transport:
            return "Couldn't reach \(name) over the network. Make sure Tandem is open on it. If it was just updated, macOS may be blocking it there: on \(name), switch Tandem off and back on in System Settings › Privacy & Security › Local Network."
        default:
            return reason.userMessage
        }
    }

    // MARK: Local network access

    /// Asks macOS whether Tandem may use the local network, and reconnects once it may again.
    func checkLocalNetwork() {
        guard role != nil, localNetworkCheck == nil else { return }
        #if DEBUG
        if simulatedLocalNetwork != nil { return }
        #endif
        localNetworkCheck = Task { [weak self] in
            let access = await LocalNetworkAccess.check()
            guard !Task.isCancelled, let self else { return }
            self.localNetworkCheck = nil
            self.apply(access)
        }
    }

    #if DEBUG
    /// Shows the blocked state without a blocked Mac (UI checks); `.allowed` ends it.
    func debugSimulateLocalNetwork(_ access: LocalNetworkAccess) {
        simulatedLocalNetwork = access == .allowed ? nil : access
        apply(access)
    }
    @ObservationIgnored private var simulatedLocalNetwork: LocalNetworkAccess?
    #endif

    private func apply(_ access: LocalNetworkAccess) {
        switch access {
        case .denied:
            if !localNetworkBlocked { log.error("macOS is blocking Tandem from the local network") }
            localNetworkBlocked = true
            if role == .studio, let target = desiredSourceID ?? settings.lastSourceID {
                lastFailure = (target, Self.localNetworkBlockedMessage)
            }
        case .allowed:
            guard localNetworkBlocked else { return }
            localNetworkBlocked = false
            log.notice("Local network access is back")
            if lastFailure?.message == Self.localNetworkBlockedMessage { lastFailure = nil }
            browser?.refresh()
            retryNow()
        case .unknown:
            break
        }
    }

    // MARK: Reconnect

    /// Reconnects to the chosen Source when it's reachable. A Source that just
    /// (re)appeared is tried right away; otherwise pending backoff is respected.
    private func maybeAutoConnect() {
        guard role == .studio, let target = desiredSourceID else {
            reachableTargets.removeAll()
            networkReachableTargets.removeAll()
            return
        }
        let onNetwork = networkDiscoveries[target] != nil
        let reachable = onNetwork || (settings.bluetoothEnabled && bluetoothDiscoveries[target] != nil)
        let newlyOnNetwork = onNetwork && !networkReachableTargets.contains(target)
        let newlyAppeared = (reachable && !reachableTargets.contains(target)) || newlyOnNetwork
        if reachable { reachableTargets.insert(target) } else { reachableTargets.remove(target) }
        if onNetwork { networkReachableTargets.insert(target) } else { networkReachableTargets.remove(target) }
        // A slow Bluetooth attempt doesn't block a network path that just showed up.
        let networkPreempts = newlyOnNetwork && bluetoothAttempts.contains(target)
        guard reachable, trust.isTrusted(target), !trust.needsRepair(target),
              connection(for: target) == nil, !connectingDeviceIDs.contains(target) || networkPreempts else { return }
        if reconnectTask != nil {
            guard newlyAppeared else { return }
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAt = nil
        }
        openConnection(to: target, forcePairing: false)
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
                self.sessionDeniedUntil = self.sessionDeniedUntil.filter { $0.value > Date() }
                if self.localNetworkBlocked { self.checkLocalNetwork() }
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
        checkLocalNetwork()
        maybeAutoConnect()
    }

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkLocalNetwork()
                self?.retryNow()
            }
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
