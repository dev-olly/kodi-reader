import Foundation
import Observation

/// Persists Ask AI model configs and the selected model id next to `library.json`.
/// API keys are never written here — they live in the Keychain.
@MainActor
@Observable
final class AIConfigStore {
    private(set) var configs: [AIModelConfig]
    var selectedModelID: UUID? {
        didSet {
            guard selectedModelID != oldValue else { return }
            save()
        }
    }

    @ObservationIgnored private let fileURL: URL

    init(directory: URL) {
        let url = directory.appendingPathComponent("ai-models.json")
        self.fileURL = url
        if let payload = Self.load(from: url), !payload.configs.isEmpty {
            configs = payload.configs
            selectedModelID = payload.selectedModelID
                ?? payload.configs.first?.id
        } else {
            configs = AIModelConfig.presets
            selectedModelID = configs.first?.id
            save()
        }
    }

    var selectedConfig: AIModelConfig? {
        guard let selectedModelID else { return configs.first }
        return configs.first { $0.id == selectedModelID } ?? configs.first
    }

    func upsert(_ config: AIModelConfig) {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        if selectedModelID == nil {
            selectedModelID = config.id
        }
        save()
    }

    func remove(id: UUID) {
        configs.removeAll { $0.id == id }
        KeychainStore.delete(account: id.uuidString)
        if selectedModelID == id {
            selectedModelID = configs.first?.id
        }
        save()
    }

    /// Adds any built-in presets that the user does not already have (matched by id).
    func restorePresets() {
        for preset in AIModelConfig.presets where !configs.contains(where: { $0.id == preset.id }) {
            configs.append(preset)
        }
        if selectedModelID == nil {
            selectedModelID = configs.first?.id
        }
        save()
    }

    func save() {
        let payload = Payload(configs: configs, selectedModelID: selectedModelID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct Payload: Codable {
        var configs: [AIModelConfig]
        var selectedModelID: UUID?
    }

    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

}
