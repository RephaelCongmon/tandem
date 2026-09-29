import Foundation
import os

/// Wall-clock nanoseconds since 1970 (comparable across Macs after offset correction).
public func wallClockNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

/// Monotonic seconds, for timeouts.
public func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// Live health numbers for a link, refreshed about once a second.
public struct LinkStats: Sendable, Equatable {
    /// Smoothed round-trip time in milliseconds.
    public var rttMillis: Double?
    /// `peerClock - localClock` in nanoseconds, from the lowest-RTT recent ping.
    public var clockOffsetNanos: Int64?
    public var sendBitsPerSecond: Double = 0
    public var receiveBitsPerSecond: Double = 0
    /// Bytes queued inside the link that haven't been handed to the OS yet.
    public var queuedBytes: Int = 0

    public init() {}
}

public enum PeerLinkCloseReason: Sendable, Equatable {
    case handshake(HandshakeFailure)
    case transport(TransportError)
    case timedOut
    case closedByPeer(String?)
    /// The other Mac's user ended the session on purpose; don't reconnect.
    case dismissedByPeer(String?)
    case closedLocally
    case protocolError(String)

    public var userMessage: String {
        switch self {
        case .handshake(let failure): return failure.localizedDescription
        case .transport(let error): return error.localizedDescription
        case .timedOut: return "The other Mac stopped responding."
        case .closedByPeer(let reason): return reason ?? "The other Mac disconnected."
        case .dismissedByPeer(let reason): return reason ?? "The other Mac ended the session."
        case .closedLocally: return "Disconnected."
        case .protocolError(let detail): return "Connection error: \(detail)"
        }
    }

    /// Whether automatically reconnecting makes sense.
    public var isRecoverable: Bool {
        switch self {
        case .transport, .timedOut, .closedByPeer: return true
        case .handshake(let failure):
            if case .busy = failure { return true }
            return false
        case .closedLocally, .protocolError, .dismissedByPeer: return false
        }
    }
}

public enum PeerLinkState: Sendable, Equatable {
    case connecting
    case handshaking
    /// Both Macs display `code`; the responder's user must approve.
    case pairing(code: String)
    case established
    case closed(PeerLinkCloseReason)
}

/// One authenticated, encrypted session with another Mac over any `ByteTransport`.
///
/// Outbound messages are queued by priority (control → bulk → video) and sealed
/// only when handed to the transport, so record counters always match wire order.
/// All state lives on the transport's serial queue; callbacks fire there too.
public final class PeerLink {
    public enum Priority: Sendable {
        /// Small, latency-critical messages (acks, requests, status).
        case control
        /// Snapshot chunks: large but user-visible, so ahead of live video.
        case bulk
        /// Live preview frames.
        case video
    }

    public let id = UUID()
    public let isInitiator: Bool
    public let transport: ByteTransport
    public var queue: DispatchQueue { transport.queue }
    public var linkKind: LinkKind { transport.linkKind }

    public private(set) var state: PeerLinkState = .connecting
    public private(set) var peer: DeviceIdentity?
    public private(set) var newlyPaired = false
    public private(set) var stats = LinkStats()

    public var onStateChange: ((PeerLinkState) -> Void)?
    /// Responder: show the code and call `decidePairing`. Initiator: show the code.
    public var onPairingCode: ((String, DeviceIdentity) -> Void)?
    public var onMessage: ((PeerMessage) -> Void)?
    public var onStats: ((LinkStats) -> Void)?

    private let session: SecureSession
    private var decoder = FrameDecoder()
    private var rawQueue: [Data] = []
    private var controlQueue: [Data] = []
    private var bulkQueue: [Data] = []
    private var videoQueue: [Data] = []
    private var queuedBytes = 0
    private var inFlightBytes = 0
    private var closeAfterFlush: PeerLinkCloseReason?
    private var isClosed = false

    private var timer: DispatchSourceTimer?
    private var lastReceive = monotonicSeconds()
    private var handshakeDeadline: Double
    private var pingCounter: UInt32 = 0
    private var rttSamples: [(rtt: Double, offset: Int64)] = []
    private var smoothedRTT: Double?
    private var bytesSentWindow = 0
    private var bytesReceivedWindow = 0
    private var windowStart = monotonicSeconds()

    private let log = Logger(subsystem: "com.rofel.tandem", category: "PeerLink")

    public static let idleTimeout: Double = 10
    public static let handshakeTimeout: Double = 15
    public static let pairingTimeout: Double = 120

    public init(transport: ByteTransport, session: SecureSession) {
        self.transport = transport
        self.session = session
        if case .initiator = session.role { isInitiator = true } else { isInitiator = false }
        handshakeDeadline = monotonicSeconds() + Self.handshakeTimeout
    }

    deinit {
        timer?.cancel()
    }

