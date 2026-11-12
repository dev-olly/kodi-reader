import EpubKit
import ReaderUI
import SwiftUI

enum LibraryDestination: String {
    case library, notes, reminders
}

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: LibraryDestination

    private var palette: LibraryPalette { .init(isDark: model.settings.theme.isDark) }
    private var reminderCount: Int {
        model.reminderBooks.reduce(0) { count, book in
            count + book.reminders.filter { !$0.isCompleted }.count
        }
    }
    private var syncIsEnabled: Bool {
        model.sync.provider != .off && model.sync.preferences.mode != .off
    }

    var body: some View {
        GeometryReader { geometry in
            sidebar(height: geometry.size.height)
        }
        .frame(width: 204)
        .foregroundStyle(palette.ink)
        .background(palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.line).frame(width: 1)
        }
    }

    private func sidebar(height: CGFloat) -> some View {
        let compact = height < 740
        return VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 25)
                .padding(.top, compact ? 24 : 36)
                .padding(.bottom, compact ? 26 : 48)

            Text("YOUR SPACE")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.3)
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)

            VStack(spacing: 6) {
                navigationRow(.library, title: "Library", symbol: "book")
                navigationRow(.notes, title: "Notes", symbol: "doc.text")
                navigationRow(.reminders, title: "Reminders", symbol: "magnifyingglass", count: reminderCount)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 20)

            if height >= 680 {
                quote
                    .padding(.horizontal, 27)
                    .padding(.bottom, compact ? 24 : 32)
            }

            footer(compact: compact)
                .padding(.horizontal, 27)
                .padding(.bottom, compact ? 18 : 23)
        }
        .frame(width: 204, height: height, alignment: .topLeading)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("KodiLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Kodi")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.7)
                Text("reader")
                    .font(.system(size: 10, weight: .regular))
                    .tracking(2.5)
                    .foregroundStyle(palette.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kodi Reader")
    }

    private func navigationRow(_ destination: LibraryDestination, title: String,
                               symbol: String, count: Int = 0) -> some View {
        let isSelected = selection == destination
        return Button { selection = destination } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 3)
                if count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(palette.accentSoft, in: .capsule)
                }
            }
            .foregroundStyle(isSelected ? palette.accent : palette.muted)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(isSelected ? palette.accentSoft : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(count > 0 ? "\(count) open reminders" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var quote: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("“")
                .font(.custom("Georgia", size: 48))
                .foregroundStyle(palette.muted.opacity(0.3))
                .frame(height: 25, alignment: .leading)
                .accessibilityHidden(true)
            Text("A book is a dream\nyou hold in your hands.")
                .font(.custom("Georgia", size: 13))
                .italic()
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(palette.muted)
                .padding(.top, 8)
            Text("NEIL GAIMAN")
                .font(.system(size: 8, weight: .medium))
                .tracking(1.3)
                .foregroundStyle(palette.muted.opacity(0.8))
                .padding(.top, 15)
        }
    }

    private func footer(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            if model.settings.showReadingProgress {
                ReadingProgressToolbarButton()
                    .buttonStyle(.plain)
                    .controlSize(.small)
            }
            UpdateButton()
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                AIAccountMenu(auth: model.aiAuth)
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .controlSize(.small)
            }
            .foregroundStyle(palette.muted)

            SettingsLink {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape").font(.system(size: 15))
                    Text("Settings").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.muted)

            HStack(spacing: 6) {
                Circle().fill(palette.accent).frame(width: 4, height: 4)
                Text(syncIsEnabled
                     ? "\(model.sync.provider.title) · \(model.sync.status.phase.rawValue)"
                     : "Your library, on this device")
                    .font(.system(size: 9))
                    .lineLimit(2)
            }
            .foregroundStyle(palette.muted)
            .help(syncIsEnabled ? (model.sync.status.message ?? model.sync.preferences.mode.title)
                  : "Your books and notes are stored locally.")
        }
    }
}

