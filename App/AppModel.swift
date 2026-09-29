import AppKit
import EpubKit
import Observation
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

enum AINoteTarget: Equatable {
    case annotation(UUID)
    case selection(ReaderSelection, chapterTitle: String?)
}

/// Application state: the open book, its saved record, and the reader driving it.
@MainActor
@Observable
final class AppModel {
    private(set) var book: ReaderDocument?
    private(set) var record: BookRecord?
    private(set) var reader: ReaderController?
    private(set) var recents: [BookRecord] = []
    private(set) var webBrowser: WebBrowserController?
    private(set) var isSavingWebPage = false
    var isShowingOpenURLSheet = false
    var pendingWebURLText = ""

    var isBrowsing: Bool { webBrowser != nil }

    var errorMessage: String?
    var isShowingContents = false
    var aiNoteTarget: AINoteTarget?
    enum Workspace: String { case closed, notes, askAI }
    private var visibleWorkspace: Workspace = .closed
    @ObservationIgnored private var workspaceTransition = 0
    @ObservationIgnored private var requestedWorkspace: Workspace = .closed
    var workspace: Workspace {
        get { visibleWorkspace }
        set {
            let previousRequest = requestedWorkspace
            requestedWorkspace = newValue
            workspaceTransition += 1
            let transition = workspaceTransition
            guard newValue != visibleWorkspace || newValue != previousRequest else { return }
            let commit = { [weak self] in
                guard let self, self.workspaceTransition == transition else { return }
                self.visibleWorkspace = newValue
            }
            guard let reader else { commit(); return }
            if newValue == .closed {
                reader.endWorkspaceRestore(completion: commit)
            } else if visibleWorkspace == .closed || previousRequest == .closed {
                reader.beginWorkspaceRestore(completion: commit)
            } else {
                commit()
            }
        }
    }
    var isShowingAnnotations: Bool {
        get { workspace == .notes }
        set { if newValue { workspace = .notes } else if workspace == .notes { workspace = .closed } }
    }
    var isShowingAskAI: Bool {
        get { workspace == .askAI }
        set { if newValue { workspace = .askAI } else if workspace == .askAI { workspace = .closed } }
    }
    /// True when page-turn shortcuts should yield to the focused control —
    /// the note editor, Excalidraw, the notes list, or any other sidebar field.
    var isNoteEditorOpen = false {
        didSet { if !isNoteEditorOpen { sync.resumeDeferredChanges() } }
    }
    /// Last colour applied via a swatch, a new note, or the note editor picker.
    private(set) var lastAppliedHighlightColor: HighlightColor?
    let sync: LibrarySyncCoordinator
    let aiConfig: AIConfigStore
    let aiAuth: AIAuthController
    let aiCredits: AICreditsController
    let chat: ChatController
    let savedPrompts: SavedPromptStore

    var notesInSidebar: Bool {
        get { settings.noteEditorPlacement == .sidebar }
        set { settings.noteEditorPlacement = newValue ? .sidebar : .sheet }
    }

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
    /// Live drawing scenes, so switching sheet/sidebar does not wait on disk.
    @ObservationIgnored private var noteFlushHandlers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var openingID: UUID?
    @ObservationIgnored private var drawingCache: [UUID: Data] = [:]
    /// Reading position captured before an in-app browser preview, restored on close.
    @ObservationIgnored private var positionBeforeBrowser: Locator?

