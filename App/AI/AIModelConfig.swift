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

    static let kodiHosted = AIModelConfig(
        id: UUID(uuidString: "A1000000-0000-4000-8000-000000000010")!,
        name: "Kodi AI",
        baseURL: "https://kodi-reader-ai.fly.dev/v1",
        modelID: "gpt-5.6-terra",
        kind: .hosted,
        requiresKey: false
    )

    /// Legacy configs decode from older installs, but Ask AI now uses Kodi AI.
    static let presets: [AIModelConfig] = [
        kodiHosted,
    ]
}
