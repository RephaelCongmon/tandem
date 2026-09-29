import CryptoKit
import Foundation

/// Why a handshake did not produce a session.
public enum HandshakeFailure: Error, Sendable, Hashable, LocalizedError {
    /// The peer speaks an incompatible protocol version.
    case versionMismatch(peerVersion: Int)
    /// The peer doesn't know us (or we don't know it) — pairing is required.
    case notPaired
    /// Keys didn't match: the pairing was removed on one side, or someone interfered.
    case authenticationFailed
    /// The other Mac declined or cancelled pairing.
    case pairingDeclined(String?)
    /// The other Mac isn't accepting pairing requests right now.
    case pairingUnavailable
    /// The other Mac is busy with another pairing request.
    case busy
    /// We reached a different device than the one we meant to connect to.
    case unexpectedPeer
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .versionMismatch:
            return "The other Mac is running an incompatible version of Tandem. Update both Macs."
        case .notPaired:
            return "These Macs aren't paired yet."
        case .authenticationFailed:
            return "The pairing between these Macs is no longer valid. Pair them again."
        case .pairingDeclined(let reason):
            return reason ?? "Pairing was declined on the other Mac."
        case .pairingUnavailable:
            return "The other Mac isn't accepting pairing requests. Open Tandem there and try again."
        case .busy:
            return "The other Mac is handling another pairing request. Try again in a moment."
        case .unexpectedPeer:
            return "Reached a different Mac than expected."
        case .protocolViolation(let detail):
            return "Connection error (\(detail))."
        }
    }
}

public enum HandshakeMode: String, Codable, Sendable {
    /// Authenticate with an existing pairing key.
    case session
    /// Establish a new pairing, confirmed by the users via a 6-digit code.
    case pair
}

/// Decides how a responder treats incoming handshakes.
public struct ResponderPolicy: Sendable {
    public var acceptsPairing: Bool
    public var isBusy: Bool

    public init(acceptsPairing: Bool, isBusy: Bool = false) {
        self.acceptsPairing = acceptsPairing
        self.isBusy = isBusy
    }
}

/// A transport-agnostic secure-session state machine.
///
/// **Session mode** (already paired): X25519 ephemeral key agreement mixed with the
/// long-term pairing key `K` via HKDF over the handshake transcript, then mutual
/// key confirmation (`Finished` MACs). Gives mutual authentication and forward secrecy.
///
/// **Pair mode**: commitment-based numeric comparison (as in Bluetooth LE Secure
/// Connections). The initiator commits to its ephemeral key before seeing the
/// responder's, so a man-in-the-middle cannot steer both sides to the same 6-digit
/// code except with probability 10⁻⁶. The responder's user approves after checking
/// that both Macs display the same code; both sides then derive and store `K`.
///
/// Wire format: plaintext handshake frames `[type][JSON]`, then encrypted records
/// whose plaintext is `[innerType][body]`.
public final class SecureSession {
    public enum Role: Sendable {
        case initiator(mode: HandshakeMode, expectedPeerID: String?)
        case responder(policy: ResponderPolicy)
    }

    public enum Output: Equatable {
        /// A frame payload to send (the caller adds length-prefix framing).
        case send(Data)
        /// Show this code; on the responder, ask the user to approve via `decidePairing`.
        case pairingCode(String, peer: DeviceIdentity)
        case established(peer: DeviceIdentity, newlyPaired: Bool)
        /// A decrypted application message (after establishment).
        case message(Data)
        case failed(HandshakeFailure)
    }

    private enum FrameType: UInt8 {
        case clientHello = 1
        case serverHello = 2
        case clientReveal = 3
    }

    private enum InnerType: UInt8 {
        case control = 0x10
        case application = 0x20
    }

    private enum Phase {
        case idle
        case awaitingServerHello
        case awaitingClientHello
        case awaitingReveal(commitment: Data, peer: DeviceIdentity)
        case awaitingFinished(peer: DeviceIdentity)
        case awaitingDecision(peer: DeviceIdentity)
        case awaitingLocalDecision(peer: DeviceIdentity)
        case awaitingAck(peer: DeviceIdentity)
        case established(peer: DeviceIdentity)
        case failed
    }

