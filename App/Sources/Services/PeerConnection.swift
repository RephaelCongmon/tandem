import Foundation
import Observation
import TandemCore

/// A lock-protected value for handlers shared between a link queue and the main actor.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// Runs `body` on the main actor, preserving FIFO order with other hops from the
/// same queue (unlike `Task { @MainActor … }`).
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

/// Main-actor view of one `PeerLink`, plus message routing:
/// - video format/frames and audio packets stay on the link queue (`videoSink`, `audioSink`)
///   for minimum latency,
/// - snapshots are reassembled on the link queue and delivered whole,
/// - everything else arrives on the main actor via `onControl`.
@MainActor
@Observable
final class PeerConnection: Identifiable {
    enum Direction { case incoming, outgoing }

    enum Phase: Equatable {
        case connecting
        case handshaking
        case pairing(code: String)
        case connected
        case closed(PeerLinkCloseReason)

        var isLive: Bool {
            if case .closed = self { return false }
            return true
        }
    }

    let id: UUID
    let direction: Direction
    let isPairingAttempt: Bool
    @ObservationIgnored nonisolated let link: PeerLink

    private(set) var phase: Phase = .connecting
    /// Known once the handshake reveals it (or up front for outgoing connections).
    private(set) var peer: DeviceIdentity?
    private(set) var linkKind: LinkKind = .other
    private(set) var stats = LinkStats()
    private(set) var remoteHello: PeerHello?
    private(set) var establishedAt: Date?
    private(set) var newlyPaired = false
    private(set) var snapshotProgress: SnapshotAssembler.Progress?
    /// Set as soon as a close is requested, so replacements aren't blocked by it.
    private(set) var isClosing = false
    /// The transport connected (the handshake started), even if the session never came up.
    private(set) var reachedPeer = false
    /// Over the network (not Bluetooth).
    nonisolated var isNetwork: Bool { link.transport is NetworkTransport }

    @ObservationIgnored var onControl: ((ControlMessage) -> Void)?
    @ObservationIgnored var onSnapshot: ((ReceivedSnapshot) -> Void)?
    @ObservationIgnored var onSnapshotRejected: ((UUID, String) -> Void)?
    @ObservationIgnored var onSnapshotProgress: ((SnapshotAssembler.Progress) -> Void)?
    /// Called on the link queue with `.videoFormat` / `.videoFrame` messages.
    @ObservationIgnored nonisolated let videoSink = Locked<((PeerMessage) -> Void)?>(nil)
    /// Called on the link queue with video acks (Source side flow control).
    @ObservationIgnored nonisolated let ackSink = Locked<((VideoAck) -> Void)?>(nil)
    /// Called on the link queue with the Source's audio packets.
    @ObservationIgnored nonisolated let audioSink = Locked<((AudioPacket) -> Void)?>(nil)
    /// Called on the link queue with pieces of an update package (Source side).
    @ObservationIgnored nonisolated let updateSink = Locked<((UpdateChunk) -> Void)?>(nil)

    var isConnected: Bool { phase == .connected }

    /// The other Mac runs a version that can send (or receive) computer audio.
    var peerSupportsAudio: Bool { remoteHello?.capabilities.contains(PeerHello.Capability.audio) ?? false }
    var peerSupportsRegionSnapshots: Bool { remoteHello?.capabilities.contains(PeerHello.Capability.regionSnapshots) ?? false }
    /// The other Mac serves the region tool (crops while its still is captured, no preview when current).
    var peerSupportsRegionTool: Bool { remoteHello?.capabilities.contains(PeerHello.Capability.regionTool) ?? false }
    /// The other Mac shows Glance overlays.
    var peerSupportsGlance: Bool { remoteHello?.capabilities.contains(PeerHello.Capability.glance) ?? false }

    /// The other Mac installs updates this Mac sends it.
    var peerAcceptsUpdates: Bool { remoteHello?.capabilities.contains(PeerHello.Capability.peerUpdate) ?? false }

    /// The other Mac's Tandem version, once it said hello.
    var peerVersion: AppVersion? { remoteHello.flatMap { AppVersion($0.appVersion) } }

