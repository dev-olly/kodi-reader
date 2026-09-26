import Foundation

/// Build configuration controls unreleased features independently of authentication.
enum AIFeatureFlags {
    static var paymentsEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "PaymentsEnabled") as? String == "YES"
    }
}