    private struct ClientHello: Codable {
        var v: Int
        var mode: HandshakeMode
        var id: String
        var name: String
        var model: String
        var eph: Data?
        var nonce: Data?
        var commit: Data?
    }

    private enum ServerStatus: String, Codable {
        case ok, notPaired, pairingUnavailable, busy, versionMismatch
    }

    private struct ServerHello: Codable {
        var v: Int
        var status: ServerStatus
        var id: String
        var name: String
        var model: String
        var eph: Data?
        var nonce: Data?
    }

    private struct ClientReveal: Codable {
        var eph: Data
        var nonce: Data
    }

    private enum SecureControl: Codable {
        case finished(mac: Data)
        case pairingDecision(accepted: Bool, reason: String?)
        case pairingAck
    }

    public static let handshakeVersion = 1

    public let role: Role
    private let identity: DeviceIdentity
    private let keyStore: PairingKeyStore
    private var phase: Phase = .idle
    private var mode: HandshakeMode = .session

    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = SecureSession.randomBytes(32)
    private var transcript = SHA256()
    private var transcriptHash = Data()
    private var sharedSecret: SharedSecret?
    private var confirmKey: SymmetricKey?
    private var sender: RecordProtector?
    private var receiver: RecordProtector?

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(role: Role, identity: DeviceIdentity, keyStore: PairingKeyStore) {
        self.role = role
        self.identity = identity
        self.keyStore = keyStore
    }

    public var isEstablished: Bool {
        if case .established = phase { return true }
        return false
    }

    public var peer: DeviceIdentity? {
        switch phase {
        case .awaitingReveal(_, let peer), .awaitingFinished(let peer), .awaitingDecision(let peer),
             .awaitingLocalDecision(let peer), .awaitingAck(let peer), .established(let peer):
            return peer
        default:
            return nil
        }
    }

    // MARK: Driving the machine

    public func start() -> [Output] {
        guard case .idle = phase else { return [] }
        switch role {
        case .initiator(let mode, _):
            self.mode = mode
            var hello = ClientHello(
                v: Self.handshakeVersion, mode: mode,
                id: identity.id, name: identity.name, model: identity.model
            )
            switch mode {
            case .session:
                hello.eph = ephemeral.publicKey.rawRepresentation
                hello.nonce = nonce
            case .pair:
                hello.commit = Self.commitment(publicKey: ephemeral.publicKey.rawRepresentation, nonce: nonce)
            }
            phase = .awaitingServerHello
            return [.send(handshakeFrame(.clientHello, hello))]
        case .responder:
            phase = .awaitingClientHello
            return []
        }
    }

    public func receive(_ frame: Data) -> [Output] {
        do {
            switch phase {
            case .idle, .failed:
                return []
            case .awaitingClientHello:
                return try handleClientHello(frame)
            case .awaitingServerHello:
                return try handleServerHello(frame)
            case .awaitingReveal(let commitment, let peer):
                return try handleReveal(frame, commitment: commitment, peer: peer)
            case .awaitingFinished(let peer):
                return try handleFinished(frame, peer: peer)
            case .awaitingDecision(let peer):
                return try handleDecision(frame, peer: peer)
            case .awaitingLocalDecision:
                // The initiator must not send anything until our user decides.
                return fail(.protocolViolation("early record"))
            case .awaitingAck(let peer):
                return try handleAck(frame, peer: peer)
            case .established:
                let (type, body) = try openRecord(frame)
                guard type == .application else { return fail(.protocolViolation("unexpected control")) }
                return [.message(body)]
            }
        } catch let failure as HandshakeFailure {
            return fail(failure)
        } catch RecordError.authenticationFailed {
            return fail(.authenticationFailed)
        } catch {
            return fail(.protocolViolation("\(error)"))
        }
    }

