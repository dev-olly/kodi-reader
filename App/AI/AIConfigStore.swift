import Foundation
import Observation

/// Persists Ask AI model configs and the selected model id next to `library.json`.
/// API keys are never written here — they live in `ai-keys.json`.
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
        Self.importLeakedConfigIfNeeded(into: directory)
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

    /// Unsigned builds used to write `ai-models.json` next to the user's real
    /// home Application Support. Pull that file into the container once.
    private static func importLeakedConfigIfNeeded(into directory: URL) {
        let destination = directory.appendingPathComponent("ai-models.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        guard !AppDataDirectory.isSandboxed else { return }
        let leaked = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EpubReader/ai-models.json")
        // Folio-era unsigned Debug path; LegacyFolioMigration usually copies this first.
        guard leaked.standardizedFileURL != destination.standardizedFileURL,
              FileManager.default.fileExists(atPath: leaked.path)
        else { return }
        try? FileManager.default.copyItem(at: leaked, to: destination)
        try? FileManager.default.removeItem(at: leaked)
    }
}
