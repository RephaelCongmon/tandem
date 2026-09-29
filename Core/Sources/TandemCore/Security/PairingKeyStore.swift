import CryptoKit
import Foundation
import os
import Security

/// Stores the 256-bit long-term key shared with each paired Mac.
public protocol PairingKeyStore: AnyObject, Sendable {
    func key(for peerID: String) -> SymmetricKey?
    func setKey(_ key: SymmetricKey, for peerID: String) throws
    func removeKey(for peerID: String)
}

public enum KeychainError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Thin wrapper over generic-password Keychain items.
public struct KeychainItemStore: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ data: Data, account: String, label: String? = nil) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if let label { attributes[kSecAttrLabel as String] = label }

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Pairing keys in the login Keychain, one item per peer device id. Reads are
/// cached in memory because every reconnect needs the key.
public final class KeychainPairingKeyStore: PairingKeyStore, @unchecked Sendable {
    private let items: KeychainItemStore
    private let lock = NSLock()
    private var cache: [String: SymmetricKey] = [:]
    private let log = Logger(subsystem: "com.rofel.tandem", category: "Keychain")

    public init(service: String) {
        items = KeychainItemStore(service: service)
    }

    public func key(for peerID: String) -> SymmetricKey? {
        lock.lock()
        if let cached = cache[peerID] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let data = items.read(account: peerID), data.count == 32 else { return nil }
        let key = SymmetricKey(data: data)
        lock.lock()
        cache[peerID] = key
        lock.unlock()
        return key
    }

    public func setKey(_ key: SymmetricKey, for peerID: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        try items.write(data, account: peerID, label: "Tandem pairing key")
        lock.lock()
        cache[peerID] = key
        lock.unlock()
    }

    public func removeKey(for peerID: String) {
        items.delete(account: peerID)
        lock.lock()
        cache[peerID] = nil
        lock.unlock()
        log.info("Removed pairing key for peer \(peerID, privacy: .private)")
    }
}

/// Volatile key store for tests and previews.
public final class InMemoryPairingKeyStore: PairingKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]

    public init() {}

    public func key(for peerID: String) -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return keys[peerID]
    }

    public func setKey(_ key: SymmetricKey, for peerID: String) throws {
        lock.lock()
        keys[peerID] = key
        lock.unlock()
    }

    public func removeKey(for peerID: String) {
        lock.lock()
        keys[peerID] = nil
        lock.unlock()
    }
}
