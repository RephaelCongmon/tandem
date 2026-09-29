import CoreBluetooth
import XCTest
@testable import TandemCore

final class BluetoothTransportTests: XCTestCase {

    // MARK: - Harness

    /// Everything observed on one transport. Only touched on that transport's queue.
    private final class Recorder {
        var received = Data()
        var states: [TransportState] = []
        var completionOrder: [Int] = []
        var completionErrors: [Int: Error] = [:]
        var callbacksOffQueue = 0
    }

    private struct Endpoint {
        let transport: StreamPairTransport
        let queue: DispatchQueue
        let recorder: Recorder
        let key: DispatchSpecificKey<String>
        let name: String

        func onQueue() -> Bool {
            DispatchQueue.getSpecific(key: key) == name
        }

        /// Runs `body` on the transport's queue and waits for it.
        func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }
    }

    /// Two transports cross-wired over bound stream pairs with a small buffer, so every
    /// large send exercises partial writes.
    private func makePair(bufferSize: Int = 4096, start: Bool = true) throws -> (Endpoint, Endpoint) {
        var aInput: InputStream?
        var bOutput: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &aInput, outputStream: &bOutput)
        var bInput: InputStream?
        var aOutput: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &bInput, outputStream: &aOutput)

        let a = makeEndpoint(
            name: "A", input: try XCTUnwrap(aInput), output: try XCTUnwrap(aOutput))
        let b = makeEndpoint(
            name: "B", input: try XCTUnwrap(bInput), output: try XCTUnwrap(bOutput))
        if start {
            a.sync { a.transport.start() }
            b.sync { b.transport.start() }
        }
        return (a, b)
    }

    private func makeEndpoint(name: String, input: InputStream, output: OutputStream) -> Endpoint {
        let queue = DispatchQueue(label: "BluetoothTransportTests.\(name)")
        let key = DispatchSpecificKey<String>()
        queue.setSpecific(key: key, value: name)
        let transport = StreamPairTransport(
            inputStream: input, outputStream: output, queue: queue,
            linkKind: .loopback, remoteDescription: "peer of \(name)")
        let endpoint = Endpoint(transport: transport, queue: queue, recorder: Recorder(), key: key, name: name)
        let recorder = endpoint.recorder
        queue.sync {
            transport.onReceive = { data in
                if !endpoint.onQueue() { recorder.callbacksOffQueue += 1 }
                recorder.received.append(data)
            }
            transport.onStateChange = { state in
                if !endpoint.onQueue() { recorder.callbacksOffQueue += 1 }
                recorder.states.append(state)
            }
        }
        return endpoint
    }

    /// Deterministic pseudo-random payloads whose first bytes encode their index, so any
    /// reordering or loss shows up in the concatenated stream.
    private func makePayloads(count: Int, maxSize: Int, seed: UInt64) -> [Data] {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        return (0..<count).map { index in
            let size = Int(next() % UInt64(maxSize)) + 1
            var bytes = [UInt8](repeating: 0, count: size)
            for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: next()) }
            withUnsafeBytes(of: UInt32(index).littleEndian) { indexBytes in
                for (offset, byte) in indexBytes.enumerated() where offset < size { bytes[offset] = byte }
            }
            return Data(bytes)
        }
    }

    /// Sends every payload in order from `endpoint`'s queue, recording completion order.
    private func sendAll(_ payloads: [Data], from endpoint: Endpoint, allDone: XCTestExpectation? = nil) {
        let recorder = endpoint.recorder
        endpoint.queue.async {
            for (index, payload) in payloads.enumerated() {
                endpoint.transport.send(payload) { error in
                    if !endpoint.onQueue() { recorder.callbacksOffQueue += 1 }
                    recorder.completionOrder.append(index)
                    if let error { recorder.completionErrors[index] = error }
                    if recorder.completionOrder.count == payloads.count { allDone?.fulfill() }
                }
            }
        }
    }

    /// Lets in-flight callbacks drain so "exactly once" assertions can catch duplicates.
    private func settle(_ endpoints: Endpoint..., for interval: TimeInterval = 0.3) {
        let pause = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) { pause.fulfill() }
        wait(for: [pause], timeout: interval + 5)
        for endpoint in endpoints { endpoint.sync {} }
    }

    private func waitUntil(
        _ description: String, timeout: TimeInterval = 10, on endpoint: Endpoint,
        _ condition: @escaping (Recorder) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if endpoint.sync({ condition(endpoint.recorder) }) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Timed out waiting for \(description) on \(endpoint.name)")
    }

    private func terminalStates(_ states: [TransportState]) -> [TransportState] {
        states.filter { state in
            switch state {
            case .closed, .failed: return true
            case .connecting, .ready: return false
            }
        }
    }

    // MARK: - Delivery

    func testReadyIsReportedOnceOnBothSides() throws {
        let (a, b) = try makePair()
        waitUntil("ready", on: a) { $0.states.contains(.ready) }
        waitUntil("ready", on: b) { $0.states.contains(.ready) }
        settle(a, b)
        XCTAssertEqual(a.sync { a.recorder.states }, [.ready])
        XCTAssertEqual(b.sync { b.recorder.states }, [.ready])
        XCTAssertEqual(a.sync { a.transport.state }, .ready)
        a.sync { a.transport.close() }
        b.sync { b.transport.close() }
    }

    func testOrderedBidirectionalDeliveryOfSeveralMegabytes() throws {
        let (a, b) = try makePair(bufferSize: 4096)
        let fromA = makePayloads(count: 700, maxSize: 12 * 1024, seed: 1)
        let fromB = makePayloads(count: 500, maxSize: 16 * 1024, seed: 2)
        let expectedAtB = fromA.reduce(into: Data()) { $0.append($1) }
        let expectedAtA = fromB.reduce(into: Data()) { $0.append($1) }
        XCTAssertGreaterThan(expectedAtB.count, 3_000_000, "should move several MB")
        XCTAssertGreaterThan(expectedAtA.count, 3_000_000, "should move several MB")

        let aSent = expectation(description: "A completions")
        let bSent = expectation(description: "B completions")
        sendAll(fromA, from: a, allDone: aSent)
        sendAll(fromB, from: b, allDone: bSent)
        wait(for: [aSent, bSent], timeout: 60)

        waitUntil("all bytes", timeout: 60, on: b) { $0.received.count >= expectedAtB.count }
        waitUntil("all bytes", timeout: 60, on: a) { $0.received.count >= expectedAtA.count }
        settle(a, b)

        XCTAssertEqual(b.sync { b.recorder.received.count }, expectedAtB.count)
        XCTAssertTrue(b.sync { b.recorder.received == expectedAtB }, "A→B bytes differ")
        XCTAssertTrue(a.sync { a.recorder.received == expectedAtA }, "B→A bytes differ")
        XCTAssertEqual(a.sync { a.recorder.completionOrder }, Array(0..<fromA.count))
        XCTAssertEqual(b.sync { b.recorder.completionOrder }, Array(0..<fromB.count))
        XCTAssertTrue(a.sync { a.recorder.completionErrors.isEmpty })
        XCTAssertTrue(b.sync { b.recorder.completionErrors.isEmpty })
        XCTAssertEqual(a.sync { a.recorder.callbacksOffQueue }, 0)
        XCTAssertEqual(b.sync { b.recorder.callbacksOffQueue }, 0)

        a.sync { a.transport.close() }
        b.sync { b.transport.close() }
    }

    func testSingleSendLargerThanStreamBufferIsDeliveredIntact() throws {
        let (a, b) = try makePair(bufferSize: 1024)
        let payload = makePayloads(count: 1, maxSize: 1, seed: 3)[0]
            + Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sent = expectation(description: "sent")
        sendAll([payload], from: a, allDone: sent)
        wait(for: [sent], timeout: 30)
        waitUntil("payload", timeout: 30, on: b) { $0.received.count >= payload.count }
        XCTAssertTrue(b.sync { b.recorder.received == payload })
        a.sync { a.transport.close() }
        b.sync { b.transport.close() }
    }

    func testCompletionsFireInOrderExactlyOnceIncludingEmptySends() throws {
        let (a, b) = try makePair()
        var payloads: [Data] = []
        for index in 0..<200 {
            payloads.append(index % 5 == 0 ? Data() : Data(repeating: UInt8(index % 251), count: 3000 + index))
        }
        let done = expectation(description: "completions")
        sendAll(payloads, from: a, allDone: done)
        wait(for: [done], timeout: 30)
        settle(a, b)
        XCTAssertEqual(a.sync { a.recorder.completionOrder }, Array(0..<payloads.count))
        XCTAssertTrue(a.sync { a.recorder.completionErrors.isEmpty })
        let expected = payloads.reduce(into: Data()) { $0.append($1) }
        waitUntil("bytes", on: b) { $0.received.count >= expected.count }
        XCTAssertTrue(b.sync { b.recorder.received == expected })
        a.sync { a.transport.close() }
        b.sync { b.transport.close() }
    }

    func testSendsQueuedBeforeStartAreDeliveredAfterStart() throws {
        let (a, b) = try makePair(start: false)
        let payloads = makePayloads(count: 20, maxSize: 8000, seed: 4)
        let done = expectation(description: "completions")
        sendAll(payloads, from: a, allDone: done)
        settle(a, b, for: 0.1)
        XCTAssertTrue(a.sync { a.recorder.completionOrder.isEmpty }, "nothing is written before start()")
        a.sync { a.transport.start() }
        b.sync { b.transport.start() }
        wait(for: [done], timeout: 30)
        let expected = payloads.reduce(into: Data()) { $0.append($1) }
        waitUntil("bytes", on: b) { $0.received.count >= expected.count }
        XCTAssertTrue(b.sync { b.recorder.received == expected })
        a.sync { a.transport.close() }
        b.sync { b.transport.close() }
    }

    // MARK: - Closing

    private func assertCloseFromOneSide(closer: Endpoint, peer: Endpoint) {
        waitUntil("ready", on: closer) { $0.states.contains(.ready) }
        waitUntil("ready", on: peer) { $0.states.contains(.ready) }
        closer.sync { closer.transport.close() }
        closer.sync { closer.transport.close() }  // Idempotent.
        waitUntil("peer terminal state", on: peer) { !self.terminalStates($0.states).isEmpty }
        settle(closer, peer)

        XCTAssertEqual(closer.sync { closer.recorder.states }, [.ready, .closed])
        XCTAssertEqual(closer.sync { closer.transport.state }, .closed)
        let peerTerminal = peer.sync { terminalStates(peer.recorder.states) }
        XCTAssertEqual(peerTerminal.count, 1, "peer must see exactly one terminal state")
        XCTAssertEqual(peerTerminal.first, .closed)
        XCTAssertEqual(peer.sync { peer.recorder.callbacksOffQueue }, 0)

        peer.sync { peer.transport.close() }
        settle(closer, peer)
        XCTAssertEqual(peer.sync { terminalStates(peer.recorder.states) }.count, 1, "no second terminal state")
    }

    func testCloseFromASideClosesPeerExactlyOnce() throws {
        let (a, b) = try makePair()
        assertCloseFromOneSide(closer: a, peer: b)
    }

    func testCloseFromBSideClosesPeerExactlyOnce() throws {
        let (a, b) = try makePair()
        assertCloseFromOneSide(closer: b, peer: a)
    }

    func testDataWrittenBeforeCloseIsDeliveredBeforePeerCloses() throws {
        let (a, b) = try makePair()
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let order = OrderLog()
        b.sync {
            let recorder = b.recorder
            b.transport.onReceive = { data in
                recorder.received.append(data)
                if recorder.received.count == payload.count { order.append("all data") }
            }
            b.transport.onStateChange = { state in
                recorder.states.append(state)
                if state == .closed { order.append("closed") }
            }
        }
        a.queue.async {
            a.transport.send(payload) { _ in a.transport.close() }
        }
        waitUntil("peer closed", on: b) { $0.states.contains(.closed) }
        XCTAssertTrue(b.sync { b.recorder.received == payload })
        XCTAssertEqual(order.entries, ["all data", "closed"])
    }

    func testCloseInsideCallbacksDoesNotDeadlock() throws {
        // Close from inside onReceive on B, from inside a send completion on A.
        let (a, b) = try makePair()
        let bClosed = expectation(description: "B closed")
        b.sync {
            let transport = b.transport
            let recorder = b.recorder
            transport.onReceive = { data in
                recorder.received.append(data)
                transport.close()
                transport.close()
            }
            transport.onStateChange = { state in
                recorder.states.append(state)
                if state == .closed {
                    transport.close()  // Re-entrant close after the terminal state is a no-op.
                    bClosed.fulfill()
                }
            }
        }
        let payloads = makePayloads(count: 100, maxSize: 10_000, seed: 5)
        let aDone = expectation(description: "A completions")
        let recorder = a.recorder
        a.queue.async {
            for (index, payload) in payloads.enumerated() {
                a.transport.send(payload) { error in
                    recorder.completionOrder.append(index)
                    if let error { recorder.completionErrors[index] = error }
                    if index == 0 { a.transport.close() }
                    if recorder.completionOrder.count == payloads.count { aDone.fulfill() }
                }
            }
        }
        wait(for: [bClosed, aDone], timeout: 10)
        settle(a, b)
        XCTAssertEqual(a.sync { a.recorder.completionOrder }, Array(0..<payloads.count), "each completion exactly once, in order")
        XCTAssertEqual(a.sync { terminalStates(a.recorder.states) }, [.closed])
        XCTAssertEqual(b.sync { terminalStates(b.recorder.states) }, [.closed])
        // B stopped receiving the moment it closed.
        XCTAssertLessThanOrEqual(b.sync { b.recorder.received.count }, 64 * 1024)
    }

    func testCloseInsideReadyCallbackDoesNotDeadlock() throws {
        let (a, b) = try makePair(start: false)
        let closed = expectation(description: "closed")
        a.sync {
            let transport = a.transport
            let recorder = a.recorder
            transport.onStateChange = { state in
                recorder.states.append(state)
                if state == .ready { transport.close() }
                if state == .closed { closed.fulfill() }
            }
            transport.start()
        }
        b.sync { b.transport.start() }
        wait(for: [closed], timeout: 10)
        waitUntil("peer closed", on: b) { !self.terminalStates($0.states).isEmpty }
        XCTAssertEqual(a.sync { a.recorder.states }, [.ready, .closed])
    }

    func testSendAfterCloseFailsExactlyOnceOnQueue() throws {
        let (a, b) = try makePair()
        a.sync { a.transport.close() }
        let failed = expectation(description: "send failed")
        let calls = Counter()
        a.queue.async {
            a.transport.send(Data([1, 2, 3])) { error in
                XCTAssertTrue(a.onQueue())
                XCTAssertNotNil(error)
                XCTAssertTrue(error is TransportError)
                calls.increment()
                failed.fulfill()
            }
        }
        wait(for: [failed], timeout: 5)
        settle(a, b)
        XCTAssertEqual(calls.value, 1)
        b.sync { b.transport.close() }
    }

    func testPendingSendsFailWhenPeerCloses() throws {
        let (a, b) = try makePair(bufferSize: 1024)
        // B never reads: stop B's reads by closing B, then A's backlog can't drain.
        let payloads = (0..<50).map { _ in Data(repeating: 0xAB, count: 32 * 1024) }
        let done = expectation(description: "all completions")
        waitUntil("ready", on: b) { $0.states.contains(.ready) }
        sendAll(payloads, from: a, allDone: done)
        b.sync { b.transport.close() }
        wait(for: [done], timeout: 10)
        settle(a, b)
        XCTAssertEqual(a.sync { a.recorder.completionOrder }, Array(0..<payloads.count))
        XCTAssertFalse(a.sync { a.recorder.completionErrors.isEmpty }, "unsent data must complete with an error")
        XCTAssertEqual(a.sync { terminalStates(a.recorder.states) }, [.closed])
    }

    func testReleasingTransportWithoutCloseClosesPeer() throws {
        var (a, b): (Endpoint?, Endpoint) = try makePair()
        waitUntil("ready", on: b) { $0.states.contains(.ready) }
        if let endpoint = a {
            endpoint.sync {
                endpoint.transport.onStateChange = nil
                endpoint.transport.onReceive = nil
            }
        }
        a = nil
        waitUntil("peer closed", on: b) { !self.terminalStates($0.states).isEmpty }
        XCTAssertEqual(b.sync { terminalStates(b.recorder.states) }, [.closed])
        b.sync { b.transport.close() }
    }

    func testTerminationObserverFiresOnceAfterTerminalState() throws {
        let (a, b) = try makePair()
        let counter = Counter()
        let fired = expectation(description: "observer")
        a.sync {
            a.transport.terminationObserver = {
                XCTAssertTrue(a.onQueue())
                XCTAssertEqual(a.transport.state, .closed)
                counter.increment()
                fired.fulfill()
            }
        }
        b.sync { b.transport.close() }
        wait(for: [fired], timeout: 10)
        a.sync { a.transport.close() }
        settle(a, b)
        XCTAssertEqual(counter.value, 1)
    }

    func testTransportProperties() throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1024, inputStream: &input, outputStream: &output)
        let queue = DispatchQueue(label: "props")
        let transport = StreamPairTransport(
            inputStream: try XCTUnwrap(input), outputStream: try XCTUnwrap(output), queue: queue)
        XCTAssertEqual(transport.linkKind, .bluetooth)
        XCTAssertEqual(transport.preferredWindowBytes, 48 * 1024)
        XCTAssertTrue(transport.queue === queue)
        XCTAssertEqual(transport.state, .connecting)
    }

    // MARK: - Peer info & PSM

    func testPeerInfoRoundTrip() throws {
        let info = BluetoothPeerInfo(
            id: "8C1E5B6A-0D3F-4E0B-9C8D-3A2B1C0D9E8F", name: "Rofel's MacBook Pro", model: "MacBookPro18,1")
        let data = info.encodedJSON()
        XCTAssertLessThan(data.count, 180)
        XCTAssertEqual(try BluetoothPeerInfo.decode(from: data), info)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, info.id)
        XCTAssertEqual(object["name"] as? String, info.name)
        XCTAssertEqual(object["model"] as? String, "MacBookPro18,1")
        XCTAssertEqual(object["v"] as? Int, 1)
    }

    func testPeerInfoTruncatesLongNameToFit() throws {
        let id = UUID().uuidString
        let longName = String(repeating: "Studio Mac with a very long name ", count: 10)
        let info = BluetoothPeerInfo(id: id, name: longName, model: "Mac14,6")
        let data = info.encodedJSON()
        XCTAssertLessThan(data.count, 180)
        let decoded = try BluetoothPeerInfo.decode(from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.model, "Mac14,6")
        XCTAssertFalse(decoded.name.isEmpty)
        XCTAssertTrue(longName.hasPrefix(decoded.name))
        XCTAssertEqual(decoded.name, decoded.name.trimmingCharacters(in: .whitespaces))
        // As long as possible: one more character wouldn't fit.
        var longer = decoded
        longer.name = String(longName.prefix(decoded.name.count + 1))
        XCTAssertGreaterThan(Self.plainEncodedSize(longer), BluetoothConstants.maxInfoBytes)
    }

    func testPeerInfoTruncationRespectsMultibyteCharacters() throws {
        let name = String(repeating: "🎛️Mäc ", count: 40)
        let info = BluetoothPeerInfo(id: UUID().uuidString, name: name, model: "MacBookAir10,1")
        for cap in [179, 120, 100] {
            let data = info.encodedJSON(maxBytes: cap)
            XCTAssertLessThanOrEqual(data.count, cap)
            let decoded = try BluetoothPeerInfo.decode(from: data)
            XCTAssertTrue(name.hasPrefix(decoded.name), "cut on a character boundary at cap \(cap)")
            XCTAssertNotNil(String(data: data, encoding: .utf8))
        }
    }

    func testPeerInfoTruncatesModelWhenNameAloneIsNotEnough() throws {
        let info = BluetoothPeerInfo(
            id: UUID().uuidString, name: "Name", model: String(repeating: "M", count: 300))
        let data = info.encodedJSON()
        XCTAssertLessThanOrEqual(data.count, BluetoothConstants.maxInfoBytes)
        let decoded = try BluetoothPeerInfo.decode(from: data)
        XCTAssertEqual(decoded.id, info.id)
        XCTAssertEqual(decoded.name, "")
        XCTAssertFalse(decoded.model.isEmpty)
    }

    func testPeerInfoDecodingIsTolerant() throws {
        let minimal = Data(#"{"id":"abc"}"#.utf8)
        XCTAssertEqual(
            try BluetoothPeerInfo.decode(from: minimal),
            BluetoothPeerInfo(id: "abc", name: "", model: "", v: 1))
        let future = Data(#"{"id":"abc","name":"N","model":"M","v":2,"caps":["x"]}"#.utf8)
        XCTAssertEqual(try BluetoothPeerInfo.decode(from: future).v, 2)
        XCTAssertThrowsError(try BluetoothPeerInfo.decode(from: Data("not json".utf8)))
        XCTAssertThrowsError(try BluetoothPeerInfo.decode(from: Data(#"{"name":"no id"}"#.utf8)))
        XCTAssertThrowsError(try BluetoothPeerInfo.decode(from: Data(#"{"id":""}"#.utf8)))
    }

    func testAdvertisedNameIsShort() {
        let info = BluetoothPeerInfo(id: "x", name: "Rofel’s MacBook Pro (16-inch, 2021)", model: "m")
        XCTAssertLessThanOrEqual(info.advertisedName.utf8.count, BluetoothConstants.maxAdvertisedNameBytes)
        XCTAssertTrue(info.name.hasPrefix(info.advertisedName))
        XCTAssertEqual(BluetoothPeerInfo(id: "x", name: "", model: "m").advertisedName, "Tandem")
        XCTAssertEqual(BluetoothPeerInfo(id: "x", name: "Mini", model: "m").advertisedName, "Mini")
    }

    func testPSMEncoding() {
        XCTAssertEqual(BluetoothConstants.encodePSM(0x0081), Data([0x81, 0x00]))
        XCTAssertEqual(BluetoothConstants.encodePSM(0x1234), Data([0x34, 0x12]))
        for psm: CBL2CAPPSM in [0x0001, 0x0080, 0x00C5, 0x00FF, 0xFFFF] {
            XCTAssertEqual(BluetoothConstants.decodePSM(BluetoothConstants.encodePSM(psm)), psm)
        }
        XCTAssertNil(BluetoothConstants.decodePSM(Data()))
        XCTAssertNil(BluetoothConstants.decodePSM(Data([0x81])))
        XCTAssertNil(BluetoothConstants.decodePSM(Data([0x81, 0x00, 0x00])))
        XCTAssertNil(BluetoothConstants.decodePSM(Data([0x00, 0x00])))
        // Works on slices with a non-zero start index.
        let slice = Data([0xFF, 0x85, 0x00]).dropFirst()
        XCTAssertEqual(BluetoothConstants.decodePSM(slice), 0x0085)
    }

    func testUUIDsAndAvailabilityMapping() {
        XCTAssertEqual(BluetoothConstants.serviceUUID.uuidString, "7A4D0001-3C1B-4F5E-9A8D-54414E44454D")
        XCTAssertEqual(BluetoothConstants.psmCharacteristicUUID.uuidString, "7A4D0002-3C1B-4F5E-9A8D-54414E44454D")
        XCTAssertEqual(BluetoothConstants.infoCharacteristicUUID.uuidString, "7A4D0003-3C1B-4F5E-9A8D-54414E44454D")
        XCTAssertEqual(BluetoothAvailability(.poweredOn), .ready)
        XCTAssertEqual(BluetoothAvailability(.poweredOff), .poweredOff)
        XCTAssertEqual(BluetoothAvailability(.unauthorized), .unauthorized)
        XCTAssertEqual(BluetoothAvailability(.unsupported), .unsupported)
        XCTAssertEqual(BluetoothAvailability(.resetting), .unknown)
        XCTAssertEqual(BluetoothAvailability(.unknown), .unknown)
    }

    private static func plainEncodedSize(_ info: BluetoothPeerInfo) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(info).count) ?? 0
    }
}

/// Thread-safe helpers for assertions from arbitrary queues.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var entries: [String] { lock.withLock { items } }
    func append(_ entry: String) { lock.withLock { items.append(entry) } }
}