/// A library-wide view of the actual saved annotations, including books hidden from Recents.
struct LibraryNotesView: View {
    @Environment(AppModel.self) private var model
    let onOpen: (BookRecord, Annotation) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var palette: LibraryPalette { .init(isDark: model.settings.theme.isDark) }
    private var entries: [LibraryNoteEntry] {
        model.reminderBooks.flatMap { book in
            book.annotations.map { LibraryNoteEntry(book: book, annotation: $0) }
        }.sorted {
            if $0.annotation.modifiedAt != $1.annotation.modifiedAt {
                return $0.annotation.modifiedAt > $1.annotation.modifiedAt
            }
            return $0.id < $1.id
        }
    }
    private var filteredEntries: [LibraryNoteEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.book.title, entry.book.author, entry.annotation.text,
             entry.annotation.plainNotePreview, entry.annotation.chapterTitle ?? ""]
                .joined(separator: "\n").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
        }
        .foregroundStyle(palette.ink)
        .background(palette.background)
    }

    private func content(width: CGFloat) -> some View {
        let horizontalPadding: CGFloat = width >= 1450 ? 64 : (width > 1000 ? 46 : 28)
        return VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, horizontalPadding)
                .padding(.top, width > 1000 ? 47 : 32)
                .padding(.bottom, 28)
            if entries.isEmpty {
                emptyState
            } else {
                searchField
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 24)
                if filteredEntries.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(filteredEntries) { entry in
                                LibraryNoteRow(entry: entry, palette: palette) {
                                    onOpen(entry.book, entry.annotation)
                                }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, 36)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("YOUR IDEAS, KEPT CLOSE")
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.7)
                .foregroundStyle(palette.accent)
            Text("Notes")
                .font(.system(size: 33, weight: .semibold))
                .tracking(-1.35)
                .padding(.bottom, 1)
                .accessibilityAddTraits(.isHeader)
            Text("The passages and thoughts you’ve kept along the way.")
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.muted)
            TextField("Search notes, highlights, or books", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search all notes and highlights")
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear note search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 13)
        .frame(height: 38)
        .background(palette.surface, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? palette.accent.opacity(0.6) : palette.line)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("A thought to keep.", systemImage: "doc.text")
        } description: {
            Text("Highlight a passage or add a note while reading. You’ll find it here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryNoteEntry: Identifiable {
    let book: BookRecord
    let annotation: Annotation
    var id: String { book.id + ":" + annotation.id.uuidString }
}

private struct LibraryNoteRow: View {
    let entry: LibraryNoteEntry
    let palette: LibraryPalette
    let onOpen: () -> Void

    private var annotation: Annotation { entry.annotation }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: annotation.hasContent ? "doc.text" : "highlighter")
                    .font(.system(size: 10))
                Text(entry.book.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(annotation.modifiedAt, style: .date)
                    .font(.system(size: 9))
            }
            .font(.system(size: 10))
            .foregroundStyle(palette.muted)

            if !annotation.text.isEmpty {
                Text(annotation.text)
                    .font(.custom("Georgia", size: 17))
                    .lineSpacing(5)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(annotation.visibleHighlightColor.swiftUIColor)
                            .frame(width: 3)
                    }
            }
            if annotation.hasNote {
                Text(annotation.plainNotePreview)
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .foregroundStyle(palette.muted)
            }
            HStack(spacing: 12) {
                if annotation.hasDrawing || !annotation.sketches.isEmpty {
                    Label("Drawing", systemImage: "pencil.tip.crop.circle")
                }
                if !annotation.audioRecordings.isEmpty {
                    Label("Audio", systemImage: "waveform")
                }
                Spacer(minLength: 4)
                Button(action: onOpen) {
                    HStack(spacing: 5) {
                        Text("Open in book")
                        Image(systemName: "arrow.up.right").font(.system(size: 8))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                .accessibilityLabel("Open note in \(entry.book.title)")
            }
            .font(.system(size: 10))
            .foregroundStyle(palette.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line)
        }
    }
}