    /// Responder only: the local user approved or declined the pairing code.
    public func decidePairing(accept: Bool) -> [Output] {
        guard case .awaitingLocalDecision(let peer) = phase else { return [] }
        do {
            if accept {
                try storePairingKey(for: peer)
                let record = try sealControl(.pairingDecision(accepted: true, reason: nil))
                phase = .awaitingAck(peer: peer)
                return [.send(record)]
            } else {
                let record = try sealControl(.pairingDecision(accepted: false, reason: "Pairing was declined on \(identity.name)."))
                phase = .failed
                return [.send(record), .failed(.pairingDeclined("You declined the pairing request."))]
            }
        } catch {
            return fail(.protocolViolation("decision: \(error)"))
        }
    }

    /// Encrypts an application message. Only valid once established.
    public func seal(_ message: Data) throws -> Data {
        guard isEstablished else { throw HandshakeFailure.protocolViolation("not established") }
        var plaintext = Data(capacity: message.count + 1)
        plaintext.append(InnerType.application.rawValue)
        plaintext.append(message)
        guard let record = try sender?.seal(plaintext) else { throw HandshakeFailure.protocolViolation("no keys") }
        return record
    }

    // MARK: Handlers

    private func handleClientHello(_ frame: Data) throws -> [Output] {
        let hello: ClientHello = try decodeHandshake(frame, expecting: .clientHello)
        guard case .responder(let policy) = role else { throw HandshakeFailure.protocolViolation("role") }
        let peer = DeviceIdentity(id: hello.id, name: hello.name, model: hello.model)
        mode = hello.mode

        func reject(_ status: ServerStatus, _ failure: HandshakeFailure) -> [Output] {
            let reply = ServerHello(v: Self.handshakeVersion, status: status, id: identity.id, name: identity.name, model: identity.model)
            phase = .failed
            return [.send(handshakeFrame(.serverHello, reply)), .failed(failure)]
        }

        guard hello.v == Self.handshakeVersion else { return reject(.versionMismatch, .versionMismatch(peerVersion: hello.v)) }
        guard UUID(uuidString: hello.id) != nil, hello.id != identity.id else {
            throw HandshakeFailure.protocolViolation("peer id")
        }

        let reply = ServerHello(
            v: Self.handshakeVersion, status: .ok,
            id: identity.id, name: identity.name, model: identity.model,
            eph: ephemeral.publicKey.rawRepresentation, nonce: nonce
        )

        switch hello.mode {
        case .session:
            guard let pairingKey = keyStore.key(for: hello.id) else { return reject(.notPaired, .notPaired) }
            // The client nonce contributes through the transcript hash (HKDF salt).
            guard let eph = hello.eph, hello.nonce?.count == 32 else {
                throw HandshakeFailure.protocolViolation("hello fields")
            }
            let replyFrame = handshakeFrame(.serverHello, reply)
            try deriveKeys(peerEphemeral: eph, pairingKey: pairingKey, isInitiator: false)
            phase = .awaitingFinished(peer: peer)
            return [.send(replyFrame)]

        case .pair:
            guard policy.acceptsPairing else { return reject(.pairingUnavailable, .pairingUnavailable) }
            guard !policy.isBusy else { return reject(.busy, .busy) }
            guard let commitment = hello.commit, commitment.count == 32 else {
                throw HandshakeFailure.protocolViolation("commitment")
            }
            phase = .awaitingReveal(commitment: commitment, peer: peer)
            return [.send(handshakeFrame(.serverHello, reply))]
        }
    }

