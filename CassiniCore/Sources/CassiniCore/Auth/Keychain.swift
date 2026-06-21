import Foundation
import Security

/// Persists the per-ring 16-byte auth key in the system Keychain (spec §3.2).
/// Keyed by the ring's stable identifier so multiple rings can coexist.
public struct AuthKeyStore {
    private let service: String

    public init(service: String = "com.matjic.cassini.authkey") {
        self.service = service
    }

    /// Store (or replace) the auth key for a ring identifier.
    @discardableResult
    public func save(_ key: [UInt8], ringID: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ringID,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Load the auth key for a ring identifier, if present.
    public func load(ringID: String) -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ringID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return [UInt8](data)
    }

    /// Remove the stored key for a ring (e.g. after a factory reset).
    @discardableResult
    public func delete(ringID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ringID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
