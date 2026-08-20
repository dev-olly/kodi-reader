import SwiftUI

/// Settings sheet for adding, editing, and choosing OpenAI-compatible models.
struct ManageModelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AIModelConfig?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.aiConfig.configs) { config in
                        Button {
                            editing = config
                        } label: {
                            row(for: config)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        let ids = indexSet.map { model.aiConfig.configs[$0].id }
                        for id in ids {
                            model.aiConfig.remove(id: id)
                        }
                    }
                } footer: {
                    Text("Keys are stored in the Keychain. Local models such as Ollama do not need a key.")
                }

                Section {
                    Button("Restore Built-in Presets") {
                        model.aiConfig.restorePresets()
                    }
                }
            }
            .navigationTitle("Manage Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAdding = true
                    } label: {
                        Label("Add Model", systemImage: "plus")
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private func row(for config: AIModelConfig) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: config.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.body.weight(.medium))
                Text(config.modelID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(config.baseURL)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.aiConfig.selectedModelID == config.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Selected")
            } else if config.requiresKey, !KeychainStore.hasKey(account: config.id.uuidString) {
                Text("No key")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .contextMenu {
            Button("Use This Model") {
                model.aiConfig.selectedModelID = config.id
            }
            Button("Edit…") { editing = config }
            Divider()
            Button("Delete", role: .destructive) {
                model.aiConfig.remove(id: config.id)
            }
        }
    }

    private func icon(for kind: AIModelKind) -> String {
        switch kind {
        case .hosted: return "cloud"
        case .free: return "gift"
        case .local: return "desktopcomputer"
        }
    }

    private func blankConfig() -> AIModelConfig {
        AIModelConfig(
            name: "Custom model",
            baseURL: "http://localhost:11434/v1",
            modelID: "",
            kind: .local,
            requiresKey: false
        )
    }
}

