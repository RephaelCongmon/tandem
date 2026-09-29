import Network
import XCTest
@testable import TandemCore

/// End-to-end: two PeerLinks talking over real TCP on the loopback interface.
final class PeerLinkLoopbackTests: XCTestCase {
    private let source = DeviceIdentity(id: UUID().uuidString, name: "Source Mac", model: "MacBookPro18,1;laptop")
    private let studio = DeviceIdentity(id: UUID().uuidString, name: "Studio Mac", model: "Mac14,2;laptop")
    private let sourceKeys = InMemoryPairingKeyStore()
    private let studioKeys = InMemoryPairingKeyStore()

    private var listener: NWListener?
    private var sourceLink: PeerLink?
    private var studioLink: PeerLink?

    override func tearDown() {
        listener?.cancel()
        let links = [sourceLink, studioLink].compactMap { $0 }
        for link in links { link.queue.sync { link.close() } }
        super.tearDown()
    }

    /// Starts a loopback listener; each accepted connection becomes a responder link.
    private func startListener(policy: ResponderPolicy, onLink: @escaping (PeerLink) -> Void) throws -> UInt16 {
        let listener = try NWListener(using: TandemNetwork.parameters(peerToPeer: false))
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { [source, sourceKeys] connection in
            let transport = NetworkTransport(connection: connection, queue: DispatchQueue(label: "test.source"))
            let session = SecureSession(role: .responder(policy: policy), identity: source, keyStore: sourceKeys)
            let link = PeerLink(transport: transport, session: session)
            transport.queue.async {
                onLink(link)
                link.start()
            }
        }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        self.listener = listener
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(listener.port?.rawValue)
    }

    private func makeStudioLink(port: UInt16, mode: HandshakeMode) -> PeerLink {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let transport = NetworkTransport(endpoint: endpoint, queue: DispatchQueue(label: "test.studio"))
        let session = SecureSession(role: .initiator(mode: mode, expectedPeerID: source.id), identity: studio, keyStore: studioKeys)
        return PeerLink(transport: transport, session: session)
    }

    private func pairOverLoopback() throws {
        let sourceEstablished = expectation(description: "source established")
        let studioEstablished = expectation(description: "studio established")
        var codes: [String] = []
        let codesLock = NSLock()

        let port = try startListener(policy: ResponderPolicy(acceptsPairing: true)) { [weak self] link in
            self?.sourceLink = link
            link.onPairingCode = { code, peer in
                XCTAssertEqual(peer.id, self?.studio.id)
                codesLock.lock(); codes.append(code); codesLock.unlock()
                link.decidePairing(accept: true)
            }
            link.onStateChange = { state in if state == .established { sourceEstablished.fulfill() } }
        }
        let studioLink = makeStudioLink(port: port, mode: .pair)
        self.studioLink = studioLink
        studioLink.queue.async {
            studioLink.onPairingCode = { code, _ in codesLock.lock(); codes.append(code); codesLock.unlock() }
            studioLink.onStateChange = { state in if state == .established { studioEstablished.fulfill() } }
            studioLink.start()
        }
        wait(for: [sourceEstablished, studioEstablished], timeout: 10)
        XCTAssertEqual(codes.count, 2)
        XCTAssertEqual(Set(codes).count, 1, "both Macs must show the same code")
        XCTAssertNotNil(sourceKeys.key(for: studio.id))
        XCTAssertNotNil(studioKeys.key(for: source.id))
        studioLink.queue.sync { XCTAssertEqual(studioLink.linkKind, .loopback) }
    }

