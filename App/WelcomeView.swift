import EpubKit
import SwiftUI

/// Shown when no book is open: a way in, plus whatever you were reading last.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var isFieldHovered = false
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "book.closed")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.tertiary)

                Text("Kodi Reader")
                    .font(.system(size: 26, weight: .semibold, design: .serif))

                Text("Drop an EPUB here, or open one to start reading.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Open Book…") { model.presentOpenPanel() }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)

            if !model.recents.isEmpty {
                recents
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.recents) { record in
                        recentRow(record)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(maxWidth: 460)
    }

    private func recentRow(_ record: BookRecord) -> some View {
        Button { model.reopen(record) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(record.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if record.progress > 0.001 {
                    Text("\(Int(record.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
        .contextMenu {
            Button("Remove from Recent", role: .destructive) {
                model.removeFromRecents(record)
            }
        }
    }
}