    // MARK: Lifecycle

    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        transport.onStateChange = { [weak self] state in self?.handleTransport(state) }
        transport.onReceive = { [weak self] data in self?.handleReceive(data) }
        startTimer()
        transport.start()
    }

    /// Sends a goodbye (best effort) and closes. With `dismiss`, the peer is told
    /// the local user ended the session on purpose, so it shouldn't reconnect.
    public func close(reason: String = "Disconnected", dismiss: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        if case .established = state {
            enqueue(.control(dismiss ? .dismissed(reason: reason) : .goodbye(reason: reason)), priority: .control)
            closeAfterFlush = .closedLocally
            pump()
            // Don't wait long for the goodbye to drain.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish(.closedLocally) }
        } else {
            finish(.closedLocally)
        }
    }

    /// Responder only: the local user approved or declined the displayed code.
    public func decidePairing(accept: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        process(session.decidePairing(accept: accept))
    }

    // MARK: Sending

    public func send(_ message: PeerMessage, priority: Priority = .control) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        enqueue(message, priority: priority)
        pump()
    }

    /// Sends a header followed by the image bytes split into chunks. The chunk
    /// count and byte count are always computed here, from the link in use.
    public func sendSnapshot(header proposed: SnapshotHeader, data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, !data.isEmpty else { return }
        let link = linkKind
        var header = proposed
        header.byteCount = data.count
        header.chunkCount = Self.chunkCount(byteCount: data.count, link: link)
        enqueue(.control(.snapshotHeader(header)), priority: .bulk)
        let chunkSize = Self.snapshotChunkSize(for: link)
        for index in 0..<header.chunkCount {
            let start = index * chunkSize
            let end = min(start + chunkSize, data.count)
            let chunk = SnapshotChunk(snapshotID: header.id, index: index, count: header.chunkCount, data: data.subdata(in: start..<end))
            enqueue(.snapshotChunk(chunk), priority: .bulk)
        }
        pump()
    }

    public static func snapshotChunkSize(for link: LinkKind) -> Int {
        link.isConstrained ? 16 * 1024 : 128 * 1024
    }

    public static func chunkCount(byteCount: Int, link: LinkKind) -> Int {
        max(1, (byteCount + snapshotChunkSize(for: link) - 1) / snapshotChunkSize(for: link))
    }

    /// Bytes waiting in the link (not yet handed to the OS) plus bytes the OS
    /// hasn't confirmed. Video producers use this to skip frames instead of queuing.
    public var backlogBytes: Int { queuedBytes + inFlightBytes }

    public var hasQueuedVideo: Bool { !videoQueue.isEmpty }

    private func enqueue(_ message: PeerMessage, priority: Priority) {
        let encoded: Data
        do {
            encoded = try PeerMessageCodec.encode(message)
        } catch {
            log.error("Failed to encode message: \(String(describing: error), privacy: .public)")
            return
        }
        queuedBytes += encoded.count
        switch priority {
        case .control: controlQueue.append(encoded)
        case .bulk: bulkQueue.append(encoded)
        case .video: videoQueue.append(encoded)
        }
    }

    private func pump() {
        guard !isClosed else { return }
        let window = transport.preferredWindowBytes
        while inFlightBytes < window {
            let frame: Data
            if !rawQueue.isEmpty {
                frame = rawQueue.removeFirst()
            } else if session.isEstablished, let plaintext = dequeueApplicationMessage() {
                queuedBytes -= plaintext.count
                do {
                    frame = try session.seal(plaintext)
                } catch {
                    finish(.protocolError("seal failed"))
                    return
                }
            } else {
                break
            }
            let framed = FrameCodec.encode(frame)
            inFlightBytes += framed.count
            bytesSentWindow += framed.count
            transport.send(framed) { [weak self] error in
                guard let self else { return }
                self.inFlightBytes -= framed.count
                if let error {
                    self.finish(.transport((error as? TransportError) ?? .connectionLost(error.localizedDescription)))
                    return
                }
                self.pump()
            }
        }
        if let reason = closeAfterFlush, rawQueue.isEmpty, controlQueue.isEmpty, inFlightBytes == 0 {
            finish(reason)
        }
    }

    private func dequeueApplicationMessage() -> Data? {
        if !controlQueue.isEmpty { return controlQueue.removeFirst() }
        if !bulkQueue.isEmpty { return bulkQueue.removeFirst() }
        if !videoQueue.isEmpty { return videoQueue.removeFirst() }
        return nil
    }

    // MARK: Receiving

    private func handleTransport(_ transportState: TransportState) {
        switch transportState {
        case .connecting:
            break
        case .ready:
            lastReceive = monotonicSeconds()
            setState(.handshaking)
            process(session.start())
        case .failed(let error):
            finish(.transport(error))
        case .closed:
            if case .established = state {
                finish(.closedByPeer(nil))
            } else {
                finish(.transport(.connectionLost("closed during handshake")))
            }
        }
    }

    private func handleReceive(_ data: Data) {
        guard !isClosed else { return }
        lastReceive = monotonicSeconds()
        bytesReceivedWindow += data.count
        let frames: [Data]
        do {
            frames = try decoder.append(data)
        } catch {
            finish(.protocolError("oversized frame"))
            return
        }
        for frame in frames {
            guard !isClosed else { return }
            process(session.receive(frame))
        }
    }

    private func process(_ outputs: [SecureSession.Output]) {
        var failure: HandshakeFailure?
        for output in outputs {
            switch output {
            case .send(let data):
                rawQueue.append(data)
            case .pairingCode(let code, let identity):
                peer = identity
                handshakeDeadline = monotonicSeconds() + Self.pairingTimeout
                setState(.pairing(code: code))
                onPairingCode?(code, identity)
            case .established(let identity, let fresh):
                peer = identity
                newlyPaired = fresh
                setState(.established)
                sendPing()
            case .message(let data):
                handleApplication(data)
            case .failed(let reason):
                failure = reason
            }
        }
        if let failure {
            // Flush a pending rejection/decline frame before closing.
            closeAfterFlush = .handshake(failure)
            pump()
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish(.handshake(failure)) }
        } else {
            pump()
        }
    }

    private func handleApplication(_ data: Data) {
        let message: PeerMessage
        do {
            message = try PeerMessageCodec.decode(data)
        } catch {
            // Newer peers may send messages we don't understand; skip them.
            log.info("Ignoring undecodable message: \(String(describing: error), privacy: .public)")
            return
        }
        switch message {
        case .control(.ping(let ping)):
            let now = wallClockNanos()
            send(.control(.pong(PongPayload(id: ping.id, pingSentAt: ping.sentAt, receivedAt: now, sentAt: wallClockNanos()))))
        case .control(.pong(let pong)):
            handlePong(pong)
        case .control(.goodbye(let reason)):
            finish(.closedByPeer(reason))
        case .control(.dismissed(let reason)):
            finish(.dismissedByPeer(reason))
        default:
            onMessage?(message)
        }
    }

    // MARK: Keepalive, RTT and clock offset

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private var tickCount = 0

    private func tick() {
        guard !isClosed else { return }
        let now = monotonicSeconds()
        switch state {
        case .established:
            if now - lastReceive > Self.idleTimeout {
                finish(.timedOut)
                return
            }
            tickCount += 1
            if tickCount % 2 == 0 { sendPing() }
        case .connecting, .handshaking, .pairing:
            if now > handshakeDeadline {
                switch state {
                case .pairing:
                    finish(.handshake(.pairingDeclined("The pairing request timed out.")))
                default:
                    // A stalled network or handshake is worth retrying.
                    finish(.timedOut)
                }
                return
            }
        case .closed:
            return
        }

        let elapsed = max(now - windowStart, 0.001)
        stats.sendBitsPerSecond = Double(bytesSentWindow * 8) / elapsed
        stats.receiveBitsPerSecond = Double(bytesReceivedWindow * 8) / elapsed
        stats.queuedBytes = queuedBytes
        bytesSentWindow = 0
        bytesReceivedWindow = 0
        windowStart = now
        onStats?(stats)
    }

    private func sendPing() {
        pingCounter &+= 1
        send(.control(.ping(PingPayload(id: pingCounter, sentAt: wallClockNanos()))))
    }

    private func handlePong(_ pong: PongPayload) {
        let now = wallClockNanos()
        // NTP-style: t0 = pingSentAt, t1 = receivedAt, t2 = sentAt, t3 = now.
        let t0 = Int64(bitPattern: pong.pingSentAt)
        let t1 = Int64(bitPattern: pong.receivedAt)
        let t2 = Int64(bitPattern: pong.sentAt)
        let t3 = Int64(bitPattern: now)
        let rttNanos = max(0, (t3 - t0) - (t2 - t1))
        let offset = ((t1 - t0) + (t2 - t3)) / 2
        let rttMillis = Double(rttNanos) / 1_000_000
        smoothedRTT = smoothedRTT.map { $0 * 0.8 + rttMillis * 0.2 } ?? rttMillis
        rttSamples.append((rttMillis, offset))
        if rttSamples.count > 8 { rttSamples.removeFirst() }
        stats.rttMillis = smoothedRTT
        stats.clockOffsetNanos = rttSamples.min { $0.rtt < $1.rtt }?.offset
    }

    // MARK: State

    private func setState(_ newState: PeerLinkState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func finish(_ reason: PeerLinkCloseReason) {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        rawQueue.removeAll()
        controlQueue.removeAll()
        bulkQueue.removeAll()
        videoQueue.removeAll()
        queuedBytes = 0
        transport.close()
        transport.onReceive = nil
        transport.onStateChange = nil
        if case .closedLocally = reason {} else {
            log.info("Link closed: \(reason.userMessage, privacy: .public)")
        }
        setState(.closed(reason))
        onMessage = nil
        onPairingCode = nil
        onStats = nil
        onStateChange = nil
    }
}

// All mutable state is confined to the transport's serial queue.
extension PeerLink: @unchecked Sendable {}
