import Foundation

/// Where Ask AI is served from.
enum AIModelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case hosted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hosted: return "Hosted"
        }
    }
}

/// OpenAI-compatible endpoint used by Ask AI.
struct AIModelConfig: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var modelID: String
    var kind: AIModelKind
    var requiresKey: Bool

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        modelID: String,
        kind: AIModelKind,
        requiresKey: Bool
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelID = modelID
        self.kind = kind
        self.requiresKey = requiresKey
    }

    // The separately named payment test build talks only to the local test server.
    // Production builds cannot select this endpoint through saved preferences.
    #if KODI_PAYMENT_SANDBOX
    private static let hostedURL = "http://127.0.0.1:55441/v1"
    #else
    private static let hostedURL = "https://kodi-reader-ai.fly.dev/v1"
    #endif

    static let kodiHosted = AIModelConfig(
        id: UUID(uuidString: "A1000000-0000-4000-8000-000000000010")!,
        name: "Kodi AI",
        baseURL: hostedURL,
        modelID: "gpt-5.6-terra",
        kind: .hosted,
        requiresKey: false
    )

    /// Legacy configs decode from older installs, but Ask AI now uses Kodi AI.
    static let presets: [AIModelConfig] = [
        kodiHosted,
    ]
}
