import Foundation
import Observation
import TandemCore

/// API keys for AI providers, kept in the Keychain (never in defaults or logs).
@MainActor
@Observable
final class APIKeyStore {
    @ObservationIgnored private let items: KeychainItemStore
    /// Bumped whenever a key changes so views re-evaluate `hasKey`.
    private(set) var revision = 0
    @ObservationIgnored private var cache: [AIProviderKind: String] = [:]

    init(servicePrefix: String) {
        items = KeychainItemStore(service: "\(servicePrefix).apikeys")
    }

    func key(for provider: AIProviderKind) -> String {
        _ = revision
        if let cached = cache[provider] { return cached }
        let value = items.read(account: provider.rawValue).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        cache[provider] = value
        return value
    }

    func hasKey(for provider: AIProviderKind) -> Bool {
        !key(for: provider).isEmpty
    }

    func setKey(_ key: String, for provider: AIProviderKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            items.delete(account: provider.rawValue)
        } else {
            try items.write(Data(trimmed.utf8), account: provider.rawValue, label: "Tandem \(provider.displayName) API key")
        }
        cache[provider] = trimmed
        revision += 1
    }

    /// A redacted preview such as "sk-ant-…4f2a".
    func maskedKey(for provider: AIProviderKind) -> String {
        let key = key(for: provider)
        guard key.count > 10 else { return key.isEmpty ? "" : "••••" }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }
}

/// A Mac this one has paired with.
struct TrustedPeer: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var model: String
    var pairedAt: Date
    var lastConnectedAt: Date?
    var lastLink: LinkKind?
    /// The last session failed authentication; the user must pair again. The key is
    /// kept (never deleted automatically) so a spoofed failure can't erase a pairing.
    var needsRepair = false

    var identity: DeviceIdentity { DeviceIdentity(id: id, name: name, model: model) }

    init(id: String, name: String, model: String, pairedAt: Date, lastConnectedAt: Date?, lastLink: LinkKind?) {
        self.id = id
        self.name = name
        self.model = model
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
        self.lastLink = lastLink
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decode(String.self, forKey: .model)
        pairedAt = try container.decode(Date.self, forKey: .pairedAt)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        lastLink = try container.decodeIfPresent(LinkKind.self, forKey: .lastLink)
        needsRepair = try container.decodeIfPresent(Bool.self, forKey: .needsRepair) ?? false
    }
}

/// Paired devices: metadata in defaults, secrets in the Keychain.
@MainActor
@Observable
final class TrustedPeerStore {
    private(set) var peers: [TrustedPeer] = []
    @ObservationIgnored let keyStore: PairingKeyStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "tandem.trustedPeers"

    init(keyStore: PairingKeyStore, defaults: UserDefaults) {
        self.keyStore = keyStore
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([TrustedPeer].self, from: data) {
            // Drop entries whose Keychain secret disappeared.
            peers = decoded.filter { keyStore.key(for: $0.id) != nil }
        }
    }

    func isTrusted(_ id: String) -> Bool {
        peers.contains { $0.id == id }
    }

    func needsRepair(_ id: String) -> Bool {
        peers.first { $0.id == id }?.needsRepair ?? false
    }

    func markNeedsRepair(_ id: String) {
        guard let index = peers.firstIndex(where: { $0.id == id }), !peers[index].needsRepair else { return }
        peers[index].needsRepair = true
        persist()
    }

    func peer(_ id: String) -> TrustedPeer? {
        peers.first { $0.id == id }
    }

    /// Records a (new or refreshed) pairing after a successful handshake.
    func recordConnection(with identity: DeviceIdentity, link: LinkKind) {
        let now = Date()
        if let index = peers.firstIndex(where: { $0.id == identity.id }) {
            peers[index].name = identity.name
            peers[index].model = identity.model
            peers[index].lastConnectedAt = now
            peers[index].lastLink = link
            peers[index].needsRepair = false
        } else {
            peers.append(TrustedPeer(id: identity.id, name: identity.name, model: identity.model, pairedAt: now, lastConnectedAt: now, lastLink: link))
        }
        persist()
    }

    func forget(_ id: String) {
        keyStore.removeKey(for: id)
        peers.removeAll { $0.id == id }
        persist()
    }

    func forgetAll() {
        for peer in peers { keyStore.removeKey(for: peer.id) }
        peers.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(peers) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
