import EpubKit
import SwiftUI

/// Cursor-style chat docked on the leading edge of the reader.
struct AskAIPanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var composerFocused: Bool
    @State private var bottomID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let error = model.chat.errorMessage, !error.isEmpty {
                errorBanner(error)
            }
            Divider()
            composer
        }
        .background(.background)
        .onChange(of: model.chat.shouldFocusComposer) { _, should in
            if should {
                composerFocused = true
                model.chat.shouldFocusComposer = false
            }
        }
        .onChange(of: model.chat.messages.count) { _, _ in
            bottomID = UUID()
        }
        .onAppear {
            if model.chat.shouldFocusComposer {
                composerFocused = true
                model.chat.shouldFocusComposer = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Ask AI")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    model.chat.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New chat")
                .disabled(model.chat.messages.isEmpty && model.chat.input.isEmpty)

                Button {
                    model.isShowingManageModels = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Manage models")
            }

            if model.aiConfig.configs.isEmpty {
                Button("Add a model…") {
                    model.isShowingManageModels = true
                }
                .font(.caption)
            } else {
                Picker("Model", selection: selectedModelBinding) {
                    ForEach(model.aiConfig.configs) { config in
                        Text(config.name).tag(config.id as UUID?)
                    }
                }
                .labelsHidden()
            }
        }
        .padding(12)
    }

    private var selectedModelBinding: Binding<UUID?> {
        Binding(
            get: { model.aiConfig.selectedModelID },
            set: { model.aiConfig.selectedModelID = $0 }
        )
    }

    private var messageList: some View {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
    }

    private var composer: some View {
        Color.clear.frame(height: 1)
    }
}
