import Foundation
import Observation

struct SavedPrompt: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var text: String
}

/// Personal Ask AI prompts, shared by all books on this Mac.
@MainActor
@Observable
final class SavedPromptStore {
    private(set) var prompts: [SavedPrompt]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "askAI.savedPrompts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedPrompt].self, from: data) {
            prompts = decoded
        } else {
            prompts = []
        }
    }

    @discardableResult
    func save(id: UUID? = nil, title: String, text: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !text.isEmpty else { return false }
        guard !prompts.contains(where: {
            $0.id != id && $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }) else { return false }

        if let id, let index = prompts.firstIndex(where: { $0.id == id }) {
            prompts[index].title = title
            prompts[index].text = text
        } else {
            prompts.append(SavedPrompt(id: UUID(), title: title, text: text))
        }
        persist()
        return true
    }

    func delete(_ id: UUID) {
        prompts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        defaults.set(data, forKey: key)
    }
}
