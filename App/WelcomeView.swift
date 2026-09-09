import EpubKit
import ReaderUI
import SwiftUI

/// Shown when no book is open: a way in, plus whatever you were reading last.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var isFieldHovered = false
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 32) {
            HStack {
                Label("Kodi Reader", systemImage: "book.closed")
                    .font(.headline)
                    .foregroundStyle(model.settings.theme.accent)
                Spacer()
                Button { model.presentOpenPanel() } label: {
                    Label("Open Book", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.recents.isEmpty ? "A little more absorbed." : "Your next chapter.")
                    .font(.system(size: 36, weight: .regular, design: .serif))
                Text(model.recents.isEmpty ? "Your books. Your thoughts." : "Pick up where you left off.")
                    .foregroundStyle(model.settings.theme.muted)
            }
            urlField
                .frame(maxWidth: 520)
            Divider()
            if !model.recents.isEmpty {
                recents
            } else {
                ContentUnavailableView("Room for a good book", systemImage: "books.vertical")
                    .frame(maxWidth: .infinity)
            }
          }
          .padding(40)
          .frame(maxWidth: 1000, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .background(model.settings.theme.surface)
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)

                TextField("Paste or type a URL", text: $urlText)
                    .textFieldStyle(.plain)
                    .focused($urlFieldFocused)
                    .onSubmit { submitURL() }
                    .onChange(of: urlText) { _, _ in urlError = nil }

                Button(action: submitURL) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(hasURLText ? Color.white : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            hasURLText
                                ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(.quaternary),
                            in: .circle
                        )
                }
                .buttonStyle(.plain)
                .disabled(!hasURLText)
                .help("Open URL")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        urlFieldFocused || isFieldHovered
                            ? Color.secondary.opacity(0.45)
                            : Color.clear,
                        lineWidth: 1
                    )
            }
            .onHover { isFieldHovered = $0 }

            if let urlError {
                Text(urlError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var hasURLText: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitURL() {
        guard let url = WebPageURL.normalized(from: urlText) else {
            urlError = ArticleError.invalidURL.localizedDescription
            return
        }
        urlError = nil
        model.openWebBrowser(url: url)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue reading")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(model.recents) { record in
                        recentRow(record)
                    }
                }
        }
    }

    private func recentRow(_ record: BookRecord) -> some View {
        Button { model.reopen(record) } label: {
            HStack(spacing: 12) {
                RecentBookCover(record: record, url: model.importedURL(for: record))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(record.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if record.isWebDocument {
                            Text("Web")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                    Text(record.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: min(1, max(0, record.progress)))
                        .padding(.top, 8)
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
        .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(record.title), \(record.author)")
        .accessibilityValue("\(Int(record.progress * 100)) percent read")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if record.sourceURL != nil {
                Button("Open Original in Browser") {
                    model.openOriginalInBrowser(record)
                }
            }
            Button("Remove from Recent", role: .destructive) {
                model.removeFromRecents(record)
            }
        }
    }
}

private struct RecentBookCover: View {
    let record: BookRecord
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.accentColor.opacity(0.12)
                    Text(String(record.title.prefix(1)))
                        .font(.system(size: 30, design: .serif))
                        .foregroundStyle(.tint)
                }
            }
        }
        .frame(width: 48, height: 70)
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            let data = await Task.detached(priority: .utility) {
                (try? EPUBBook(fileURL: url))?.coverImageData
            }.value
            if !Task.isCancelled { image = data.flatMap(NSImage.init(data:)) }
        }
    }
}
