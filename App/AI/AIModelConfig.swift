import Foundation

/// Where a model is served from — drives labels and default key requirements.
enum AIModelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case hosted
    case free
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hosted: return "Hosted"
        case .free: return "Free"
        case .local: return "Local"
        }
    }
}

/// One OpenAI-compatible endpoint the user can pick in Ask AI.
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
}
