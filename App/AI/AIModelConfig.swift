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
