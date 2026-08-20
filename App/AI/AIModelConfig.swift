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

    /// Built-in starting set: a hosted key, a free open-source route, and local Ollama.
    static let presets: [AIModelConfig] = [
        AIModelConfig(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            modelID: "gpt-4o-mini",
            kind: .hosted,
            requiresKey: true
        ),
        AIModelConfig(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!,
            name: "OpenRouter (free)",
            baseURL: "https://openrouter.ai/api/v1",
            modelID: "meta-llama/llama-3.3-70b-instruct:free",
            kind: .free,
            requiresKey: true
        ),
        AIModelConfig(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!,
            name: "Ollama (local)",
            baseURL: "http://localhost:11434/v1",
            modelID: "llama3.2",
            kind: .local,
            requiresKey: false
        ),
    ]
}