    func sendUpdatePackage(offerID: UUID, data: Data) {
        let link = self.link
        link.queue.async { link.sendUpdatePackage(offerID: offerID, data: data) }
    }

    init(link: PeerLink, direction: Direction, isPairingAttempt: Bool, expectedPeer: DeviceIdentity?) {
        id = link.id
        self.link = link
        self.direction = direction
        self.isPairingAttempt = isPairingAttempt
        peer = expectedPeer
    }

    // MARK: Actions

    func send(_ message: PeerMessage, priority: PeerLink.Priority = .control) {
        let link = self.link
        link.queue.async { link.send(message, priority: priority) }
    }

    func sendSnapshot(header: SnapshotHeader, data: Data) {
        let link = self.link
        link.queue.async { link.sendSnapshot(header: header, data: data) }
    }

    /// Closes the link. `dismiss` tells the other Mac not to reconnect on its own.
    func close(reason: String = "Disconnected", dismiss: Bool = false) {
        isClosing = true
        let link = self.link
        link.queue.async { link.close(reason: reason, dismiss: dismiss) }
    }

    func decidePairing(accept: Bool) {
        let link = self.link
        link.queue.async { link.decidePairing(accept: accept) }
    }

    // MARK: Updates from the manager (main actor)

    func update(phase: Phase) {
        self.phase = phase
        if phase == .connected, establishedAt == nil { establishedAt = Date() }
        switch phase {
        case .handshaking, .pairing, .connected: reachedPeer = true
        case .connecting, .closed: break
        }
    }

    func update(peer: DeviceIdentity?, newlyPaired: Bool? = nil) {
        if let peer { self.peer = peer }
        if let newlyPaired { self.newlyPaired = newlyPaired }
    }

    func update(stats: LinkStats, linkKind: LinkKind) {
        self.stats = stats
        self.linkKind = linkKind
    }

    func receive(_ control: ControlMessage) {
        if case .hello(let hello) = control { remoteHello = hello }
        onControl?(control)
    }

    func receive(snapshot: ReceivedSnapshot) {
        snapshotProgress = nil
        onSnapshot?(snapshot)
    }

    func receive(progress: SnapshotAssembler.Progress?) {
        snapshotProgress = progress
        if let progress { onSnapshotProgress?(progress) }
    }

    func rejectSnapshot(_ id: UUID, reason: String) {
        snapshotProgress = nil
        onSnapshotRejected?(id, reason)
    }
}

/// Link-queue-confined helper that reassembles snapshots and routes messages.
final class LinkRouter: @unchecked Sendable {
    private var assembler = SnapshotAssembler()
    private var lastProgressPost = 0.0

    func route(_ message: PeerMessage, connection: PeerConnection) {
        switch message {
        case .videoFormat, .videoFrame:
            connection.videoSink.value?(message)

        case .control(.videoAck(let ack)):
            connection.ackSink.value?(ack)

        case .audioPacket(let packet):
            connection.audioSink.value?(packet)

        case .updateChunk(let chunk):
            connection.updateSink.value?(chunk)

        case .snapshotChunk(let chunk):
            guard let event = assembler.receive(chunk) else { return }
            deliver(event, to: connection)

        case .control(.snapshotHeader(let header)):
            if let event = assembler.begin(header) { deliver(event, to: connection) }

        case .control(let control):
            onMain { connection.receive(control) }
        }
    }

    func expireStale(connection: PeerConnection) {
        for id in assembler.expireStale() {
            onMain { connection.rejectSnapshot(id, reason: "The snapshot transfer stalled.") }
        }
    }

    private func deliver(_ event: SnapshotAssembler.Event, to connection: PeerConnection) {
        switch event {
        case .progress(let progress):
            // Throttle UI updates to ~15 Hz.
            let now = monotonicSeconds()
            guard now - lastProgressPost > 0.066 || progress.receivedBytes == 0 else { return }
            lastProgressPost = now
            onMain { connection.receive(progress: progress) }
        case .completed(let snapshot):
            onMain { connection.receive(snapshot: snapshot) }
        case .rejected(let id, let reason):
            onMain { connection.rejectSnapshot(id, reason: reason) }
        }
    }
}
