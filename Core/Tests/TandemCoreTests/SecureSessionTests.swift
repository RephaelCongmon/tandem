import CryptoKit
import XCTest
@testable import TandemCore

final class SecureSessionTests: XCTestCase {
    private let alice = DeviceIdentity(id: UUID().uuidString, name: "Alice's MacBook", model: "MacBookPro18,1;laptop")
    private let bob = DeviceIdentity(id: UUID().uuidString, name: "Bob's MacBook", model: "Mac14,2;laptop")

    /// Pumps frames between two machines until neither has anything left to send.
    private struct Harness {
        let initiator: SecureSession
        let responder: SecureSession
        var initiatorOutputs: [SecureSession.Output] = []
        var responderOutputs: [SecureSession.Output] = []

        mutating func run(startingWith outputs: [SecureSession.Output]) {
            initiatorOutputs += outputs
            pump(toResponder: sends(outputs), toInitiator: [])
        }

        mutating func deliverResponder(_ outputs: [SecureSession.Output]) {
            responderOutputs += outputs
            pump(toResponder: [], toInitiator: sends(outputs))
        }

        private mutating func pump(toResponder: [Data], toInitiator: [Data]) {
            var pendingResponder = toResponder
            var pendingInitiator = toInitiator
            var rounds = 0
            while (!pendingResponder.isEmpty || !pendingInitiator.isEmpty) && rounds < 50 {
                rounds += 1
                if !pendingResponder.isEmpty {
                    let outputs = pendingResponder.flatMap { responder.receive($0) }
                    pendingResponder = []
                    responderOutputs += outputs
                    pendingInitiator += sends(outputs)
                }
                if !pendingInitiator.isEmpty {
                    let outputs = pendingInitiator.flatMap { initiator.receive($0) }
                    pendingInitiator = []
                    initiatorOutputs += outputs
                    pendingResponder += sends(outputs)
                }
            }
        }

        func sends(_ outputs: [SecureSession.Output]) -> [Data] {
            outputs.compactMap { if case .send(let data) = $0 { return data } else { return nil } }
        }
    }

    private func code(in outputs: [SecureSession.Output]) -> String? {
        for output in outputs { if case .pairingCode(let code, _) = output { return code } }
        return nil
    }

    private func established(in outputs: [SecureSession.Output]) -> (DeviceIdentity, Bool)? {
        for output in outputs { if case .established(let peer, let fresh) = output { return (peer, fresh) } }
        return nil
    }

    private func failure(in outputs: [SecureSession.Output]) -> HandshakeFailure? {
        for output in outputs { if case .failed(let failure) = output { return failure } }
        return nil
    }