    init() {
        let root = AppDataDirectory.prepare()
        let store = LibraryStore(fileURL: root.appendingPathComponent("library.json"))
        self.store = store
        let iCloudEnabled = (Bundle.main.object(forInfoDictionaryKey: "iCloudSyncEnabled") as? String) == "YES"
        self.sync = LibrarySyncCoordinator(store: store, transport: CloudKitSyncTransport(
            stagingDirectory: root.appendingPathComponent("Sync/Payloads"), enabled: iCloudEnabled))
        settings = (try? store.migrateAppearanceSettings(defaultSettings: ReaderSettings()) {
            $0.applyAppearanceDefaults()
        }) ?? store.loadSettings(ReaderSettings.self) ?? ReaderSettings()
        recents = store.recentBooks(limit: .max)

        let aiConfig = AIConfigStore(directory: root)
        self.aiConfig = aiConfig
        let aiAuth = AIAuthController()
        self.aiAuth = aiAuth
        let aiCredits = AICreditsController(auth: aiAuth)
        self.aiCredits = aiCredits
        let chat = ChatController(configStore: aiConfig, auth: aiAuth)
        self.chat = chat
        self.savedPrompts = SavedPromptStore()
        aiAuth.onWillSignOut = { [weak chat, weak aiCredits] in chat?.stop(); aiCredits?.reset() }
        chat.onInsufficientCredits = { [weak aiCredits] in
            guard AIFeatureFlags.paymentsEnabled else { return }
            aiCredits?.showingPacks = true
        }
        chat.onCreditsChanged = { [weak aiCredits] in Task {
            // Give cancellation settlement a moment to reach the server before refreshing.
            try? await Task.sleep(for: .milliseconds(500))
            await aiCredits?.refresh()
        } }
        chat.onPersist = { [weak self] threads, activeID in
            self?.persistChat(threads, activeID: activeID)
        }
        sync.isEntityEditing = { [weak self] entity in
            guard let self, record?.cloudIdentity == entity.bookID else { return false }
            switch entity.kind {
            case .book: return !noteFlushHandlers.isEmpty || chat.isStreaming
            case .annotation:
                guard let key = entity.id.split(separator: ":").last, let id = UUID(uuidString: String(key)) else { return false }
                return noteFlushHandlers[id] != nil
            case .chat: return chat.isStreaming
            default: return false
            }
        }
        sync.onLibraryChanged = { [weak self] in self?.refreshAfterSync() }
        chat.onStreamStopped = { [weak self] in self?.sync.resumeDeferredChanges() }
        chat.contextProvider = { [weak self] in
            AIChatService.Context(
                bookTitle: self?.book?.title ?? self?.record?.title ?? "",
                author: self?.book?.author ?? self?.record?.author ?? "",
                chapterTitle: self?.reader?.chapterTitle
            )
        }
    }

