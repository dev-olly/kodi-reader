import AppKit
import EpubKit
import Observation
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// Application state: the open book, its saved record, and the reader driving it.
@Observable
final class AppModel {
    private(set) var book: EPUBBook?
    private(set) var record: BookRecord?
    private(set) var reader: ReaderController?
    private(set) var recents: [BookRecord] = []

    var errorMessage: String?
    var isShowingContents = false
    var isShowingAnnotations = false

    /// Settings live outside any single book so they persist across opens.
    var settings: ReaderSettings {
        didSet {
            guard settings != oldValue else { return }
            reader?.settings = settings
            store.saveSettings(settings)
        }
    }

    @ObservationIgnored private let store: LibraryStore
    /// URLs whose security scope we hold open, to be released on close.
    @ObservationIgnored private var scopedURL: URL?

    init() {
        let store = (try? LibraryStore()) ?? LibraryStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("library.json")
        )
        self.store = store
        settings = store.loadSettings(ReaderSettings.self) ?? ReaderSettings()
        recents = store.recentBooks()
    }

    // MARK: - Opening and closing

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose an EPUB to read"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        closeBook()

        let didScope = url.startAccessingSecurityScopedResource()
        do {
            let book = try EPUBBook(fileURL: url)
            let existing = store.record(for: book.bookID)

            var record = existing ?? BookRecord(
                id: book.bookID,
                title: book.title,
                author: book.author
            )
            record.title = book.title
            record.author = book.author
            record.lastOpenedAt = Date()
            record.lastKnownPath = url.path
            record.fileBookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            store.upsert(record)

            let controller = ReaderController(settings: settings)
            wire(controller, bookID: book.bookID)

            scopedURL = didScope ? url : nil
            self.book = book
            self.record = record
            reader = controller
            recents = store.recentBooks()
            errorMessage = nil
        } catch {
            if didScope { url.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
        }
    }

    /// Reopens a book from the recents list using its saved bookmark.
    func reopen(_ record: BookRecord) {
        if let data = record.fileBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                open(url: url)
                return
            }
        }
        if let path = record.lastKnownPath, FileManager.default.fileExists(atPath: path) {
            open(url: URL(fileURLWithPath: path))
            return
        }
        errorMessage = "\"\(record.title)\" could not be found. It may have been moved or deleted."
    }

    func closeBook() {
        store.flush()
        reader?.tearDown()
        reader = nil
        book = nil
        record = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        recents = store.recentBooks()
    }

    func removeFromRecents(_ record: BookRecord) {
        store.remove(bookID: record.id)
        recents = store.recentBooks()
    }

    func flush() {
        store.flush()
    }

    // MARK: - Reader wiring

    private func wire(_ controller: ReaderController, bookID: String) {
        controller.onPositionChanged = { [weak self] locator in
            guard let self else { return }
            record?.position = locator
            record?.progress = locator.totalProgression ?? 0
            store.update(bookID) { stored in
                stored.position = locator
                stored.progress = locator.totalProgression ?? 0
                stored.lastOpenedAt = Date()
            }
        }
        controller.onSettingsChanged = { [weak self] updated in
            self?.settings = updated
        }
    }

    /// Called once the reader view is on screen and able to load content.
    func startReading() {
        guard let reader, let record else { return }
        reader.start(at: record.position, annotations: record.annotations)
    }

    // MARK: - Annotations

    /// Creates a highlight from the current selection and clears it.
    /// Returns the new annotation so the UI can open the note editor immediately.
    @discardableResult
    func addHighlight(color: HighlightColor) -> Annotation? {
        guard
            let reader,
            let selection = reader.selection,
            let bookID = book?.bookID
        else { return nil }

        let annotation = Annotation(
            locator: selection.locator,
            text: selection.text,
            color: color,
            chapterTitle: reader.chapterTitle
        )
        mutateAnnotations(bookID: bookID) { $0.append(annotation) }
        reader.clearSelection()
        return annotation
    }

    func updateNote(_ note: String, for id: UUID) {
        guard let bookID = book?.bookID else { return }
        mutateAnnotations(bookID: bookID) { annotations in
            guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[index].note = note.isEmpty ? nil : note
            annotations[index].modifiedAt = Date()
        }
    }

    func changeColor(_ color: HighlightColor, for id: UUID) {
        guard let bookID = book?.bookID else { return }
        mutateAnnotations(bookID: bookID) { annotations in
            guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[index].color = color
            annotations[index].modifiedAt = Date()
        }
    }

    func deleteAnnotation(_ id: UUID) {
        guard let bookID = book?.bookID else { return }
        mutateAnnotations(bookID: bookID) { $0.removeAll { $0.id == id } }
    }

    func annotation(with id: UUID) -> Annotation? {
        record?.annotations.first { $0.id == id }
    }

    private func mutateAnnotations(bookID: String, _ transform: (inout [Annotation]) -> Void) {
        guard var record else { return }
        transform(&record.annotations)
        self.record = record
        store.update(bookID) { $0.annotations = record.annotations }
        reader?.setAnnotations(record.annotations)
    }

    // MARK: - Bookmarks

    var isCurrentPageBookmarked: Bool {
        guard let reader, let record else { return false }
        return record.bookmarks.contains {
            $0.locator.spineIndex == reader.spineIndex
                && $0.locator.start == currentPosition(reader)?.start
        }
    }

    func toggleBookmark() {
        guard let reader, var record, let locator = currentPosition(reader) else { return }

        if let index = record.bookmarks.firstIndex(where: {
            $0.locator.spineIndex == locator.spineIndex && $0.locator.start == locator.start
        }) {
            record.bookmarks.remove(at: index)
        } else {
            record.bookmarks.append(
                Bookmark(locator: locator, chapterTitle: reader.chapterTitle)
            )
        }

        let bookmarks = record.bookmarks
        self.record = record
        store.update(record.id) { $0.bookmarks = bookmarks }
    }

    private func currentPosition(_ reader: ReaderController) -> Locator? {
        record?.position ?? Locator(
            spineIndex: reader.spineIndex,
            start: TextPosition(elementPath: [], offset: 0)
        )
    }
}