    private func pair(aliceKeys: InMemoryPairingKeyStore, bobKeys: InMemoryPairingKeyStore) throws {
        let studio = SecureSession(role: .initiator(mode: .pair, expectedPeerID: alice.id), identity: bob, keyStore: bobKeys)
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: true)), identity: alice, keyStore: aliceKeys)
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())
        let studioCode = try XCTUnwrap(code(in: harness.initiatorOutputs))
        let sourceCode = try XCTUnwrap(code(in: harness.responderOutputs))
        XCTAssertEqual(studioCode, sourceCode)
        XCTAssertEqual(studioCode.count, 7)
        harness.deliverResponder(source.decidePairing(accept: true))
        XCTAssertEqual(established(in: harness.initiatorOutputs)?.0.id, alice.id)
        XCTAssertEqual(established(in: harness.initiatorOutputs)?.1, true)
        XCTAssertEqual(established(in: harness.responderOutputs)?.0.id, bob.id)
        XCTAssertTrue(studio.isEstablished)
        XCTAssertTrue(source.isEstablished)
    }

    func testPairingProducesMatchingCodesAndSharedKey() throws {
        let aliceKeys = InMemoryPairingKeyStore()
        let bobKeys = InMemoryPairingKeyStore()
        try pair(aliceKeys: aliceKeys, bobKeys: bobKeys)
        let a = try XCTUnwrap(aliceKeys.key(for: bob.id))
        let b = try XCTUnwrap(bobKeys.key(for: alice.id))
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testSessionAfterPairingExchangesEncryptedMessagesBothWays() throws {
        let aliceKeys = InMemoryPairingKeyStore()
        let bobKeys = InMemoryPairingKeyStore()
        try pair(aliceKeys: aliceKeys, bobKeys: bobKeys)

        let studio = SecureSession(role: .initiator(mode: .session, expectedPeerID: alice.id), identity: bob, keyStore: bobKeys)
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: false)), identity: alice, keyStore: aliceKeys)
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())
        XCTAssertEqual(established(in: harness.initiatorOutputs)?.1, false)
        XCTAssertNotNil(established(in: harness.responderOutputs))

        let payload = Data("hello from the studio".utf8)
        let record = try studio.seal(payload)
        XCTAssertFalse(record.range(of: payload) != nil, "plaintext must not appear on the wire")
        XCTAssertEqual(source.receive(record), [.message(payload)])

        let back = try source.seal(Data([1, 2, 3]))
        XCTAssertEqual(studio.receive(back), [.message(Data([1, 2, 3]))])
    }

    func testSessionWithoutPairingIsRejected() {
        let studio = SecureSession(role: .initiator(mode: .session, expectedPeerID: nil), identity: bob, keyStore: InMemoryPairingKeyStore())
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: true)), identity: alice, keyStore: InMemoryPairingKeyStore())
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())
        XCTAssertEqual(failure(in: harness.responderOutputs), .notPaired)
        XCTAssertEqual(failure(in: harness.initiatorOutputs), .notPaired)
    }

    func testMismatchedPairingKeysFailAuthentication() {
        let aliceKeys = InMemoryPairingKeyStore()
        let bobKeys = InMemoryPairingKeyStore()
        try? aliceKeys.setKey(SymmetricKey(size: .bits256), for: bob.id)
        try? bobKeys.setKey(SymmetricKey(size: .bits256), for: alice.id)
        let studio = SecureSession(role: .initiator(mode: .session, expectedPeerID: nil), identity: bob, keyStore: bobKeys)
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: true)), identity: alice, keyStore: aliceKeys)
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())
        XCTAssertEqual(failure(in: harness.responderOutputs), .authenticationFailed)
        XCTAssertFalse(source.isEstablished)
    }

    func testDeclinedPairingReachesInitiator() throws {
        let studio = SecureSession(role: .initiator(mode: .pair, expectedPeerID: nil), identity: bob, keyStore: InMemoryPairingKeyStore())
        let sourceKeys = InMemoryPairingKeyStore()
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: true)), identity: alice, keyStore: sourceKeys)
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())
        XCTAssertNotNil(code(in: harness.responderOutputs))
        harness.deliverResponder(source.decidePairing(accept: false))
        guard case .pairingDeclined = failure(in: harness.initiatorOutputs) else {
            return XCTFail("expected decline, got \(String(describing: failure(in: harness.initiatorOutputs)))")
        }
        XCTAssertNil(sourceKeys.key(for: bob.id))
    }

    func testPairingDisabledOnResponder() {
        let studio = SecureSession(role: .initiator(mode: .pair, expectedPeerID: nil), identity: bob, keyStore: InMemoryPairingKeyStore())
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: false)), identity: alice, keyStore: InMemoryPairingKeyStore())
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())
        XCTAssertEqual(failure(in: harness.initiatorOutputs), .pairingUnavailable)
    }

    func testUnexpectedPeerIsDetected() {
        let studio = SecureSession(role: .initiator(mode: .pair, expectedPeerID: UUID().uuidString), identity: bob, keyStore: InMemoryPairingKeyStore())
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: true)), identity: alice, keyStore: InMemoryPairingKeyStore())
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())
        XCTAssertEqual(failure(in: harness.initiatorOutputs), .unexpectedPeer)
    }

    /// A man-in-the-middle relaying between both Macs ends up with two independent
    /// pairings whose codes differ, so the users can spot it.
    func testManInTheMiddleSeesDifferentCodes() throws {
        let mallory = DeviceIdentity(id: UUID().uuidString, name: "Alice's MacBook", model: "MacBookPro18,1")
        // Studio ⇄ Mallory (posing as Source)
        let studio = SecureSession(role: .initiator(mode: .pair, expectedPeerID: nil), identity: bob, keyStore: InMemoryPairingKeyStore())
        let fakeSource = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: true)), identity: mallory, keyStore: InMemoryPairingKeyStore())
        _ = fakeSource.start()
        var left = Harness(initiator: studio, responder: fakeSource)
        left.run(startingWith: studio.start())
        // Mallory (posing as Studio) ⇄ Source
        let fakeStudio = SecureSession(role: .initiator(mode: .pair, expectedPeerID: nil), identity: mallory, keyStore: InMemoryPairingKeyStore())
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: true)), identity: alice, keyStore: InMemoryPairingKeyStore())
        _ = source.start()
        var right = Harness(initiator: fakeStudio, responder: source)
        right.run(startingWith: fakeStudio.start())

        let studioCode = try XCTUnwrap(code(in: left.initiatorOutputs))
        let sourceCode = try XCTUnwrap(code(in: right.responderOutputs))
        XCTAssertNotEqual(studioCode, sourceCode)
    }

    func testTamperedRecordIsRejected() throws {
        let aliceKeys = InMemoryPairingKeyStore()
        let bobKeys = InMemoryPairingKeyStore()
        try pair(aliceKeys: aliceKeys, bobKeys: bobKeys)
        let studio = SecureSession(role: .initiator(mode: .session, expectedPeerID: nil), identity: bob, keyStore: bobKeys)
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: false)), identity: alice, keyStore: aliceKeys)
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())

        var record = try studio.seal(Data("secret".utf8))
        record[record.startIndex] ^= 0x01
        XCTAssertEqual(source.receive(record), [.failed(.authenticationFailed)])
    }

    func testReplayedRecordIsRejected() throws {
        let aliceKeys = InMemoryPairingKeyStore()
        let bobKeys = InMemoryPairingKeyStore()
        try pair(aliceKeys: aliceKeys, bobKeys: bobKeys)
        let studio = SecureSession(role: .initiator(mode: .session, expectedPeerID: nil), identity: bob, keyStore: bobKeys)
        let source = SecureSession(role: .responder(policy: ResponderPolicy(acceptsPairing: false)), identity: alice, keyStore: aliceKeys)
        _ = source.start()
        var harness = Harness(initiator: studio, responder: source)
        harness.run(startingWith: studio.start())

        let record = try studio.seal(Data("once".utf8))
        XCTAssertEqual(source.receive(record), [.message(Data("once".utf8))])
        XCTAssertEqual(source.receive(record), [.failed(.authenticationFailed)])
    }

    func testCodeFormatting() {
        XCTAssertEqual(SecureSession.formatCode(42), "000 042")
        XCTAssertEqual(SecureSession.formatCode(999_999), "999 999")
    }
}