    // MARK: - Opening and closing

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose an EPUB or PDF to read"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func presentOpenURL() {
        pendingWebURLText = webBrowser?.currentURL?.absoluteString ?? ""
        isShowingOpenURLSheet = true
    }

    func submitOpenURL() {
        guard let url = WebPageURL.normalized(from: pendingWebURLText) else {
            errorMessage = ArticleError.invalidURL.localizedDescription
            return
        }
        isShowingOpenURLSheet = false
        pendingWebURLText = ""
        openWebBrowser(url: url)
    }

    func openWebBrowser(url: URL) {
        positionBeforeBrowser = record?.position
        reader?.pinRestoreCurrentPositionOnce()
        if let webBrowser {
            webBrowser.load(url)
            return
        }
        let controller = WebBrowserController()
        webBrowser = controller
        controller.load(url)
    }

    func closeBrowser() {
        webBrowser?.tearDown()
        webBrowser = nil
        isSavingWebPage = false
    }

    /// Called when the reader is on screen again after a browser preview.
    func resumeReadingAfterBrowser() {
        guard let reader, let locator = positionBeforeBrowser else { return }
        positionBeforeBrowser = nil
        reader.restorePosition(locator)
    }

    func openOriginalInBrowser(_ record: BookRecord) {
        guard let url = record.sourceURL else { return }
        openWebBrowser(url: url)
    }

    func saveCurrentWebPage() {
        guard let browser = webBrowser, !isSavingWebPage else { return }
        isSavingWebPage = true
        errorMessage = nil
        browser.extractArticle { [weak self] result in
            Task { @MainActor in
                await self?.finishSavingWebpage(result)
            }
        }
    }

    private func finishSavingWebpage(_ result: Result<ArticleContent, Error>) async {
        defer { isSavingWebPage = false }
        do {
            let article = try result.get()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kodi-web-\(UUID().uuidString).epub")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try await ArticleEPUBBuilder.build(article, to: tempURL)
            open(url: tempURL, sourceURL: article.sourceURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(url: URL, sourceURL: URL? = nil, expectedIdentity: String? = nil, preferredLocalID: String? = nil) {
        closeBook()
        let operation = UUID(); openingID = operation
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let kind: DocumentKind = url.pathExtension.lowercased() == "pdf" ? .pdf : .epub
                let identity = try await Task.detached { try BlobManifest.bookIdentity(file: url, kind: kind) }.value
                guard openingID == operation else { return }
                if let expectedIdentity, identity != expectedIdentity {
                    errorMessage = "This is a different edition or file. Locate the same book to attach its synced notes."
                    return
                }
                openPrepared(url: url, sourceURL: sourceURL, identity: identity, preferredLocalID: preferredLocalID)
            } catch { if openingID == operation { errorMessage = error.localizedDescription } }
        }
    }

    private func openPrepared(url: URL, sourceURL: URL?, identity: String, preferredLocalID: String?) {
        closeBook()

        let didScope = url.startAccessingSecurityScopedResource()
        do {
            // Without a security scope the sandbox cannot read user-selected
            // files after relaunch; fail early with a clear message.
            if !didScope, !FileManager.default.isReadableFile(atPath: url.path) {
                throw EPUBError.cannotAccessFile(url)
            }

            let provisional = try ReaderDocument(fileURL: url, knownBookID: url.pathExtension.lowercased() == "pdf" ? identity : nil)
            var matched = store.record(cloudIdentity: identity)
            if let preferredLocalID, let preferred = store.record(for: preferredLocalID),
               preferred.cloudIdentity == nil || preferred.cloudIdentity == identity {
                matched = preferred
            }
            if matched == nil, let legacy = store.record(for: provisional.bookID),
               let legacyFile = store.existingImportedURL(for: legacy),
               try BlobManifest.bookIdentity(file: legacyFile, kind: legacy.documentKind) == identity {
                matched = legacy
            }
            let localID = matched?.id ?? identity
            // Durable copy inside the container — Recents opens this forever.
            let importedURL = try store.importBook(
                from: url,
                bookID: localID,
                kind: provisional.kind
            )
            let readingFromImport = importedURL.resolvingSymlinksInPath().path
                != url.resolvingSymlinksInPath().path
            let book = try ReaderDocument(fileURL: importedURL, knownBookID: localID)

            if readingFromImport, didScope {
                url.stopAccessingSecurityScopedResource()
            }

            let existing = matched ?? store.record(for: localID)
            var record = existing ?? BookRecord(
                id: book.bookID,
                title: book.title,
                author: book.author,
                documentKind: book.kind
            )
            record.cloudIdentity = sync.isLocalRecovery(localID) ? nil : identity
            record.isHiddenFromRecents = false
            record.title = sync.isLocalRecovery(localID) ? "Recovered version: " + book.title : book.title
            record.author = book.author
            record.documentKind = book.kind
            record.lastOpenedAt = Date()
            record.importedRelativePath = LibraryStore.relativeImportedPath(
                for: book.bookID,
                kind: book.kind
            )
            if let sourceURL {
                record.sourceURL = sourceURL
            }

            // Preserve the user's original path/bookmark when reopening an import.
            // Frozen webpages have no user-selected file — don't record the temp EPUB.
            if sourceURL != nil {
                record.lastKnownPath = existing?.lastKnownPath
                record.fileBookmark = existing?.fileBookmark
            } else if store.isImportedURL(url) {
                record.lastKnownPath = existing?.lastKnownPath ?? record.lastKnownPath
                record.fileBookmark = existing?.fileBookmark
            } else {
                record.lastKnownPath = url.path
                record.fileBookmark = makeSecurityScopedBookmark(for: url)
                    ?? existing?.fileBookmark
            }

            store.upsert(record)
            store.flush()

            let controller = ReaderController(settings: settings)
            wire(controller, bookID: book.bookID)

            scopedURL = (!readingFromImport && didScope) ? url : nil
            self.book = book
            self.record = record
            reader = controller
            recents = store.recentBooks(limit: .max)
            drawingCache.removeAll()
            errorMessage = nil
            chat.load(threads: record.conversationThreads, activeID: record.activeChatID)
        } catch {
            if didScope { url.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
        }
    }

    /// Reopens a book from Recents, preferring the imported library copy.
    func reopen(_ record: BookRecord) {
        if let imported = store.existingImportedURL(for: record) {
            open(url: imported, expectedIdentity: record.cloudIdentity, preferredLocalID: record.id)
            return
        }

        if record.cloudFile != nil, sync.preferences.mode == .booksAndNotes {
            downloadForOffline(record, openAfter: true)
            return
        }
        if let data = record.fileBookmark {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                open(url: url, expectedIdentity: record.cloudIdentity, preferredLocalID: record.id)
                return
            } catch {
                // Fall through to Locate…
            }
        }

        locateAndOpen(record)
    }

    /// One-time re-grant for books opened before library import existed.
    private func locateAndOpen(_ record: BookRecord) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = record.documentKind == .pdf ? [.pdf] : [.epub]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Locate"
        panel.message = "Locate the same \(record.documentKind.rawValue.uppercased()) file for “\(record.title)” to attach its notes."

        if let path = record.lastKnownPath {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.path) {
                panel.directoryURL = directory
            }
            panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url, expectedIdentity: record.cloudIdentity, preferredLocalID: record.id)
    }

    /// Best-effort bookmark of the original file; Recents does not depend on it.
    private func makeSecurityScopedBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return nil
        }
    }

    var canGoHome: Bool { book != nil || isBrowsing }

    /// Leaves the current book or webpage and returns to the welcome screen.
    func goHome() {
        closeBook()
    }

    func closeBook() {
        openingID = nil
        chat.stop()
        persistChat(chat.threads, activeID: chat.activeThreadID)
        flush()
        reader?.tearDown()
        reader = nil
        book = nil
        record = nil
        chat.detach()
        aiNoteTarget = nil
        workspace = .closed
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        recents = store.recentBooks(limit: .max)
        drawingCache.removeAll()
        positionBeforeBrowser = nil
        closeBrowser()
    }

    func removeFromRecents(_ record: BookRecord) {
        store.hideFromRecents(record.id)
        recents = store.recentBooks(limit: .max)
    }

    func importedURL(for record: BookRecord) -> URL? {
        store.existingImportedURL(for: record)
    }

    func flush() {
        for flushEditor in Array(noteFlushHandlers.values) { flushEditor() }
        sync.checkpoint()
    }

    func beginNoteEditing(_ id: UUID, flush: @escaping () -> Void) { noteFlushHandlers[id] = flush }
    func endNoteEditing(_ id: UUID) {
        noteFlushHandlers[id] = nil
        sync.resumeDeferredChanges()
    }

    func refreshAfterSync() {
        recents = store.recentBooks(limit: .max)
        guard let currentID = record?.id else { return }
        guard let updated = store.record(for: currentID) else {
            closeBook()
            return
        }
        record = updated
        drawingCache.removeAll()
        reader?.setAnnotations(updated.annotations)
        if !chat.isStreaming { chat.mergeStoredThreads(updated.conversationThreads) }
    }

    func downloadForOffline(_ record: BookRecord, openAfter: Bool = false) {
        guard sync.status.downloads[record.id] == nil else { return }
        Task {
            do {
                let url = try await sync.download(record)
                if openAfter { open(url: url, expectedIdentity: record.cloudIdentity, preferredLocalID: record.id) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeDownload(_ record: BookRecord) {
        do {
            if self.record?.id == record.id { closeBook() }
            try sync.removeDownload(record)
            refreshAfterSync()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteEverywhere(_ record: BookRecord) {
        do {
            if self.record?.id == record.id { closeBook() }
            try sync.deleteEverywhere(record)
        } catch { errorMessage = error.localizedDescription }
    }

    func showHiddenBooks() {
        for book in store.allBooks() where book.isHiddenFromRecents {
            store.update(book.id) { $0.isHiddenFromRecents = false }
        }
        recents = store.recentBooks(limit: .max)
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
        controller.onAnchorsResolved = { [weak self] resolutions in
            self?.applyAnchorResolutions(resolutions)
        }
        controller.onExternalLink = { [weak self] url in
            self?.openWebBrowser(url: url)
        }
    }

    /// Called once the reader view is on screen and able to load content.
    func startReading() {
        guard let reader, let record else { return }
        reader.start(at: record.position, annotations: record.annotations)
    }

    // MARK: - Ask AI

    /// Pins the on-screen passage before a width change so relayout cannot
    /// fall back to chapter start. This must capture the live viewport, not the
    /// last persisted locator, because saved progress can lag behind scrolling.
    func pinReaderForViewportChange() {
        reader?.pinRestoreCurrentPositionOnce()
    }

    func toggleAskAI() {
        pinReaderForViewportChange()
        isShowingAskAI.toggle()
    }

    func toggleAnnotations() {
        pinReaderForViewportChange()
        isShowingAnnotations.toggle()
    }

    /// Opens the leading chat panel and attaches the current selection, if any.
    func addSelectionToChat() {
        guard book != nil else { return }
        guard let reader, let selection = reader.selection else {
            aiNoteTarget = nil
            pinReaderForViewportChange()
            isShowingAskAI = true
            chat.shouldFocusComposer = true
            return
        }
        reader.pinRestoreOnce(to: selection.locator.start)
        isShowingAskAI = true
        aiNoteTarget = .selection(selection, chapterTitle: reader.chapterTitle)
        let reference = ChatReference(
            quotedText: selection.text,
            chapterTitle: reader.chapterTitle,
            spineIndex: selection.locator.spineIndex
        )
        let locator = selection.locator
        chat.addReference(reference)
        reader.clearSelection()
        reader.extractSurroundingPassage(from: locator) { [weak self] passage in
            Task { @MainActor in
                let before = passage.before.trimmingCharacters(in: .whitespacesAndNewlines)
                let after = passage.after.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !before.isEmpty || !after.isEmpty else { return }
                self?.chat.updateReference(
                    reference.id,
                    contextBefore: before.isEmpty ? nil : before,
                    contextAfter: after.isEmpty ? nil : after
                )
            }
        }
    }

    /// Opens Ask AI with a durable reference to an existing highlight.
    func addAnnotationToChat(_ annotation: Annotation) {
        guard book != nil, let reader else { return }
        reader.pinRestoreOnce(to: annotation.locator.start)
        isShowingAskAI = true
        aiNoteTarget = .annotation(annotation.id)
        let reference = ChatReference(
            quotedText: annotation.text,
            chapterTitle: annotation.chapterTitle,
            spineIndex: annotation.locator.spineIndex
        )
        chat.addReference(reference)
        reader.extractSurroundingPassage(from: annotation.locator) { [weak self] passage in
            Task { @MainActor in
                let before = passage.before.trimmingCharacters(in: .whitespacesAndNewlines)
                let after = passage.after.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !before.isEmpty || !after.isEmpty else { return }
                self?.chat.updateReference(
                    reference.id,
                    contextBefore: before.isEmpty ? nil : before,
                    contextAfter: after.isEmpty ? nil : after
                )
            }
        }
    }

    private func persistChat(_ threads: [ChatThread], activeID: UUID?) {
        guard var record, let bookID = book?.bookID else { return }
        let stored = threads.filter { !$0.messages.isEmpty }
        record.chats = stored.isEmpty ? nil : stored
        record.activeChatID = stored.contains(where: { $0.id == activeID }) ? activeID : stored.first?.id
        record.chatMessages = stored.first(where: { $0.id == record.activeChatID })?.messages
        self.record = record
        store.update(bookID) {
            $0.chats = record.chats
            $0.activeChatID = record.activeChatID
            $0.chatMessages = record.chatMessages
        }
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
        lastAppliedHighlightColor = color
        reader.clearSelection()
        return annotation
    }

    /// Colour for a new note: the next swatch after the last applied colour.
    func nextColorForNewNote() -> HighlightColor {
        if let last = lastAppliedHighlightColor {
            return last.nextFill
        }
        if let latest = record?.annotations.max(by: { $0.createdAt < $1.createdAt }) {
            return latest.color.nextFill
        }
        return .yellow
    }

    func updateNote(
        _ note: String,
        for id: UUID,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard let bookID = book?.bookID, var record else {
            completion?(.failure(NotePersistenceError.missingBook))
            return
        }
        guard let index = record.annotations.firstIndex(where: { $0.id == id }) else {
            completion?(.failure(NotePersistenceError.missingAnnotation))
            return
        }

        record.annotations[index].note = note.isEmpty ? nil : note
        if record.annotations[index].hasNote, record.annotations[index].color == .underline {
            record.annotations[index].color = .yellow
            lastAppliedHighlightColor = .yellow
        }
        record.annotations[index].modifiedAt = Date()
        do {
            try store.updateAndFlush(bookID) { $0.annotations = record.annotations }
            self.record = record
            completion?(.success(()))
            // Refresh the note-dot on painted highlights without a full re-resolve.
            reader?.setAnnotations(record.annotations)
        } catch {
            completion?(.failure(error))
        }
    }

    func appendKodiExcerpt(
        _ excerpt: String,
        to id: UUID,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let annotation = annotation(with: id) else {
            completion(.failure(NotePersistenceError.missingAnnotation))
            return
        }
        let note = NoteMarkdown.appendingKodiExcerpt(
            excerpt,
            to: annotation.note ?? ""
        )
        guard note != (annotation.note ?? "") else {
            completion(.failure(NotePersistenceError.emptyExcerpt))
            return
        }
        updateNote(note, for: id, completion: completion)
    }

    func createKodiNote(
        from excerpt: String,
        for selection: ReaderSelection,
        chapterTitle: String?,
        completion: @escaping (Result<UUID, Error>) -> Void
    ) {
        guard let bookID = book?.bookID, var record else {
            completion(.failure(NotePersistenceError.missingBook))
            return
        }
        let note = NoteMarkdown.appendingKodiExcerpt(excerpt, to: "")
        guard !note.isEmpty else {
            completion(.failure(NotePersistenceError.emptyExcerpt))
            return
        }

        let color = nextColorForNewNote()
        let annotation = Annotation(
            locator: selection.locator,
            text: selection.text,
            note: note,
            color: color,
            chapterTitle: chapterTitle
        )
        record.annotations.append(annotation)

        do {
            try store.updateAndFlush(bookID) { $0.annotations = record.annotations }
            self.record = record
            lastAppliedHighlightColor = color
            aiNoteTarget = .annotation(annotation.id)
            reader?.setAnnotations(record.annotations)
            completion(.success(annotation.id))
        } catch {
            completion(.failure(error))
        }
    }

    func drawingScene(for id: UUID) -> Data? {
        if let cached = drawingCache[id] { return cached }
        guard let bookID = book?.bookID else { return nil }
        let data = store.drawingStore.loadScene(bookID: bookID, annotationID: id)
        drawingCache[id] = data
        return data
    }

    func updateDrawing(
        scene: Data,
        elementCount: Int,
        for id: UUID,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard let bookID = book?.bookID else {
            completion?(.failure(DrawingPersistenceError.missingBook))
            return
        }
        let hasDrawing = elementCount > 0
        do {
            try store.drawingStore.replaceScene(hasDrawing ? scene : nil, bookID: bookID, annotationID: id)
            try store.updateAndFlush(bookID) { record in
                var annotations = record.annotations
                guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
                annotations[index].hasDrawing = hasDrawing
                if hasDrawing, annotations[index].color == .underline {
                    annotations[index].color = .yellow
                    lastAppliedHighlightColor = .yellow
                }
                annotations[index].modifiedAt = Date()
                record.annotations = annotations
            }
            drawingCache[id] = hasDrawing ? scene : nil
            record = store.record(for: bookID)
            if let annotations = record?.annotations { reader?.setAnnotations(annotations) }
            completion?(.success(()))
        } catch { completion?(.failure(error)) }
    }

    func changeColor(_ color: HighlightColor, for id: UUID) {
        guard let bookID = book?.bookID else { return }
        var appliedColor = color
        mutateAnnotations(bookID: bookID) { annotations in
            guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
            // Underline remains available for plain highlights, but a note or
            // drawing always owns a filled highlight.
            appliedColor = annotations[index].hasContent && color == .underline ? .yellow : color
            annotations[index].color = appliedColor
            annotations[index].modifiedAt = Date()
        }
        lastAppliedHighlightColor = appliedColor
    }

    func deleteAnnotation(_ id: UUID) {
        guard let bookID = book?.bookID else { return }
        if case .annotation(id) = aiNoteTarget {
            aiNoteTarget = nil
        }
        drawingCache[id] = nil
        store.drawingStore.deleteScene(bookID: bookID, annotationID: id)
        mutateAnnotations(bookID: bookID) { $0.removeAll { $0.id == id } }
    }

    func annotation(with id: UUID) -> Annotation? {
        record?.annotations.first { $0.id == id }
    }

    /// Persists locator repairs and orphan/resolved status from the reader runtime.
    func applyAnchorResolutions(_ resolutions: [AnchorResolution]) {
        guard let bookID = book?.bookID, var record, !resolutions.isEmpty else { return }

        var changed = false
        for resolution in resolutions {
            guard let index = record.annotations.firstIndex(where: { $0.id == resolution.id }) else {
                continue
            }
            if record.annotations[index].anchorStatus != resolution.status {
                record.annotations[index].anchorStatus = resolution.status
                changed = true
            }
            if let locator = resolution.locator, record.annotations[index].locator != locator {
                record.annotations[index].locator = locator
                changed = true
            }
        }

        guard changed else { return }
        // Avoid a re-resolve loop: repairs are already painted in the web view.
        self.record = record
        store.update(bookID) { $0.annotations = record.annotations }
    }

    /// Markdown export of every annotation that has a note body.
    func exportNotesMarkdown() -> String {
        let title = book?.title ?? record?.title ?? "Untitled"
        let author = book?.author ?? record?.author ?? "Unknown Author"
        return NoteMarkdown.exportDocument(
            bookTitle: title,
            author: author,
            annotations: record?.annotations ?? []
        )
    }

    private func mutateAnnotations(
        bookID: String,
        pushToReader: Bool = true,
        _ transform: (inout [Annotation]) -> Void
    ) {
        guard var record else { return }
        transform(&record.annotations)
        self.record = record
        store.update(bookID) { $0.annotations = record.annotations }
        if pushToReader {
            reader?.setAnnotations(record.annotations)
        }
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
        if let position = record?.position { return position }
        if book?.kind == .pdf { return .pdfPage(reader.spineIndex) }
        return Locator(spineIndex: reader.spineIndex, start: TextPosition(elementPath: [], offset: 0))
    }
}

private enum DrawingPersistenceError: LocalizedError {
    case missingBook

    var errorDescription: String? {
        "Could not save the drawing because no document is open."
    }
}

private enum NotePersistenceError: LocalizedError {
    case missingBook
    case missingAnnotation
    case emptyExcerpt

    var errorDescription: String? {
        switch self {
        case .missingBook:
            return "Could not save the note because no document is open."
        case .missingAnnotation:
            return "Could not save the note because the highlight no longer exists."
        case .emptyExcerpt:
            return "Select some text from the AI answer first."
        }
    }
}
