import Foundation

/// File-backed storage for model API keys.
///
/// Keys live next to `library.json` as `ai-keys.json` (owner-only). The login
/// Keychain cannot be used without a password dialog on this ad-hoc-signed
/// sandboxed build, so we keep secrets in the app's private container instead.
enum APIKeyStore {
    private static var fileURL: URL {
        AppDataDirectory.root.appendingPathComponent("ai-keys.json")
    }

    private static var cache: [String: String]?

    static func get(account: String) -> String? {
        let value = load()[account]
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    static func set(_ value: String, account: String) throws {
        var keys = load()
        keys[account] = value
        try persist(keys)
    }

    static func delete(account: String) {
        var keys = load()
        guard keys.removeValue(forKey: account) != nil else { return }
        try? persist(keys)
    }

    static func hasKey(account: String) -> Bool {
        get(account: account) != nil
    }

    private static func load() -> [String: String] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            cache = [:]
            return [:]
        }
        cache = decoded
        return decoded
    }

    private static func persist(_ keys: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(keys)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        cache = keys
    }
}
