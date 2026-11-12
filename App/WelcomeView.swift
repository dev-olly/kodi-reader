import EpubKit
import ReaderUI
import SwiftUI

/// The library and its navigation stay separate from the reading workspace.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    var onOpenNote: (BookRecord, Annotation) -> Void
    @State private var destination: LibraryDestination = .library
    @State private var bookToDelete: BookRecord?
    @State private var showingWebpage = false
    @State private var searchText = ""
    @AppStorage("librarySort") private var librarySort: LibrarySort = .dateRead
    @AppStorage("librarySortAscending") private var sortAscending = false
    @AppStorage("libraryFilter") private var libraryFilter: LibraryFilter = .all
    @AppStorage("libraryLayout") private var layout = "grid"
    @FocusState private var searchFocused: Bool

    private var palette: LibraryPalette { LibraryPalette(isDark: model.settings.theme.isDark) }

    private var visibleBooks: [BookRecord] {
        LibraryQuery(searchText: searchText, sort: librarySort,
                     ascending: sortAscending, filter: libraryFilter)
            .apply(to: model.recents)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                LibrarySidebar(selection: $destination)
                Group {
                    switch destination {
                    case .library:
                        library(width: geometry.size.width)
                    case .notes:
                        LibraryNotesView(onOpen: onOpenNote)
                    case .reminders:
                        reminders(width: geometry.size.width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.background)
        .foregroundStyle(palette.ink)
        .tint(palette.accent)
        .sheet(isPresented: $showingWebpage) { SaveWebpageSheet() }
        .confirmationDialog("Delete this book and its reading data?", isPresented: Binding(
            get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } }
        ), titleVisibility: .visible) {
            if let target = bookToDelete {
                Button(target.cloudIdentity == nil ? "Delete Book and Notes" : "Delete Book and Notes Everywhere", role: .destructive) {
                    model.deleteEverywhere(target)
                    bookToDelete = nil
                }
            }
        } message: {
            Text("This deletes the book, notes, reminders, drawings, bookmarks, and saved conversations. Synced deletions reach other Macs when they reconnect. Use Remove Download to keep your reading data.")
        }
        .onChange(of: librarySort) { _, sort in sortAscending = sort == .title }
    }

    private func library(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 32)
                tools.padding(.bottom, 23)
                filters.padding(.bottom, 29)
                books
                footer.padding(.top, 50).padding(.bottom, 24)
            }
            .padding(.horizontal, contentPadding(width))
            .padding(.top, width > 1000 ? 47 : 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("library-content")
    }

    private func contentPadding(_ width: CGFloat) -> CGFloat {
        width >= 1450 ? 64 : (width > 1000 ? 46 : 28)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                heading
                Spacer(minLength: 16)
                importActions.padding(.top, 24)
            }
            VStack(alignment: .leading, spacing: 20) {
                heading
                importActions
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("YOUR READING SPACE")
                .font(.system(size: 8, weight: .semibold)).tracking(1.7)
                .foregroundStyle(palette.accent)
            Text("Library")
                .font(.system(size: 33, weight: .semibold)).tracking(-1.35)
                .padding(.bottom, 1)
                .accessibilityAddTraits(.isHeader)
            Text(model.recents.isEmpty
                 ? "A quiet place for your next good read."
                 : "\(model.recents.count) \(model.recents.count == 1 ? "document" : "documents") · A little further, every day.")
                .font(.system(size: 12)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importActions: some View {
        HStack(spacing: 8) {
            Button { showingWebpage = true } label: {
                Label("Save a webpage", systemImage: "link")
            }
            .buttonStyle(LibraryActionStyle(palette: palette))
            Button { model.presentOpenPanel() } label: {
                Label("Add books", systemImage: "plus")
            }
            .buttonStyle(LibraryActionStyle(palette: palette, prominent: true))
            .keyboardShortcut("o", modifiers: .command)
        }
        .fixedSize()
    }

    private var tools: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                searchField.frame(maxWidth: 300)
                Spacer(minLength: 12)
                sortControls
                layoutControls
            }
            VStack(alignment: .leading, spacing: 14) {
                searchField
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    sortControls
                    layoutControls
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 15))
            TextField("Search by title or author…", text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 11))
                .foregroundStyle(palette.ink).focused($searchFocused)
                .accessibilityLabel("Search your library")
                .onKeyPress(.escape) {
                    guard !searchText.isEmpty else { return .ignored }
                    searchText = ""
                    return .handled
                }
            if !searchText.isEmpty {
                Button { searchText = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).accessibilityLabel("Clear book search")
            }
        }
        .foregroundStyle(palette.muted).padding(.horizontal, 12)
        .frame(minWidth: 170)
        .frame(height: 35)
        .background(palette.surface, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? palette.accent : palette.line, lineWidth: 1)
        }
    }

    private var sortControls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Sort by", selection: $librarySort) {
                    ForEach(LibrarySort.allCases) { sort in
                        Text(sort == .dateRead ? "Last read" : sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 16) {
                    Text(librarySort == .dateRead ? "Last read" : librarySort.title)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .font(.system(size: 10)).padding(.horizontal, 6).frame(height: 31)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel("Sort books: \(librarySort.title)")
            Button { sortAscending.toggle() } label: {
                Image(systemName: sortAscending ? "arrow.up.to.line" : "arrow.down.to.line")
                    .font(.system(size: 15)).frame(width: 31, height: 31)
            }
            .buttonStyle(.plain).accessibilityLabel("Reverse sort order")
            .accessibilityValue(sortDirection).help("\(sortDirection). Click to reverse.")
        }
        .foregroundStyle(palette.muted).fixedSize()
    }

    private var sortDirection: String {
        if librarySort == .title { return sortAscending ? "A to Z" : "Z to A" }
        return sortAscending ? "Oldest first" : "Newest first"
    }

    private var layoutControls: some View {
        HStack(spacing: 1) {
            layoutButton("grid", title: "Grid view", symbol: "square.grid.2x2")
            layoutButton("list", title: "List view", symbol: "list.bullet")
        }
        .padding(2)
        .background(palette.soft, in: .rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line, lineWidth: 1) }
        .fixedSize()
    }

    private func layoutButton(_ value: String, title: String, symbol: String) -> some View {
        Button { layout = value } label: {
            Image(systemName: symbol).font(.system(size: 15))
                .frame(width: 26, height: 25)
                .foregroundStyle(layout == value ? palette.accent : palette.muted)
                .background(layout == value ? palette.surface : Color.clear, in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityAddTraits(layout == value ? [.isSelected] : []).help(title)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 19) {
                ForEach(LibraryFilter.allCases) { filter in
                    Button { libraryFilter = filter } label: {
                        Text(filter.title)
                            .font(.system(size: 10, weight: libraryFilter == filter ? .semibold : .regular))
                            .foregroundStyle(libraryFilter == filter ? palette.accent : palette.muted)
                            .padding(.bottom, 13)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(libraryFilter == filter ? palette.accent : Color.clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(libraryFilter == filter ? [.isSelected] : [])
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1).offset(y: 1) }
        .accessibilityLabel("Filter library")
    }

    @ViewBuilder
    private var books: some View {
        let books = visibleBooks
        if books.isEmpty {
            emptyLibrary.frame(maxWidth: .infinity).padding(.vertical, 64)
        } else if layout == "list" {
            LazyVStack(spacing: 0) {
                ForEach(books) { record in
                    LibraryBookCard(record: record, isList: true, onDelete: { bookToDelete = $0 })
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 172), spacing: 31, alignment: .leading)],
                      alignment: .leading, spacing: 36) {
                ForEach(books) { record in
                    LibraryBookCard(record: record, onDelete: { bookToDelete = $0 })
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 30, weight: .light))
                .foregroundStyle(palette.accent)
            Text(searchText.isEmpty && libraryFilter == .all ? "Make room for a good book" : "No matching books")
                .font(.system(size: 20, weight: .medium))
            Text(searchText.isEmpty && libraryFilter == .all
                 ? "Add an EPUB or PDF to start reading and collecting ideas."
                 : "Try another search or reading filter.")
                .font(.system(size: 12)).foregroundStyle(palette.muted).multilineTextAlignment(.center)
            Button(searchText.isEmpty && libraryFilter == .all ? "Add books" : "Show all books") {
                if searchText.isEmpty && libraryFilter == .all { model.presentOpenPanel() }
                else { searchText = ""; libraryFilter = .all }
            }
            .buttonStyle(LibraryActionStyle(palette: palette, prominent: true)).padding(.top, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
            Text("EPUB & PDF · Offline reading · Your ideas, kept close")
        }
        .font(.system(size: 8)).foregroundStyle(palette.muted.opacity(0.75))
        .frame(maxWidth: .infinity)
    }

    private func reminders(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text("A LITTLE CURIOSITY, KEPT CLOSE")
                    .font(.system(size: 8, weight: .semibold)).tracking(1.7)
                    .foregroundStyle(palette.accent)
                Text("Reminders").font(.system(size: 33, weight: .semibold)).tracking(-1.35)
                Text("Return to the ideas you want to explore.")
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            .padding(.horizontal, contentPadding(width)).padding(.top, 47)
            RemindersListView(onOpen: { reminder, bookID in model.openReminder(reminder, bookID: bookID) })
        }
    }
}
