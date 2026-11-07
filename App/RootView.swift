import AppKit
import EpubKit
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// Personal reading goals stay scoped to the main key window. Product
/// engagement also covers explicitly marked reader-owned editor sheets/tools.
private struct AnalyticsReadingWindowObserver: NSViewRepresentable {
    var onReadingChange: (Bool) -> Void
    var onEngagementChange: (Bool) -> Void
    var onReadingInteraction: () -> Void
    var onEngagementInteraction: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView(onReadingChange: onReadingChange, onEngagementChange: onEngagementChange,
                    onReadingInteraction: onReadingInteraction, onEngagementInteraction: onEngagementInteraction)
    }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.onReadingChange = onReadingChange
        view.onEngagementChange = onEngagementChange
        view.onReadingInteraction = onReadingInteraction
        view.onEngagementInteraction = onEngagementInteraction
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stopObserving() }

    final class MonitorView: NSView {
        var onReadingChange: (Bool) -> Void
        var onEngagementChange: (Bool) -> Void
        var onReadingInteraction: () -> Void
        var onEngagementInteraction: () -> Void
        private var tokens: [NSObjectProtocol] = []
        private var inputMonitor: Any?
        private weak var lastEditorWindow: NSWindow?
        private var publishScheduled = false

        init(onReadingChange: @escaping (Bool) -> Void, onEngagementChange: @escaping (Bool) -> Void,
             onReadingInteraction: @escaping () -> Void, onEngagementInteraction: @escaping () -> Void) {
            self.onReadingChange = onReadingChange
            self.onEngagementChange = onEngagementChange
            self.onReadingInteraction = onReadingInteraction
            self.onEngagementInteraction = onEngagementInteraction
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willBeginSheetNotification,
                NSWindow.didEndSheetNotification, NSApplication.didBecomeActiveNotification,
                NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
                NSApplication.didUnhideNotification, AnalyticsReaderEditorMarker.windowsChanged]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        if name == NSWindow.didBecomeKeyNotification, let key = note.object as? NSWindow {
                            self?.rememberEditorContext(for: key)
                        }
                        self?.schedulePublish()
                    }
                }
            }
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                if event.window === self.window, self.window?.isKeyWindow == true {
                    self.onReadingInteraction()
                }
                // Only timing is observed, and only in this reader's context.
                // Settings and unrelated app windows cannot reset its idle clock.
                if let eventWindow = event.window, eventWindow === NSApp.keyWindow,
                   self.engagementIsVisible(), self.isOwnedInteractionWindow(eventWindow) {
                    self.onEngagementInteraction()
                }
                return event
            }
            publish()
        }

        func stopObserving() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
            lastEditorWindow = nil
            onReadingChange(false)
            onEngagementChange(false)
        }

        private func schedulePublish() {
            guard !publishScheduled else { return }
            publishScheduled = true
            // A note sheet or toolbar can replace the key window in the same
            // run-loop turn. Avoid a false inactive gap ending its edit session.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publishScheduled = false
                self.publish()
            }
        }

        private func isDescendant(_ candidate: NSWindow, of ancestor: NSWindow) -> Bool {
            var current: NSWindow? = candidate
            var seen = Set<ObjectIdentifier>()
            while let next = current, seen.insert(ObjectIdentifier(next)).inserted {
                if next === ancestor { return true }
                current = next.sheetParent ?? next.parent
            }
            return false
        }

        private func keyContext(for key: NSWindow?) -> AnalyticsReaderWindowPolicy.KeyContext {
            guard let root = window, let key else { return .none }
            // A marked note sheet may own a second, unrelated modal dialog.
            // Only the deepest sheet's explicit editor marker authorizes it.
            var sheet = root.attachedSheet
            while let next = sheet?.attachedSheet { sheet = next }
            if let sheet, !AnalyticsReaderEditorMarker.isPresent(in: sheet) { return .unrelated }
            if key === root { return .reader }
            if isDescendant(key, of: root), AnalyticsReaderEditorMarker.isPresent(in: key) { return .editor }
            // Reader/editor popovers have an explicit parent relationship but
            // are not modal sheets. They remain within the same workspace.
            if key.sheetParent == nil, isDescendant(key, of: root) { return .transient }
            if let editor = lastEditorWindow, editor.isVisible,
               isDescendant(editor, of: root), AnalyticsReaderEditorMarker.isPresent(in: editor) {
                // Color tools float outside the sheet hierarchy. The context is
                // cleared synchronously if any unrelated window becomes key.
                if key is NSColorPanel { return .transient }
            }
            return .unrelated
        }

        private func rememberEditorContext(for key: NSWindow) {
            switch keyContext(for: key) {
            case .reader, .editor:
                lastEditorWindow = AnalyticsReaderEditorMarker.isPresent(in: key) ? key : nil
            case .transient: break
            case .unrelated, .none: lastEditorWindow = nil
            }
        }

        private func engagementIsVisible() -> Bool {
            guard let window else { return false }
            return AnalyticsReaderWindowPolicy.isEngaged(readerVisible: window.isVisible && !NSApp.isHidden,
                readerMinimized: window.isMiniaturized, appActive: NSApp.isActive,
                keyContext: keyContext(for: NSApp.keyWindow))
        }

        private func isOwnedInteractionWindow(_ key: NSWindow) -> Bool {
            switch keyContext(for: key) {
            case .reader, .editor, .transient: return true
            case .unrelated, .none: return false
            }
        }

        private func publish() {
            guard let window else { onReadingChange(false); onEngagementChange(false); return }
            if let key = NSApp.keyWindow { rememberEditorContext(for: key) }
            onReadingChange(window.isVisible && window.isKeyWindow && !window.isMiniaturized)
            onEngagementChange(engagementIsVisible())
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("kodiAuthWelcomeSeen") private var authWelcomeSeen = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var model = model

        Group {
            if needsAuthWelcome {
                AISignInSheet(auth: model.aiAuth, onboarding: true) {
                    authWelcomeSeen = true
                    model.aiAuth.showingSignIn = false
                }
            } else if let book = model.book, let reader = model.reader {
                ReaderScreen(book: book, reader: reader)
                    // Rebuild the whole reader when the book changes, so the
                    // web view and its scheme handler are recreated cleanly.
                    .id(book.bookID)
            } else {
                WelcomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.settings.theme.uiBackground)
        .background {
            AnalyticsReadingWindowObserver(
                onReadingChange: { model.readingProgress.setReadingWindowVisible($0) },
                onEngagementChange: { model.analytics.setReadingWindowVisible($0) },
                onReadingInteraction: { model.readingProgress.recordInteraction() },
                onEngagementInteraction: { model.analytics.recordInteraction() })
        }
        .foregroundStyle(model.settings.theme.uiForeground)
        .tint(model.settings.theme.accent)
        .preferredColorScheme(model.settings.theme.colorScheme)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !needsAuthWelcome else { return false }
            return loadDroppedBook(from: providers)
        }
        .alert(
            "Could not open",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
        .task {
            if model.aiAuth.isSignedIn { authWelcomeSeen = true }
        }
        .onChange(of: model.aiAuth.isSignedIn) { _, signedIn in
            if signedIn { authWelcomeSeen = true }
        }
        .task(id: model.aiAuth.userID) { await model.aiCredits.refresh() }
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await model.aiCredits.refresh() } }
        }
        .onChange(of: analyticsReadingContent, initial: true) { _, content in
            model.analytics.setReadingContent(content)
        }
        .onChange(of: isReadingGoalEligible, initial: true) { _, eligible in
            model.readingProgress.setReaderEligible(eligible)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !needsAuthWelcome { UsageAnalyticsNotice() }
        }
        .sheet(isPresented: Binding(get: { !needsAuthWelcome && model.aiAuth.showingSignIn }, set: { model.aiAuth.showingSignIn = $0 })) {
            AISignInSheet(auth: model.aiAuth)
        }
        .sheet(isPresented: Binding(get: { AIFeatureFlags.paymentsEnabled && model.aiCredits.showingPacks }, set: { model.aiCredits.showingPacks = $0 })) {
            AICreditPacksSheet(credits: model.aiCredits)
        }
        .sheet(item: $model.documentToRename) { target in
            RenameDocumentSheet(target: target).environment(model)
        }
        .sheet(isPresented: $model.isShowingReminders) {
            RemindersSheet().environment(model)
        }
    }

    private var needsAuthWelcome: Bool { !authWelcomeSeen && !model.aiAuth.isSignedIn }

    private var isReadingGoalEligible: Bool {
        guard !needsAuthWelcome, model.book != nil,
              let reader = model.reader else { return false }
        return model.hasReadyReader && !reader.isLoading && reader.errorMessage == nil
    }

    /// A stable root observer avoids duplicated starts from rebuilt reader views.
    private var analyticsReadingContent: AnalyticsContentType? {
        guard !needsAuthWelcome else { return nil }
        guard let book = model.book, let reader = model.reader,
              model.hasReadyReader, reader.errorMessage == nil else { return nil }
        return model.record?.sourceURL != nil ? .web : (book.kind == .pdf ? .pdf : .epub)
    }

    private func loadDroppedBook(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // Prefer the file URL representation so the drop carries a
        // security-scoped bookmark Kodi Reader can persist for Recents.
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let itemURL = item as? URL {
                url = itemURL
            } else {
                url = nil
            }
            guard let url, ["epub", "pdf"].contains(url.pathExtension.lowercased()) else { return }
            DispatchQueue.main.async { model.open(url: url) }
        }
        return true
    }
}

private struct RenameDocumentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: BookRecord
    @State private var name: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(target: BookRecord) {
        self.target = target
        _name = State(initialValue: target.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Document").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { save() }
            Text("This name appears in your Kodi library and syncs with your book details. The original file keeps its name.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }

    private func save() {
        do {
            try model.renameDocument(target, to: name)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
