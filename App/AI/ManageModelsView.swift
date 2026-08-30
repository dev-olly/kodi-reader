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
                    Text("Keys are stored in this app's private data folder. Local models such as Ollama do not need a key.")
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
            .sheet(item: $editing) { config in
                ModelEditorView(config: config, isNew: false)
            }
            .sheet(isPresented: $isAdding) {
                ModelEditorView(config: blankConfig(), isNew: true)
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
            } else if config.requiresKey, !APIKeyStore.hasKey(account: config.id.uuidString) {
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

private struct ModelEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var config: AIModelConfig
    let isNew: Bool
    @State private var keyDraft = ""
    @State private var keyLoaded = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $config.name)
                Picker("Type", selection: $config.kind) {
                    ForEach(AIModelKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: config.kind) { _, kind in
                    if kind == .local {
                        config.requiresKey = false
                    } else if isNew {
                        config.requiresKey = true
                    }
                }
                TextField("Base URL", text: $config.baseURL)
                TextField("Model ID", text: $config.modelID)
                Toggle("Requires API key", isOn: $config.requiresKey)
                if config.requiresKey {
                    SecureField("API key", text: $keyDraft)
                    Text("Leave blank to keep the existing key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isNew ? "Add Model" : "Edit Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .alert(
                "Could not save key",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onAppear(perform: loadKey)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private var canSave: Bool {
        !config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadKey() {
        guard !keyLoaded else { return }
        keyLoaded = true
        if let existing = APIKeyStore.get(account: config.id.uuidString) {
            keyDraft = existing
        }
    }

    private func save() {
        config.name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.modelID = config.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        model.aiConfig.upsert(config)
        if isNew || model.aiConfig.selectedModelID == nil {
            model.aiConfig.selectedModelID = config.id
        }

        let trimmedKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.requiresKey {
            if !trimmedKey.isEmpty {
                do {
                    try APIKeyStore.set(trimmedKey, account: config.id.uuidString)
                } catch {
                    saveError = error.localizedDescription
                    return
                }
            }
        } else if !trimmedKey.isEmpty {
            do {
                try APIKeyStore.set(trimmedKey, account: config.id.uuidString)
            } catch {
                saveError = error.localizedDescription
                return
            }
        }
        dismiss()
    }
}