    func testPairThenReconnectAndExchangeMessagesAndSnapshot() throws {
        try pairOverLoopback()
        // Drop the pairing connection and reconnect in session mode.
        if let link = studioLink { link.queue.sync { link.close() } }
        listener?.cancel()
        sourceLink = nil
        studioLink = nil

        let sourceReady = expectation(description: "source session")
        let studioReady = expectation(description: "studio session")
        let gotRequest = expectation(description: "source got snapshot request")
        let gotSnapshot = expectation(description: "studio got snapshot")
        let gotFrames = expectation(description: "studio got video frames")
        gotFrames.expectedFulfillmentCount = 30

        let image = Data((0..<900_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

        let port = try startListener(policy: ResponderPolicy(acceptsPairing: false)) { [weak self] link in
            self?.sourceLink = link
            link.onStateChange = { state in if state == .established { sourceReady.fulfill() } }
            link.onMessage = { message in
                guard case .control(.snapshotRequest(let request)) = message else { return }
                gotRequest.fulfill()
                let header = SnapshotHeader(
                    id: request.id, trigger: request.trigger, note: nil, pixelWidth: 10, pixelHeight: 10,
                    byteCount: image.count, chunkCount: PeerLink.chunkCount(byteCount: image.count, link: link.linkKind),
                    mimeType: "image/jpeg", capturedAt: Date(), captureTitle: "Test"
                )
                link.sendSnapshot(header: header, data: image)
                for sequence in 0..<30 {
                    link.send(.videoFrame(VideoFrame(sequence: UInt32(sequence), isKeyframe: sequence == 0, presentationMicros: UInt64(sequence), capturedAtNanos: wallClockNanos(), data: Data(repeating: 7, count: 20_000))), priority: .video)
                }
            }
        }

        let studioLink = makeStudioLink(port: port, mode: .session)
        self.studioLink = studioLink
        var assembler = SnapshotAssembler()
        var received: ReceivedSnapshot?
        var lastSequence: UInt32?
        studioLink.queue.async {
            studioLink.onStateChange = { state in
                if state == .established {
                    XCTAssertFalse(studioLink.newlyPaired)
                    studioReady.fulfill()
                    studioLink.send(.control(.snapshotRequest(SnapshotRequest(trigger: .manual, maxDimension: 0, quality: 0.9))))
                }
            }
            studioLink.onMessage = { message in
                switch message {
                case .control(.snapshotHeader(let header)):
                    _ = assembler.begin(header)
                case .snapshotChunk(let chunk):
                    if case .completed(let snapshot) = assembler.receive(chunk) {
                        received = snapshot
                        gotSnapshot.fulfill()
                    }
                case .videoFrame(let frame):
                    if let lastSequence { XCTAssertEqual(frame.sequence, lastSequence + 1, "frames arrive in order") }
                    lastSequence = frame.sequence
                    gotFrames.fulfill()
                default:
                    break
                }
            }
            studioLink.start()
        }

        wait(for: [sourceReady, studioReady, gotRequest, gotSnapshot, gotFrames], timeout: 15)
        XCTAssertEqual(received?.data, image)
    }

    func testDismissTellsPeerNotToReconnect() throws {
        try pairOverLoopback()
        let studioClosed = expectation(description: "studio saw dismissal")
        var reason: PeerLinkCloseReason?
        let studio = try XCTUnwrap(studioLink)
        let source = try XCTUnwrap(sourceLink)
        studio.queue.sync {
            studio.onStateChange = { state in
                if case .closed(let why) = state {
                    reason = why
                    studioClosed.fulfill()
                }
            }
        }
        source.queue.async { source.close(reason: "Ended by the Source user", dismiss: true) }
        wait(for: [studioClosed], timeout: 5)
        XCTAssertEqual(reason, .dismissedByPeer("Ended by the Source user"))
        XCTAssertEqual(reason?.isRecoverable, false)
    }

    func testDeclinedPairingClosesBothSides() throws {
        let studioClosed = expectation(description: "studio closed")
        let port = try startListener(policy: ResponderPolicy(acceptsPairing: true)) { [weak self] link in
            self?.sourceLink = link
            link.onPairingCode = { _, _ in link.decidePairing(accept: false) }
        }
        let studioLink = makeStudioLink(port: port, mode: .pair)
        self.studioLink = studioLink
        var closeReason: PeerLinkCloseReason?
        studioLink.queue.async {
            studioLink.onStateChange = { state in
                if case .closed(let reason) = state {
                    closeReason = reason
                    studioClosed.fulfill()
                }
            }
            studioLink.start()
        }
        wait(for: [studioClosed], timeout: 10)
        guard case .handshake(.pairingDeclined) = closeReason else {
            return XCTFail("unexpected close reason \(String(describing: closeReason))")
        }
    }

    func testSessionWithoutPairingFailsWithNotPaired() throws {
        let studioClosed = expectation(description: "studio closed")
        let port = try startListener(policy: ResponderPolicy(acceptsPairing: true)) { [weak self] link in
            self?.sourceLink = link
        }
        let studioLink = makeStudioLink(port: port, mode: .session)
        self.studioLink = studioLink
        var closeReason: PeerLinkCloseReason?
        studioLink.queue.async {
            studioLink.onStateChange = { state in
                if case .closed(let reason) = state {
                    closeReason = reason
                    studioClosed.fulfill()
                }
            }
            studioLink.start()
        }
        wait(for: [studioClosed], timeout: 10)
        XCTAssertEqual(closeReason, .handshake(.notPaired))
    }
}
