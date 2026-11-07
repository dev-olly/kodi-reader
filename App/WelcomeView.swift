import EpubKit
import ReaderUI
import SwiftUI

/// Shown when no document is open: a way in, plus whatever you were reading last.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var bookToDelete: BookRecord?
    @State private var searchText = ""
    @AppStorage("librarySort") private var librarySort: LibrarySort = .dateRead
    @AppStorage("librarySortAscending") private var sortAscending = false
    @AppStorage("libraryFilter") private var libraryFilter: LibraryFilter = .all
    @FocusState private var searchFocused: Bool

    private var visibleBooks: [BookRecord] {
        LibraryQuery(searchText: searchText, sort: librarySort,
                     ascending: sortAscending, filter: libraryFilter)
            .apply(to: model.recents)
    }

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 32) {
            HStack {
                Image("KodiLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityLabel("Kodi Reader")
                Spacer()
                AIAccountMenu(auth: model.aiAuth).frame(maxWidth: 220)
                UpdateButton()
                Button { model.showReminders() } label: {
                    Label("Reminders", systemImage: "bell")
                }
                .controlSize(.large)
                Button { model.presentOpenPanel() } label: {
                    Label("Open Document", systemImage: "plus")
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
            if model.settings.showReadingProgress {
                ReadingProgressCard()
            }
            Divider()
            if !model.recents.isEmpty {
                recents
            } else {
                ContentUnavailableView("Room for a good book", systemImage: "books.vertical")
                    .frame(maxWidth: .infinity)
            }
            HStack {
                Text("Kodi Reader \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(model.settings.theme.muted)
                Spacer()
            }
            .font(.caption)
          }
          .padding(40)
          .frame(maxWidth: 1000, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .background(model.settings.theme.surface)
        .confirmationDialog("Delete this book and its reading data?", isPresented: Binding(
            get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } }
        ), titleVisibility: .visible) {
            if let target = bookToDelete {
                Button(target.cloudIdentity == nil ? "Delete Book and Notes" : "Delete Book and Notes Everywhere", role: .destructive) {
                    model.deleteEverywhere(target); bookToDelete = nil
                }
            }
        } message: {
            Text("This deletes the book, notes, reminders, drawings, bookmarks, and saved conversations. Synced deletions reach other Macs when they reconnect. Use Remove Download to keep your reading data.")
        }
    }

    private var recents: some View {
        let books = visibleBooks
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your library")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                Spacer()
                Text(books.count == model.recents.count
                     ? "\(books.count) \(books.count == 1 ? "book" : "books")"
                     : "\(books.count) of \(model.recents.count) books")
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(model.settings.theme.muted)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    searchField.frame(minWidth: 220)
                    filterMenu
                    sortControls
                }
                VStack(alignment: .leading, spacing: 12) {
                    searchField
                    HStack(spacing: 12) {
                        filterMenu
                        Spacer(minLength: 0)
                        sortControls
                    }
                }
            }

            if librarySort == .dateAdded, model.recents.contains(where: { $0.addedAt == nil }) {
                Text("Older books without an added date appear last.")
                    .font(.caption)
                    .foregroundStyle(model.settings.theme.muted)
            }

            if books.isEmpty {
                ContentUnavailableView {
                    Label("No matching books", systemImage: "magnifyingglass")
                } description: {
                    Text("Try another title or author, or choose a different reading filter.")
                } actions: {
                    Button("Clear search and filters") {
                        searchText = ""
                        libraryFilter = .all
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(books) { record in
                        recentRow(record)
                    }
                }
            }

        }
        .onChange(of: librarySort) { _, sort in
            sortAscending = sort == .title
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(model.settings.theme.muted)
            TextField("Search title or author", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search your library")
                .onKeyPress(.escape) {
                    guard !searchText.isEmpty else { return .ignored }
                    searchText = ""
                    return .handled
                }
            if !searchText.isEmpty {
                Button { searchText = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(model.settings.theme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear book search")
                .help("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? model.settings.theme.accent.opacity(0.6) : model.settings.theme.border,
                              lineWidth: 1)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Reading filter", selection: $libraryFilter) {
                ForEach(LibraryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(libraryFilter.title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter books: \(libraryFilter.title)")
        .help(libraryFilter == .recentlyRead ? "Books read in the last 7 days" : "Filter by reading status")
    }

    private var sortControls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Sort by", selection: $librarySort) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    Text(librarySort.title)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Sort books: \(librarySort.title)")

            Button { sortAscending.toggle() } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reverse sort order")
            .accessibilityValue(sortDirection)
            .help("\(sortDirection). Click to reverse.")
        }
        .fixedSize()
    }

    private var sortDirection: String {
        if librarySort == .title { return sortAscending ? "A to Z" : "Z to A" }
        return sortAscending ? "Oldest first" : "Newest first"
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
                        } else if record.documentKind == .pdf {
                            Text("PDF")
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
                    if let downloading = model.sync.status.downloads[record.id] {
                        ProgressView("Downloading…", value: downloading).font(.caption)
                    } else if model.importedURL(for: record) == nil {
                        Label(record.cloudFile != nil && model.sync.preferences.mode == .booksAndNotes ? "In \(model.sync.provider.title)" : "Locate file to read",
                              systemImage: model.sync.provider == .iCloud ? "icloud" : "externaldrive")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.sync.isLocalRecovery(record.id) {
                        Text("Recovered locally").font(.caption).foregroundStyle(.secondary)
                    } else if record.cloudIdentity == nil {
                        Text("Locate file to enable sync").font(.caption).foregroundStyle(.secondary)
                    }
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
        .disabled(model.sync.status.downloads[record.id] != nil)
        .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(record.title), \(record.author)")
        .accessibilityValue("\(Int(record.progress * 100)) percent read")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Rename…") { model.documentToRename = record }
            if record.sourceURL != nil {
                Button("Open Original in Browser") {
                    model.openOriginalInBrowser(record)
                }
            }
            if record.cloudFile != nil {
                if model.importedURL(for: record) == nil {
                    Button("Download for Offline Reading") { model.downloadForOffline(record) }
                        .disabled(model.sync.preferences.mode != .booksAndNotes)
                } else {
                    Button("Remove Download") { model.removeDownload(record) }
                }
            }
            Button("Remove from Recent") {
                model.removeFromRecents(record)
            }
            Button(record.cloudIdentity == nil ? "Delete Book and Notes…" : "Delete Book and Notes Everywhere…", role: .destructive) {
                bookToDelete = record
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
                (try? ReaderDocument(fileURL: url))?.coverImageData
            }.value
            if !Task.isCancelled { image = data.flatMap(NSImage.init(data:)) }
        }
    }
}
