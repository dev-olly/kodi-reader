import Foundation
import Security

/// Generic-password Keychain access for model API keys.
/// Keys are stored under `account` = the model config's UUID string, never in JSON.
enum KeychainStore {
    static let service = "com.olly.KodiReader.ai-keys"
    static let legacyService = "com.olly.Folio.ai-keys"

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainError.unhandled(updated) }
        } else if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unhandled(added) }
        } else {
            throw KeychainError.unhandled(status)
        }
    }

    static func get(account: String) -> String? {
        get(account: account, service: service)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// True when a non-empty secret is stored for this config.
    static func hasKey(account: String) -> Bool {
        guard let value = get(account: account) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Copies any Folio-era secrets into the current service. Idempotent:
    /// existing new-service items are left alone.
    static func migrateLegacyKeys(additionalAccounts: [String] = []) {
        var accounts = Set(additionalAccounts)
        for account in allAccounts(service: legacyService) {
            accounts.insert(account)
        }
        for preset in AIModelConfig.presets {
            accounts.insert(preset.id.uuidString)
        }
        for account in accounts {
            guard get(account: account, service: service) == nil,
                  let value = get(account: account, service: legacyService),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            try? set(value, account: account)
        }
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    return message
                }
                return "Keychain error (\(status))"
            }
        }
    }

    private static func get(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func allAccounts(service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
