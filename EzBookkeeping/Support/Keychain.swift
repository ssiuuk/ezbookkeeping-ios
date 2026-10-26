import Foundation
import Security

/// Keeps each server's sign-in token in the Keychain, readable only on this device after first unlock.
enum Keychain {
    private static let service = "com.ssiuuk.ezbookkeeping.token"

    static func token(for serverId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Saves the token, or deletes it when it is nil or empty. Returns false when the Keychain refused.
    @discardableResult
    static func setToken(_ token: String?, for serverId: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId,
        ]

        guard let token, !token.isEmpty, let data = token.data(using: .utf8) else {
            let status = SecItemDelete(match as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(match as CFDictionary, update as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Forgets every saved token, for a fresh start in the UI tests.
    static func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