    private func handleServerHello(_ frame: Data) throws -> [Output] {
        let hello: ServerHello = try decodeHandshake(frame, expecting: .serverHello)
        guard case .initiator(_, let expectedPeerID) = role else { throw HandshakeFailure.protocolViolation("role") }
        switch hello.status {
        case .ok: break
        case .notPaired: throw HandshakeFailure.notPaired
        case .pairingUnavailable: throw HandshakeFailure.pairingUnavailable
        case .busy: throw HandshakeFailure.busy
        case .versionMismatch: throw HandshakeFailure.versionMismatch(peerVersion: hello.v)
        }
        guard hello.v == Self.handshakeVersion else { throw HandshakeFailure.versionMismatch(peerVersion: hello.v) }
        if let expectedPeerID, expectedPeerID != hello.id { throw HandshakeFailure.unexpectedPeer }
        guard UUID(uuidString: hello.id) != nil, hello.id != identity.id else {
            throw HandshakeFailure.protocolViolation("peer id")
        }
        guard let eph = hello.eph, let serverNonce = hello.nonce, serverNonce.count == 32 else {
            throw HandshakeFailure.protocolViolation("hello fields")
        }
        let peer = DeviceIdentity(id: hello.id, name: hello.name, model: hello.model)

        switch mode {
        case .session:
            guard let pairingKey = keyStore.key(for: hello.id) else { throw HandshakeFailure.notPaired }
            try deriveKeys(peerEphemeral: eph, pairingKey: pairingKey, isInitiator: true)
            let finished = try sealControl(.finished(mac: finishedMAC(label: "client")))
            phase = .awaitingFinished(peer: peer)
            return [.send(finished)]

        case .pair:
            let reveal = ClientReveal(eph: ephemeral.publicKey.rawRepresentation, nonce: nonce)
            let revealFrame = handshakeFrame(.clientReveal, reveal)
            try deriveKeys(peerEphemeral: eph, pairingKey: nil, isInitiator: true)
            phase = .awaitingDecision(peer: peer)
            return [.send(revealFrame), .pairingCode(try pairingCode(), peer: peer)]
        }
    }

    private func handleReveal(_ frame: Data, commitment: Data, peer: DeviceIdentity) throws -> [Output] {
        let reveal: ClientReveal = try decodeHandshake(frame, expecting: .clientReveal)
        guard reveal.nonce.count == 32,
              Self.commitment(publicKey: reveal.eph, nonce: reveal.nonce) == commitment else {
            throw HandshakeFailure.authenticationFailed
        }
        try deriveKeys(peerEphemeral: reveal.eph, pairingKey: nil, isInitiator: false)
        phase = .awaitingLocalDecision(peer: peer)
        return [.pairingCode(try pairingCode(), peer: peer)]
    }

    private func handleFinished(_ frame: Data, peer: DeviceIdentity) throws -> [Output] {
        let (type, body) = try openRecord(frame)
        guard type == .control, case .finished(let mac) = try jsonDecoder.decode(SecureControl.self, from: body) else {
            throw HandshakeFailure.protocolViolation("expected finished")
        }
        switch role {
        case .responder:
            guard constantTimeEqual(mac, try finishedMAC(label: "client")) else { throw HandshakeFailure.authenticationFailed }
            let reply = try sealControl(.finished(mac: finishedMAC(label: "server")))
            phase = .established(peer: peer)
            return [.send(reply), .established(peer: peer, newlyPaired: false)]
        case .initiator:
            guard constantTimeEqual(mac, try finishedMAC(label: "server")) else { throw HandshakeFailure.authenticationFailed }
            phase = .established(peer: peer)
            return [.established(peer: peer, newlyPaired: false)]
        }
    }

    private func handleDecision(_ frame: Data, peer: DeviceIdentity) throws -> [Output] {
        let (type, body) = try openRecord(frame)
        guard type == .control,
              case .pairingDecision(let accepted, let reason) = try jsonDecoder.decode(SecureControl.self, from: body) else {
            throw HandshakeFailure.protocolViolation("expected decision")
        }
        guard accepted else { throw HandshakeFailure.pairingDeclined(reason) }
        try storePairingKey(for: peer)
        let ack = try sealControl(.pairingAck)
        phase = .established(peer: peer)
        return [.send(ack), .established(peer: peer, newlyPaired: true)]
    }

    private func handleAck(_ frame: Data, peer: DeviceIdentity) throws -> [Output] {
        let (type, body) = try openRecord(frame)
        guard type == .control, case .pairingAck = try jsonDecoder.decode(SecureControl.self, from: body) else {
            throw HandshakeFailure.protocolViolation("expected ack")
        }
        phase = .established(peer: peer)
        return [.established(peer: peer, newlyPaired: true)]
    }

    // MARK: Crypto helpers

