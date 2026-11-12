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
    private(set) var hasReadyReader = false
    private(set) var recents: [BookRecord] = []
    private(set) var reminderBooks: [BookRecord] = []
    var isShowingReminders = false
    var reminderNoteToOpen: UUID?
    @ObservationIgnored private var pendingReminderDestination: (bookID: String, reminder: ResearchReminder)?
    @ObservationIgnored private var pendingLibraryAnnotation: (bookID: String, annotationID: UUID)?
    var documentToRename: BookRecord?

    var errorMessage: String?
    var isShowingContents = false
    var aiNoteTarget: AINoteTarget?
    typealias Workspace = ReaderWorkspacePresentation.Workspace
    private let workspacePresentation = ReaderWorkspacePresentation()
    var isPreparingWorkspaceLayout: Bool { workspacePresentation.isPreparingLayout }
    var workspace: Workspace {
        get { workspacePresentation.visible }
        set {
            workspacePresentation.request(newValue,
                prepareLayout: { [weak self] finished in
                    guard let reader = self?.reader else { finished(); return }
                    reader.beginWorkspaceRestore(completion: finished)
                },
                releaseLayout: { [weak self] finished in
                    guard let reader = self?.reader else { finished(); return }
                    reader.endWorkspaceRestore(completion: finished)
                },
                flushNotes: { [weak self] finished in self?.flush(completion: finished) })
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
    let sync: LibrarySyncService
    let aiConfig: AIConfigStore
    let aiAuth: AIAuthController
    let aiCredits: AICreditsController
    let chat: ChatController
    let savedPrompts: SavedPromptStore
    let analytics = UsageAnalytics.shared
    let readingProgress: ReadingProgress
    let audioNotes = AudioNoteController()
    let audioTranscription = AudioTranscriptionController()
    private(set) var audioTranscriptionErrors: [AudioTranscriptionScope: [UUID: String]] = [:]
    @ObservationIgnored var suspendNarration: (() -> Void)?

    private var analyticsContentType: AnalyticsContentType? {
        guard let book else { return nil }
        return record?.sourceURL != nil ? .web : (book.kind == .pdf ? .pdf : .epub)
    }

    private func analyticsContentType(for record: BookRecord) -> AnalyticsContentType {
        record.sourceURL != nil ? .web : (record.documentKind == .pdf ? .pdf : .epub)
    }

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
    /// Editors checkpoint their text and canvas before navigation or sync.
    @ObservationIgnored private var noteFlushHandlers: [UUID: (@escaping (Result<Void, Error>) -> Void) -> Void] = [:]
    @ObservationIgnored private var noteEditingSessions: [UUID: UUID] = [:]
    @ObservationIgnored private var noteAnalyticsEdits: [UUID: AnalyticsEditToken] = [:]
    @ObservationIgnored private var sketchAnalyticsEdits: [UUID: [UUID: AnalyticsEditToken]] = [:]
    private struct PendingSketchAnalytics {
        let token: AnalyticsEditToken
        let originalSignature: Data?
        let wasNew: Bool
    }
    // A drawing file can be written before the library checkpoint fails. Keep
    // the original comparison until the complete save succeeds, so retrying the
    // same checkpoint does not lose or invent a meaningful editing event.
    @ObservationIgnored private var pendingSketchAnalytics: [String: PendingSketchAnalytics] = [:]
    @ObservationIgnored private var openingID: UUID?
    @ObservationIgnored private var sketchUndoArchive: [String: SketchUndoHistory] = [:]
    @ObservationIgnored private var audioUndoArchive: [String: AudioUndoHistory] = [:]

    init() {
        let root = AppDataDirectory.prepare()
        readingProgress = ReadingProgress(directory: root)
        let store = LibraryStore(fileURL: root.appendingPathComponent("library.json"))
        self.store = store
        let iCloudEnabled = (Bundle.main.object(forInfoDictionaryKey: "iCloudSyncEnabled") as? String) == "YES"
        self.sync = LibrarySyncService(store: store, iCloudEnabled: iCloudEnabled,
            googleClientID: Bundle.main.object(forInfoDictionaryKey: "GoogleDriveClientID") as? String,
            googleClientSecret: Bundle.main.object(forInfoDictionaryKey: "GoogleDriveClientSecret") as? String)
        settings = (try? store.migrateAppearanceSettings(defaultSettings: ReaderSettings()) {
            $0.applyAppearanceDefaults()
        }) ?? store.loadSettings(ReaderSettings.self) ?? ReaderSettings()
        recents = store.recentBooks(limit: .max)
        reminderBooks = store.allBooks()

        let aiConfig = AIConfigStore(directory: root)
        self.aiConfig = aiConfig
        let aiAuth = AIAuthController()
        self.aiAuth = aiAuth
        let aiCredits = AICreditsController(auth: aiAuth)
        self.aiCredits = aiCredits
        let chat = ChatController(configStore: aiConfig, auth: aiAuth)
        self.chat = chat
        self.savedPrompts = SavedPromptStore()
        chat.onRequestStarted = { [weak self] requestID in self?.analytics.record(.aiRequestStarted, content: self?.analyticsContentType, requestID: requestID) }
        chat.onRequestCompleted = { [weak self] requestID, timing in self?.analytics.record(.aiRequestCompleted, content: self?.analyticsContentType, requestID: requestID, timing: timing) }
        chat.onRequestCancelled = { [weak self] requestID, timing in self?.analytics.record(.aiRequestCancelled, content: self?.analyticsContentType, requestID: requestID, timing: timing) }
        chat.onRequestFailed = { [weak self] requestID, error, timing in
            let category: AnalyticsErrorCategory
            switch error {
            case AIChatError.authRequired: category = .authentication
            case AIChatError.insufficientCredits: category = .credits
            case is URLError: category = .network
            default: category = .service
            }
            self?.analytics.record(.aiRequestFailed, content: self?.analyticsContentType, error: category, requestID: requestID, timing: timing)
        }
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
                bookTitle: self?.record?.title ?? self?.book?.title ?? "",
                author: self?.book?.author ?? self?.record?.author ?? "",
                chapterTitle: self?.reader?.chapterTitle
            )
        }
        audioNotes.beforeAudioActivity = { [weak self] in self?.suspendNarration?() }
        audioNotes.onAnalyticsEvent = { [weak self] event in self?.analytics.record(event) }
        audioNotes.onAnalyticsActivityChanged = { [weak self] activity, active in
            self?.analytics.setFeatureActivity(activity, active: active)
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

    func openOriginalInBrowser(_ record: BookRecord) {
        guard let url = record.sourceURL else { return }
        NSWorkspace.shared.open(url)
    }

    func open(url: URL, sourceURL: URL? = nil, expectedIdentity: String? = nil, preferredLocalID: String? = nil) {
        if preferredLocalID != pendingReminderDestination?.bookID { pendingReminderDestination = nil }
        if preferredLocalID != pendingLibraryAnnotation?.bookID { pendingLibraryAnnotation = nil }
        closeBook { [self] in
            beginOpening(url: url, sourceURL: sourceURL, expectedIdentity: expectedIdentity, preferredLocalID: preferredLocalID)
        }
    }

    private func beginOpening(url: URL, sourceURL: URL?, expectedIdentity: String?, preferredLocalID: String?) {
        let operation = UUID(); openingID = operation
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let kind: DocumentKind = url.pathExtension.lowercased() == "pdf" ? .pdf : .epub
                let identity = try await Task.detached { try BlobManifest.bookIdentity(file: url, kind: kind) }.value
                guard openingID == operation else { return }
                if let expectedIdentity, identity != expectedIdentity {
                    pendingReminderDestination = nil
                    pendingLibraryAnnotation = nil
                    errorMessage = "This is a different edition or file. Locate the same book to attach its synced notes."
                    return
                }
                openPrepared(url: url, sourceURL: sourceURL, identity: identity, preferredLocalID: preferredLocalID)
            } catch {
                if openingID == operation {
                    pendingReminderDestination = nil
                    pendingLibraryAnnotation = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openPrepared(url: URL, sourceURL: URL?, identity: String, preferredLocalID: String?) {
        completeClosingBook()

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
            if existing == nil, sync.isLocalRecovery(localID) {
                record.title = "Recovered version: " + book.title
            }
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
            reminderBooks = store.allBooks()
            errorMessage = nil
            chat.load(threads: record.conversationThreads, activeID: record.activeChatID)
            if existing == nil { analytics.record(.bookImported, content: analyticsContentType) }
        } catch {
            if didScope { url.stopAccessingSecurityScopedResource() }
            pendingReminderDestination = nil
            errorMessage = error.localizedDescription
            pendingLibraryAnnotation = nil
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

        guard panel.runModal() == .OK, let url = panel.url else {
            pendingReminderDestination = nil
            pendingLibraryAnnotation = nil
            return
        }
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

    var canGoHome: Bool { book != nil }

    /// Leaves the current book and returns to the welcome screen.
    func goHome() {
        pendingReminderDestination = nil
        pendingLibraryAnnotation = nil
        reminderNoteToOpen = nil
        closeBook()
    }

    func closeBook(completion: (() -> Void)? = nil) {
        flush { [self] succeeded in
            guard succeeded else { return }
            completeClosingBook()
            completion?()
        }
    }

    private func completeClosingBook() {
        analytics.setReadingContent(nil)
        for token in noteAnalyticsEdits.values { analytics.endEditing(token: token) }
        for edits in sketchAnalyticsEdits.values {
            for token in edits.values { analytics.endEditing(token: token) }
        }
        noteAnalyticsEdits.removeAll()
        sketchAnalyticsEdits.removeAll()
        pendingSketchAnalytics.removeAll()
        analytics.endAllEditing()
        readingProgress.setReaderEligible(false)
        hasReadyReader = false
        noteFlushHandlers.removeAll()
        noteEditingSessions.removeAll()
        sketchUndoArchive.removeAll()
        for history in audioUndoArchive.values { history.discard() }
        audioUndoArchive.removeAll()
        audioNotes.stopPlayback()
        openingID = nil
        chat.stop()
        persistChat(chat.threads, activeID: chat.activeThreadID)
        sync.checkpoint()
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
        reminderBooks = store.allBooks()
    }

    func removeFromRecents(_ record: BookRecord) {
        store.hideFromRecents(record.id)
        recents = store.recentBooks(limit: .max)
    }

    func renameDocument(_ target: BookRecord, to title: String) throws {
        try store.renameBook(target.id, to: title)
        if record?.id == target.id { record = store.record(for: target.id) }
        recents = store.recentBooks(limit: .max)
        reminderBooks = store.allBooks()
    }

    func importedURL(for record: BookRecord) -> URL? {
        store.existingImportedURL(for: record)
    }

    func flush(completion: ((Bool) -> Void)? = nil) {
        readingProgress.checkpoint()
        flushNoteEditors { [self] succeeded in
            if succeeded { sync.checkpoint() }
            completion?(succeeded)
        }
    }

    /// Opening a note only needs to protect live edits, not checkpoint the
    /// entire library and sync journal before presenting its editor.
    func flushNoteEditors(completion: @escaping (Bool) -> Void) {
        let handlers = Array(noteFlushHandlers.values)
        var remaining = handlers.count
        var succeeded = true
        guard remaining > 0 else { completion(true); return }
        for flushEditor in handlers {
            flushEditor { result in
                if case .failure = result { succeeded = false }
                remaining -= 1
                if remaining == 0 {
                    completion(succeeded)
                }
            }
        }
    }

    func beginNoteEditing(_ id: UUID, session: UUID, flush: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void) {
        if noteEditingSessions[id] != session { endAnalyticsEditing(id) }
        noteEditingSessions[id] = session
        noteFlushHandlers[id] = flush
    }
    func isNoteEditingSession(_ id: UUID, session: UUID) -> Bool { noteEditingSessions[id] == session }

    func endNoteEditing(_ id: UUID, session: UUID) {
        guard noteEditingSessions[id] == session else { return }
        endAnalyticsEditing(id)
        noteEditingSessions[id] = nil
        if let bookID = book?.bookID {
            let key = "\(bookID):\(id)"
            sketchUndoArchive[key] = nil
            audioUndoArchive.removeValue(forKey: key)?.discard()
        }
        noteFlushHandlers[id] = nil
        sync.resumeDeferredChanges()
    }

    /// The editor calls this after its final canvas save when leaving a drawing.
    func endSketchEditing(_ id: UUID, session: UUID) {
        guard noteEditingSessions[id] == session else { return }
        endSketchAnalyticsEditing(id)
    }

    func endTextNoteEditing(_ id: UUID, session: UUID) {
        guard noteEditingSessions[id] == session else { return }
        if let token = noteAnalyticsEdits.removeValue(forKey: id) { analytics.endEditing(token: token) }
    }

    private func endAnalyticsEditing(_ id: UUID) {
        if let token = noteAnalyticsEdits.removeValue(forKey: id) { analytics.endEditing(token: token) }
        endSketchAnalyticsEditing(id)
    }

    private func endSketchAnalyticsEditing(_ id: UUID) {
        guard let edits = sketchAnalyticsEdits.removeValue(forKey: id) else { return }
        for token in edits.values { analytics.endEditing(token: token) }
    }

    private func beginNoteAnalyticsEdit(bookID: String, annotationID: UUID, isNew: Bool) -> AnalyticsEditToken {
        let token = analytics.beginEditing(kind: .note, itemKey: "\(bookID):\(annotationID)",
                                           isNew: isNew, content: analyticsContentType)
        noteAnalyticsEdits[annotationID] = token
        return token
    }

    private func beginSketchAnalyticsEdit(bookID: String, annotationID: UUID, sketchID: UUID, isNew: Bool) -> AnalyticsEditToken {
        let token = analytics.beginEditing(kind: .sketch, itemKey: "\(bookID):\(annotationID):\(sketchID)",
                                           isNew: isNew, content: analyticsContentType)
        sketchAnalyticsEdits[annotationID, default: [:]][sketchID] = token
        return token
    }

    func refreshAfterSync() {
        recents = store.recentBooks(limit: .max)
        reminderBooks = store.allBooks()
        guard let currentID = record?.id else { return }
        guard let updated = store.record(for: currentID) else {
            closeBook()
            return
        }
        record = updated
        reader?.setAnnotations(updated.annotations)
        reader?.setReminders(updated.reminders)
        reader?.readingMarker = updated.readingMarker?.locator
        if !chat.isStreaming { chat.mergeStoredThreads(updated.conversationThreads) }
    }

    func downloadForOffline(_ record: BookRecord, openAfter: Bool = false) {
        guard sync.status.downloads[record.id] == nil else { return }
        let wasReminderNavigation = pendingReminderDestination?.bookID == record.id
        let wasAnnotationNavigation = pendingLibraryAnnotation?.bookID == record.id
        Task {
            do {
                let url = try await sync.download(record)
                if pendingReminderDestination?.bookID == record.id
                    || pendingLibraryAnnotation?.bookID == record.id
                    || (openAfter && !wasReminderNavigation && !wasAnnotationNavigation) {
                    open(url: url, expectedIdentity: record.cloudIdentity, preferredLocalID: record.id)
                }
            } catch {
                if wasReminderNavigation, pendingReminderDestination?.bookID != record.id { return }
                if wasAnnotationNavigation, pendingLibraryAnnotation?.bookID != record.id { return }
                if pendingReminderDestination?.bookID == record.id { pendingReminderDestination = nil }
                if pendingLibraryAnnotation?.bookID == record.id { pendingLibraryAnnotation = nil }
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeDownload(_ record: BookRecord) {
        let remove = { [self] in
            do { try sync.removeDownload(record); refreshAfterSync() }
            catch { errorMessage = error.localizedDescription }
        }
        if self.record?.id == record.id { closeBook(completion: remove) }
        else { remove() }
    }

    func deleteEverywhere(_ record: BookRecord) {
        let remove = { [self] in
            do { try sync.deleteEverywhere(record) }
            catch { errorMessage = error.localizedDescription }
        }
        if self.record?.id == record.id { closeBook(completion: remove) }
        else { remove() }
    }

    func showHiddenBooks() {
        for book in store.allBooks() where book.isHiddenFromRecents {
            store.update(book.id) { $0.isHiddenFromRecents = false }
        }
        recents = store.recentBooks(limit: .max)
    }

    // MARK: - Reader wiring

    private func wire(_ controller: ReaderController, bookID: String) {
        var lastPage: (spine: Int, page: Int, count: Int)?
        controller.onPositionChanged = { [weak self, weak controller] locator in
            guard let self, let controller, reader === controller else { return }
            let currentPage = (spine: controller.spineIndex, page: controller.page, count: controller.pageCount)
            if !controller.isLoading {
                hasReadyReader = true
                if let lastPage,
                   (lastPage.spine != currentPage.spine || lastPage.count == currentPage.count),
                   (lastPage.spine != currentPage.spine || lastPage.page != currentPage.page) {
                    analytics.record(.pageTurned, content: analyticsContentType)
                }
                lastPage = currentPage
            }
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
        controller.onReadingMarkerPlaced = { [weak self, weak controller] locator in
            guard let self, self.record?.id == bookID else { return }
            let marker = Bookmark(
                id: Bookmark.readingMarkerID,
                locator: locator,
                chapterTitle: controller?.chapterTitle,
                excerpt: locator.text
            )
            self.saveReadingMarker(marker)
        }
    }

    /// Called once the reader view is on screen and able to load content.
    func startReading() {
        guard let reader, let record else { return }
        reader.readingMarker = record.readingMarker?.locator
        reader.setReminders(record.reminders)
        if let destination = pendingReminderDestination, destination.bookID == record.id {
            pendingReminderDestination = nil
            let source = record.annotations.first { $0.id == destination.reminder.annotationID }
            reader.start(at: source?.locator ?? destination.reminder.locator, annotations: record.annotations)
            if let id = destination.reminder.annotationID, annotation(with: id) != nil {
                reminderNoteToOpen = id
            }
            analytics.record(.reminderOpened, content: analyticsContentType(for: record))
        } else if let destination = pendingLibraryAnnotation, destination.bookID == record.id {
            pendingLibraryAnnotation = nil
            let annotation = record.annotations.first { $0.id == destination.annotationID }
            reader.start(at: annotation?.locator ?? record.position, annotations: record.annotations)
            reminderNoteToOpen = annotation?.id
        } else {
            reader.start(at: record.position, annotations: record.annotations)
        }
    }

    /// The destination survives library dismissal, file location, and cloud download.
    func openLibraryAnnotation(_ annotation: Annotation, in target: BookRecord) {
        pendingLibraryAnnotation = (target.id, annotation.id)
        reopen(target)
    }

    // MARK: - Research reminders

    var currentReminderLocator: Locator? {
        guard let reader, !reader.isLoading, reader.errorMessage == nil else { return nil }
        return currentPosition(reader)
    }

    func reminder(with id: UUID, bookID: String? = nil) -> ResearchReminder? {
        guard let bookID = bookID ?? book?.bookID else { return nil }
        return store.record(for: bookID)?.reminders.first { $0.id == id }
    }

    @discardableResult
    func createReminder(title: String, source: ResearchReminder.Source, locator: Locator,
                        quotedText: String = "", chapterTitle: String? = nil,
                        annotationID: UUID? = nil, id: UUID = UUID(), noteUpdate: String? = nil) throws -> ResearchReminder {
        guard let bookID = book?.bookID, let stored = store.record(for: bookID) else {
            throw LibraryStoreError.missingBook
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ReminderPersistenceError.emptyTitle }
        if noteUpdate != nil, !stored.annotations.contains(where: { $0.id == annotationID }) {
            throw NotePersistenceError.missingAnnotation
        }
        let reminder = ResearchReminder(id: id, title: title, source: source, locator: locator,
                                        quotedText: quotedText, chapterTitle: chapterTitle, annotationID: annotationID)
        try store.updateAndFlush(bookID) { stored in
            stored.reminders.removeAll { $0.id == id }
            stored.reminders.append(reminder)
            if let noteUpdate, let index = stored.annotations.firstIndex(where: { $0.id == annotationID }) {
                stored.annotations[index].note = noteUpdate
                stored.annotations[index].modifiedAt = Date()
            }
        }
        refreshReminders(bookID: bookID)
        if noteUpdate != nil, let annotations = record?.annotations { reader?.setAnnotations(annotations) }
        if !stored.reminders.contains(where: { $0.id == id }) {
            analytics.record(.reminderCreated, content: analyticsContentType(for: stored))
        }
        return reminder
    }

    func updateReminder(_ reminder: ResearchReminder, bookID: String) throws {
        guard let stored = store.record(for: bookID),
              let previous = stored.reminders.first(where: { $0.id == reminder.id }) else {
            throw ReminderPersistenceError.missingReminder
        }
        let title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ReminderPersistenceError.emptyTitle }
        try store.updateAndFlush(bookID) { stored in
            guard let index = stored.reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
            stored.reminders[index].title = title
            stored.reminders[index].completedAt = reminder.completedAt
            stored.reminders[index].modifiedAt = Date()
        }
        refreshReminders(bookID: bookID)
        let content = analyticsContentType(for: stored)
        if previous.title != title { analytics.record(.reminderUpdated, content: content) }
        if previous.isCompleted != reminder.isCompleted {
            analytics.record(reminder.isCompleted ? .reminderCompleted : .reminderReopened, content: content)
        }
    }

    func deleteReminder(_ id: UUID, bookID: String) throws {
        let previous = store.record(for: bookID)
        try store.updateAndFlush(bookID) { $0.reminders.removeAll { $0.id == id } }
        refreshReminders(bookID: bookID)
        if let previous, previous.reminders.contains(where: { $0.id == id }) {
            analytics.record(.reminderDeleted, content: analyticsContentType(for: previous))
        }
    }

    func restoreReminder(_ reminder: ResearchReminder, bookID: String) throws {
        let previous = store.record(for: bookID)
        var restored = reminder
        restored.modifiedAt = Date()
        try store.updateAndFlush(bookID) { stored in
            stored.reminders.removeAll { $0.id == restored.id }
            stored.reminders.append(restored)
        }
        refreshReminders(bookID: bookID)
        if let previous, !previous.reminders.contains(where: { $0.id == reminder.id }) {
            analytics.record(.reminderRestored, content: analyticsContentType(for: previous))
        }
    }

    private func refreshReminders(bookID: String) {
        reminderBooks = store.allBooks()
        if record?.id == bookID {
            record = store.record(for: bookID)
            reader?.setReminders(record?.reminders ?? [])
        }
    }

    func showReminders() {
        flush { [self] succeeded in
            guard succeeded else { return }
            reminderBooks = store.allBooks()
            if book != nil {
                pinReaderForViewportChange()
                workspace = workspace == .reminders ? .closed : .reminders
            } else { isShowingReminders = true }
        }
    }

    func openReminder(_ reminder: ResearchReminder, bookID: String) {
        flush { [self] succeeded in
            guard succeeded, let target = store.record(for: bookID) else { return }
            isShowingReminders = false
            if book?.bookID == bookID, let reader {
                reader.pinRestore(to: nil)
                let source = target.annotations.first { $0.id == reminder.annotationID }
                reader.go(to: source?.locator ?? reminder.locator)
                if let id = reminder.annotationID, annotation(with: id) != nil { reminderNoteToOpen = id }
                analytics.record(.reminderOpened, content: analyticsContentType(for: target))
            } else {
                pendingReminderDestination = (bookID, reminder)
                reopen(target)
            }
        }
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
    func addHighlight(color: HighlightColor, from capturedSelection: ReaderSelection? = nil) -> Annotation? {
        guard
            let reader,
            let selection = capturedSelection ?? reader.selection,
            let bookID = book?.bookID
        else { return nil }

        let annotation = Annotation(
            locator: selection.locator,
            text: selection.text,
            color: color,
            chapterTitle: reader.chapterTitle
        )
        mutateAnnotations(bookID: bookID) { $0.append(annotation) }
        analytics.record(.highlightCreated, content: analyticsContentType)
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
        reconcileSketches: Bool = false,
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

        let previousText = AnalyticsContentRules.textNote(record.annotations[index].note ?? "")
        let analyticsEdit = previousText != AnalyticsContentRules.textNote(note)
            ? beginNoteAnalyticsEdit(bookID: bookID, annotationID: id, isNew: previousText.isEmpty)
            : nil
        record.annotations[index].note = note.isEmpty ? nil : note
        if record.annotations[index].hasNote, record.annotations[index].color == .underline {
            record.annotations[index].color = .yellow
            lastAppliedHighlightColor = .yellow
        }
        record.annotations[index].modifiedAt = Date()
        var importedAudioIDs: [UUID] = []
        var didCheckpoint = false
        do {
            var removed: [NoteSketch] = []
            var removedAudio: [NoteAudio] = []
            if reconcileSketches {
                let key = "\(bookID):\(id)"
                let history = sketchUndoArchive[key] ?? SketchUndoHistory()
                sketchUndoArchive[key] = history
                let before = record.annotations[index]
                let updated = try history.reconciling(before, note: note, drawings: store.drawingStore, bookID: bookID)
                removed = before.sketches.filter { sketch in !updated.sketches.contains { $0.id == sketch.id } }
                let audioHistory = audioUndoArchive[key] ?? AudioUndoHistory()
                audioUndoArchive[key] = audioHistory
                let clipboard = try AudioNoteClipboard.importing(into: updated, note: note, audio: store.audioStore, bookID: bookID)
                importedAudioIDs = clipboard.audioRecordings.filter { audio in !before.audioRecordings.contains { $0.id == audio.id } }.map(\.id)
                let imported = try store.importReferencedAudio(in: clipboard, note: note, bookID: bookID)
                importedAudioIDs = imported.audioRecordings.filter { audio in !before.audioRecordings.contains { $0.id == audio.id } }.map(\.id)
                let withAudio = try audioHistory.reconciling(imported, note: note, audio: store.audioStore, bookID: bookID)
                removedAudio = before.audioRecordings.filter { audio in !withAudio.audioRecordings.contains { $0.id == audio.id } }
                record.annotations[index] = withAudio
            }
            try store.updateAndFlush(bookID) { $0.annotations = record.annotations }
            didCheckpoint = true
            self.record = record
            // The text is durable now. A later attachment-cleanup failure must
            // not lose this event: retrying already-saved text is unchanged.
            if let analyticsEdit { analytics.noteSuccessfulEdit(token: analyticsEdit, meaningful: true) }
            for sketch in removed {
                try store.drawingStore.deleteSketch(bookID: bookID, annotationID: id, sketchID: sketch.id)
                analytics.record(.sketchDeleted, content: analyticsContentType)
            }
            for audio in removedAudio {
                if audioNotes.playbackID == audio.id { audioNotes.stopPlayback() }
                let scope = AudioTranscriptionScope(bookID: bookID, annotationID: id)
                audioTranscription.cancel(id: audio.id, scope: scope)
                audioTranscriptionErrors[scope]?[audio.id] = nil
                try? store.audioStore.deleteRecording(bookID: bookID, annotationID: id, audioID: audio.id)
            }
            completion?(.success(()))
            // Refresh the note-dot on painted highlights without a full re-resolve.
            reader?.setAnnotations(record.annotations)
        } catch {
            if !didCheckpoint {
                for audioID in importedAudioIDs { try? store.audioStore.deleteRecording(bookID: bookID, annotationID: id, audioID: audioID) }
            }
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
        let analyticsEdit = beginNoteAnalyticsEdit(bookID: bookID, annotationID: annotation.id, isNew: true)

        do {
            try store.updateAndFlush(bookID) { $0.annotations = record.annotations }
            self.record = record
            lastAppliedHighlightColor = color
            aiNoteTarget = .annotation(annotation.id)
            analytics.noteSuccessfulEdit(token: analyticsEdit, meaningful: true)
            reader?.setAnnotations(record.annotations)
            completion(.success(annotation.id))
        } catch {
            completion(.failure(error))
        }
    }

    func migrateDrawing(for id: UUID) throws {
        guard let bookID = book?.bookID, let annotation = annotation(with: id), annotation.hasDrawing, annotation.sketches.isEmpty else { return }
        let updated = try store.drawingStore.migratingLegacyDrawing(annotation, bookID: bookID)
        try store.updateAndFlush(bookID) { record in
            guard let index = record.annotations.firstIndex(where: { $0.id == id }) else { return }
            record.annotations[index] = updated
        }
        record = store.record(for: bookID)
        // The legacy scene remains available for rollback and older local backups.
    }

    func exportNotes(_ format: NoteExportFormat, annotations requested: [Annotation]? = nil) {
        guard let bookID = book?.bookID else { return }
        let ids = (requested ?? record?.annotations ?? []).map(\.id)
        do { for id in ids { try migrateDrawing(for: id) } }
        catch { showSketchExportError(error); return }
        let snapshots = ids.compactMap { annotation(with: $0) }
        let reminderSnapshot = record?.reminders ?? []
        let title = record?.title ?? "Untitled"
        let author = record?.author ?? "Unknown Author"
        let references = snapshots.flatMap { note in SketchReference.references(in: note.note ?? "").map { (note.id, $0) } }
        var audioFiles: [UUID: URL] = [:]
        for note in snapshots {
            for reference in AudioReference.references(in: note.note ?? "") {
                audioFiles[reference.id] = store.audioStore.recordingURL(bookID: bookID, annotationID: note.id, audioID: reference.id)
            }
        }
        var images: [UUID: Data] = [:]
        func resolve(_ index: Int) {
            guard index < references.count else {
                NotesExporter.presentSavePanel(format: format, bookTitle: title, author: author, annotations: snapshots, sketchImages: images, audioFiles: audioFiles, reminders: reminderSnapshot)
                return
            }
            let (annotationID, reference) = references[index]
            if images[reference.id] != nil { resolve(index + 1); return }
            let sceneURL = store.drawingStore.sceneURL(bookID: bookID, annotationID: annotationID, sketchID: reference.id)
            let previewURL = store.drawingStore.previewURL(bookID: bookID, annotationID: annotationID, sketchID: reference.id)
            let sceneDate = (try? sceneURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            let previewDate = (try? previewURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if previewDate >= sceneDate, let image = store.drawingStore.loadPreview(bookID: bookID, annotationID: annotationID, sketchID: reference.id), NSImage(data: image) != nil {
                images[reference.id] = image; resolve(index + 1); return
            }
            guard let scene = store.drawingStore.loadScene(bookID: bookID, annotationID: annotationID, sketchID: reference.id) else {
                showSketchExportError(NSError(domain: "KodiExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "The drawing for \(reference.title) is missing. Try Sync Now before exporting."]))
                return
            }
            ExcalidrawController.renderPreview(scene: scene) { [self] result in
                switch result {
                case .success(let image):
                    do {
                        try store.drawingStore.replaceSketch(scene: scene, preview: image, bookID: bookID, annotationID: annotationID, sketchID: reference.id)
                        images[reference.id] = image
                        resolve(index + 1)
                    } catch { showSketchExportError(error) }
                case .failure(let error): showSketchExportError(error)
                }
            }
        }
        resolve(0)
    }

    private func showSketchExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t export notes"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func sketchScene(annotationID: UUID, sketchID: UUID) -> Data? {
        guard let bookID = book?.bookID else { return nil }
        return store.drawingStore.loadScene(bookID: bookID, annotationID: annotationID, sketchID: sketchID)
    }

    func sketchPreview(annotationID: UUID, sketchID: UUID) -> Data? {
        guard let bookID = book?.bookID else { return nil }
        return store.drawingStore.loadPreview(bookID: bookID, annotationID: annotationID, sketchID: sketchID)
    }

    func recordSketchOpened(annotationID: UUID, sketchID: UUID) {
        guard annotation(with: annotationID)?.sketches.contains(where: { $0.id == sketchID }) == true else { return }
        analytics.record(.sketchOpened, content: analyticsContentType)
    }

    func saveSketch(_ sketch: NoteSketch, checkpoint: SketchCheckpoint, note: String, annotationID: UUID) throws {
        guard let bookID = book?.bookID else { throw DrawingPersistenceError.missingBook }
        guard let previous = annotation(with: annotationID) else { throw NotePersistenceError.missingAnnotation }
        let key = "\(bookID):\(annotationID):\(sketch.id)"
        let savedSignature = AnalyticsContentRules.drawingSignature(store.drawingStore.loadScene(bookID: bookID, annotationID: annotationID, sketchID: sketch.id))
        let signature = AnalyticsContentRules.drawingSignature(checkpoint.scene)
        let pending = pendingSketchAnalytics[key]
        let isNewSketch = pending?.wasNew ?? !previous.sketches.contains { $0.id == sketch.id }
        let originalSignature: Data?
        if let pending { originalSignature = pending.originalSignature }
        else { originalSignature = savedSignature }
        let meaningfulDrawing = isNewSketch ? checkpoint.elementCount > 0 : signature != nil && signature != originalSignature
        let sketchEdit = meaningfulDrawing
            ? pending?.token ?? beginSketchAnalyticsEdit(bookID: bookID, annotationID: annotationID, sketchID: sketch.id, isNew: isNewSketch)
            : nil
        if let sketchEdit, pending == nil {
            pendingSketchAnalytics[key] = PendingSketchAnalytics(token: sketchEdit, originalSignature: savedSignature, wasNew: isNewSketch)
        }
        let previousText = AnalyticsContentRules.textNote(previous.note ?? "")
        let noteEdit = previousText != AnalyticsContentRules.textNote(note)
            ? beginNoteAnalyticsEdit(bookID: bookID, annotationID: annotationID, isNew: previousText.isEmpty)
            : nil
        try store.drawingStore.replaceSketch(scene: checkpoint.scene, preview: checkpoint.preview, bookID: bookID, annotationID: annotationID, sketchID: sketch.id)
        try store.updateAndFlush(bookID) { record in
            guard let index = record.annotations.firstIndex(where: { $0.id == annotationID }) else { return }
            var updated = sketch
            updated.modifiedAt = Date()
            record.annotations[index].sketches.removeAll { $0.id == sketch.id }
            record.annotations[index].sketches.append(updated)
            record.annotations[index].sketches.sort { $0.createdAt < $1.createdAt }
            record.annotations[index].note = note.isEmpty ? nil : note
            record.annotations[index].hasDrawing = true
            record.annotations[index].modifiedAt = Date()
            if record.annotations[index].color == .underline { record.annotations[index].color = .yellow }
        }
        record = store.record(for: bookID)
        if let annotations = record?.annotations { reader?.setAnnotations(annotations) }
        if let sketchEdit { analytics.noteSuccessfulEdit(token: sketchEdit, meaningful: true) }
        pendingSketchAnalytics.removeValue(forKey: key)
        if let noteEdit { analytics.noteSuccessfulEdit(token: noteEdit, meaningful: true) }
    }

    func renameSketch(_ sketchID: UUID, title: String, note: String, annotationID: UUID) throws {
        guard let bookID = book?.bookID else { throw DrawingPersistenceError.missingBook }
        try store.updateAndFlush(bookID) { record in
            guard let index = record.annotations.firstIndex(where: { $0.id == annotationID }),
                  let sketchIndex = record.annotations[index].sketches.firstIndex(where: { $0.id == sketchID }) else { return }
            record.annotations[index].sketches[sketchIndex].title = title
            record.annotations[index].sketches[sketchIndex].modifiedAt = Date()
            record.annotations[index].note = note
            record.annotations[index].modifiedAt = Date()
        }
        record = store.record(for: bookID)
    }

    func audioURL(annotationID: UUID, audioID: UUID) -> URL? {
        guard let bookID = book?.bookID else { return nil }
        let url = store.audioStore.recordingURL(bookID: bookID, annotationID: annotationID, audioID: audioID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Finalized bytes become durable before a note can publish their reference.
    func saveAudio(_ audio: NoteAudio, from draft: URL, note: String, annotationID: UUID) throws {
        guard let bookID = book?.bookID else { throw NotePersistenceError.missingBook }
        guard let previous = annotation(with: annotationID) else { throw NotePersistenceError.missingAnnotation }
        let isNew = !previous.audioRecordings.contains { $0.id == audio.id }
        guard isNew else {
            throw NSError(domain: "KodiAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "This recording has already been saved."])
        }
        try store.audioStore.saveRecording(from: draft, bookID: bookID, annotationID: annotationID, audioID: audio.id)
        do {
            try store.updateAndFlush(bookID) { record in
                guard let index = record.annotations.firstIndex(where: { $0.id == annotationID }) else { return }
                record.annotations[index].audioRecordings.removeAll { $0.id == audio.id }
                record.annotations[index].audioRecordings.append(audio)
                record.annotations[index].audioRecordings.sort { $0.createdAt < $1.createdAt }
                record.annotations[index].note = note
                record.annotations[index].modifiedAt = Date()
                if record.annotations[index].color == .underline { record.annotations[index].color = .yellow }
            }
        } catch {
            if isNew { try? store.audioStore.deleteRecording(bookID: bookID, annotationID: annotationID, audioID: audio.id) }
            throw error
        }
        record = store.record(for: bookID)
        if let annotations = record?.annotations { reader?.setAnnotations(annotations) }
    }

    func renameAudio(_ audioID: UUID, title: String, note: String, annotationID: UUID) throws {
        guard let bookID = book?.bookID else { throw NotePersistenceError.missingBook }
        guard annotation(with: annotationID)?.audioRecordings.contains(where: { $0.id == audioID }) == true else {
            throw NotePersistenceError.missingAnnotation
        }
        try store.updateAndFlush(bookID) { record in
            guard let index = record.annotations.firstIndex(where: { $0.id == annotationID }),
                  let audioIndex = record.annotations[index].audioRecordings.firstIndex(where: { $0.id == audioID }) else { return }
            record.annotations[index].audioRecordings[audioIndex].title = title
            record.annotations[index].audioRecordings[audioIndex].modifiedAt = Date()
            record.annotations[index].note = note
            record.annotations[index].modifiedAt = Date()
        }
        record = store.record(for: bookID)
    }

    func transcribeAudio(_ audioID: UUID, annotationID: UUID, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !audioTranscription.isBusy, let bookID = book?.bookID,
              let url = audioURL(annotationID: annotationID, audioID: audioID) else {
            completion(false)
            return
        }
        let scope = AudioTranscriptionScope(bookID: bookID, annotationID: annotationID)
        audioTranscriptionErrors[scope]?[audioID] = nil
        Task { @MainActor in
            // A note may be deleted or another job may start before this
            // queued task runs. Neither should start work or publish an error.
            guard !audioTranscription.isBusy,
                  store.record(for: bookID)?.annotations.first(where: { $0.id == annotationID })?
                    .audioRecordings.contains(where: { $0.id == audioID }) == true else {
                completion(false); return
            }
            do {
                let transcript = try await audioTranscription.transcribe(id: audioID, url: url, scope: scope)
                guard let annotation = store.record(for: bookID)?.annotations.first(where: { $0.id == annotationID }),
                      annotation.audioRecordings.contains(where: { $0.id == audioID }) else {
                    completion(false); return
                }
                try store.updateAndFlush(bookID) { record in
                    guard let noteIndex = record.annotations.firstIndex(where: { $0.id == annotationID }),
                          let audioIndex = record.annotations[noteIndex].audioRecordings.firstIndex(where: { $0.id == audioID }) else { return }
                    record.annotations[noteIndex].audioRecordings[audioIndex].transcript = transcript
                    record.annotations[noteIndex].audioRecordings[audioIndex].modifiedAt = Date()
                    record.annotations[noteIndex].modifiedAt = Date()
                }
                if book?.bookID == bookID { record = store.record(for: bookID) }
                audioTranscriptionErrors[scope]?[audioID] = nil
                sync.checkpoint()
                completion(true)
            } catch is CancellationError {
                completion(false)
            } catch {
                // Keep the recording and any previous transcript intact.
                audioTranscriptionErrors[scope, default: [:]][audioID] = error.localizedDescription
                completion(false)
            }
        }
    }

    func exportAudio(_ audioID: UUID, annotationID: UUID) {
        guard let audio = annotation(with: annotationID)?.audioRecordings.first(where: { $0.id == audioID }),
              let source = audioURL(annotationID: annotationID, audioID: audioID) else {
            errorMessage = "This recording is unavailable. Try Sync Now before exporting."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4a") ?? .audio]
        panel.nameFieldStringValue = audio.title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-") + ".m4a"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".kodi-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: target) }
        } catch { errorMessage = error.localizedDescription }
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
        let deletedSketches = annotation(with: id)?.sketches ?? []
        let deletedAudio = annotation(with: id)?.audioRecordings ?? []
        do {
            try store.updateAndFlush(bookID) { $0.annotations.removeAll { $0.id == id } }
        } catch { errorMessage = error.localizedDescription; return }
        if case .annotation(id) = aiNoteTarget {
            aiNoteTarget = nil
        }
        if audioNotes.recordingAnnotationID == id { audioNotes.discardRecording() }
        let transcriptionScope = AudioTranscriptionScope(bookID: bookID, annotationID: id)
        for audio in deletedAudio { audioTranscription.cancel(id: audio.id, scope: transcriptionScope) }
        audioTranscriptionErrors[transcriptionScope] = nil
        audioNotes.stopPlayback()
        audioUndoArchive.removeValue(forKey: "\(bookID):\(id)")?.discard()
        store.audioStore.deleteRecordings(bookID: bookID, annotationID: id)
        store.drawingStore.deleteScene(bookID: bookID, annotationID: id)
        for _ in deletedSketches { analytics.record(.sketchDeleted, content: analyticsContentType) }
        record = store.record(for: bookID)
        if let annotations = record?.annotations { reader?.setAnnotations(annotations) }
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
            annotations: record?.annotations ?? [],
            reminders: record?.reminders ?? []
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

    // MARK: - Reading marker

    func toggleReadingMarkerPlacement() {
        reader?.toggleReadingMarkerPlacement()
    }

    func goToReadingMarker() {
        guard reader?.isLoading == false, let marker = record?.readingMarker else { return }
        reader?.cancelReadingMarkerPlacement()
        reader?.clearSelection()
        reader?.go(to: marker.locator)
    }

    func removeReadingMarker() {
        reader?.cancelReadingMarkerPlacement()
        saveReadingMarker(nil)
    }

    private func saveReadingMarker(_ marker: Bookmark?) {
        guard let bookID = record?.id else { return }
        let previous = record?.readingMarker
        do {
            try store.updateAndFlush(bookID) { $0.readingMarker = marker }
            record?.readingMarker = marker
            reader?.readingMarker = marker?.locator
        } catch {
            store.update(bookID) { $0.readingMarker = previous }
            reader?.readingMarker = record?.readingMarker?.locator
            errorMessage = "Could not save the reading marker: \(error.localizedDescription)"
        }
    }

    // MARK: - Bookmarks

    var isCurrentPageBookmarked: Bool {
        guard let reader, let record else { return false }
        return record.pageBookmarks.contains {
            $0.locator.spineIndex == reader.spineIndex
                && $0.locator.start == currentPosition(reader)?.start
        }
    }

    func toggleBookmark() {
        guard let reader, var record, let locator = currentPosition(reader) else { return }

        if let index = record.bookmarks.firstIndex(where: {
            !$0.isReadingMarker && $0.locator.spineIndex == locator.spineIndex && $0.locator.start == locator.start
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

private enum ReminderPersistenceError: LocalizedError {
    case emptyTitle, missingReminder
    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "Enter a topic to research."
        case .missingReminder: return "This reminder has been deleted."
        }
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