    private func deriveKeys(peerEphemeral: Data, pairingKey: SymmetricKey?, isInitiator: Bool) throws {
        let peerKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral)
        } catch {
            throw HandshakeFailure.protocolViolation("ephemeral key")
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peerKey)
        sharedSecret = shared
        transcriptHash = Data(transcript.finalize())

        var ikm = shared.withUnsafeBytes { Data($0) }
        if let pairingKey { ikm.append(pairingKey.withUnsafeBytes { Data($0) }) }
        let info = Data("tandem/v1/\(mode.rawValue)-keys".utf8)
        let material = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: transcriptHash,
            info: info,
            outputByteCount: 96
        ).withUnsafeBytes { Data($0) }

        let clientToServer = SymmetricKey(data: material.subdata(in: 0..<32))
        let serverToClient = SymmetricKey(data: material.subdata(in: 32..<64))
        confirmKey = SymmetricKey(data: material.subdata(in: 64..<96))
        sender = RecordProtector(key: isInitiator ? clientToServer : serverToClient)
        receiver = RecordProtector(key: isInitiator ? serverToClient : clientToServer)
    }

    private func finishedMAC(label: String) throws -> Data {
        guard let confirmKey else { throw HandshakeFailure.protocolViolation("no keys") }
        var hmac = HMAC<SHA256>(key: confirmKey)
        hmac.update(data: Data("tandem/v1/finished/\(label)".utf8))
        hmac.update(data: transcriptHash)
        return Data(hmac.finalize())
    }

    private func pairingCode() throws -> String {
        guard let confirmKey else { throw HandshakeFailure.protocolViolation("no keys") }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("tandem/v1/sas".utf8), using: confirmKey)
        let bytes = Array(mac)
        let value = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) % 1_000_000
        return Self.formatCode(value)
    }

    public static func formatCode(_ value: UInt32) -> String {
        let digits = String(format: "%06u", value)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    private func storePairingKey(for peer: DeviceIdentity) throws {
        guard let sharedSecret else { throw HandshakeFailure.protocolViolation("no secret") }
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("tandem/v1/pairing-key".utf8),
            outputByteCount: 32
        )
        try keyStore.setKey(key, for: peer.id)
    }

    private static func commitment(publicKey: Data, nonce: Data) -> Data {
        var hash = SHA256()
        hash.update(data: Data("tandem/v1/commit".utf8))
        hash.update(data: publicKey)
        hash.update(data: nonce)
        return Data(hash.finalize())
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "system RNG unavailable")
        return Data(bytes)
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    // MARK: Framing helpers

    private func handshakeFrame<T: Encodable>(_ type: FrameType, _ value: T) -> Data {
        var frame = Data([type.rawValue])
        // Encoding these fixed structs cannot fail.
        frame.append((try? jsonEncoder.encode(value)) ?? Data())
        appendToTranscript(frame)
        return frame
    }

    private func decodeHandshake<T: Decodable>(_ frame: Data, expecting type: FrameType) throws -> T {
        guard let first = frame.first, first == type.rawValue else {
            throw HandshakeFailure.protocolViolation("expected frame \(type)")
        }
        appendToTranscript(frame)
        do {
            return try jsonDecoder.decode(T.self, from: frame.dropFirst())
        } catch {
            throw HandshakeFailure.protocolViolation("decode \(type)")
        }
    }

    private func appendToTranscript(_ frame: Data) {
        withUnsafeBytes(of: UInt32(frame.count).bigEndian) { transcript.update(bufferPointer: $0) }
        transcript.update(data: frame)
    }

    private func sealControl(_ control: SecureControl) throws -> Data {
        var plaintext = Data([InnerType.control.rawValue])
        plaintext.append(try jsonEncoder.encode(control))
        guard let record = try sender?.seal(plaintext) else { throw HandshakeFailure.protocolViolation("no keys") }
        return record
    }

    private func openRecord(_ frame: Data) throws -> (InnerType, Data) {
        guard let plaintext = try receiver?.open(frame) else { throw HandshakeFailure.protocolViolation("no keys") }
        guard let first = plaintext.first, let type = InnerType(rawValue: first) else {
            throw HandshakeFailure.protocolViolation("inner type")
        }
        return (type, plaintext.dropFirst())
    }

    private func fail(_ failure: HandshakeFailure) -> [Output] {
        phase = .failed
        return [.failed(failure)]
    }
}
