import AppKit
import EpubKit
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// Scope reading time to this window: Settings, minimized windows, and other
/// apps should not accrue reading time just because a book remains open.
private struct AnalyticsReadingWindowObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void
    var onInteraction: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView(onChange: onChange, onInteraction: onInteraction) }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.onChange = onChange
        view.onInteraction = onInteraction
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stopObserving() }

    final class MonitorView: NSView {
        var onChange: (Bool) -> Void
        var onInteraction: () -> Void
        private var tokens: [NSObjectProtocol] = []
        private var inputMonitor: Any?

        init(onChange: @escaping (Bool) -> Void, onInteraction: @escaping () -> Void) {
            self.onChange = onChange
            self.onInteraction = onInteraction
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                }
            }
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                if let self, event.window === self.window, self.window?.isKeyWindow == true {
                    self.onInteraction()
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
            onChange(false)
        }

        private func publish() {
            guard let window else { onChange(false); return }
            onChange(window.isVisible && window.isKeyWindow && !window.isMiniaturized)
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
            } else if let browser = model.webBrowser {
                WebBrowserScreen(browser: browser)
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
            AnalyticsReadingWindowObserver(onChange: {
                model.analytics.setReadingWindowVisible($0)
                model.readingProgress.setReadingWindowVisible($0)
            }, onInteraction: { model.readingProgress.recordInteraction() })
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
        .sheet(isPresented: Binding(get: { !needsAuthWelcome && model.aiAuth.showingSignIn }, set: { model.aiAuth.showingSignIn = $0 })) {
            AISignInSheet(auth: model.aiAuth)
        }
        .sheet(isPresented: Binding(get: { AIFeatureFlags.paymentsEnabled && model.aiCredits.showingPacks }, set: { model.aiCredits.showingPacks = $0 })) {
            AICreditPacksSheet(credits: model.aiCredits)
        }
        .sheet(isPresented: $model.isShowingOpenURLSheet) {
            OpenURLSheet()
                .environment(model)
        }
        .sheet(item: $model.documentToRename) { target in
            RenameDocumentSheet(target: target).environment(model)
        }
    }

    private var needsAuthWelcome: Bool { !authWelcomeSeen && !model.aiAuth.isSignedIn }

    private var isReadingGoalEligible: Bool {
        guard !needsAuthWelcome, !model.isBrowsing, model.book != nil,
              let reader = model.reader else { return false }
        return model.hasReadyReader && !reader.isLoading && reader.errorMessage == nil
    }

    /// A stable root observer avoids duplicated starts from rebuilt reader views.
    private var analyticsReadingContent: AnalyticsContentType? {
        guard !needsAuthWelcome else { return nil }
        if let browser = model.webBrowser {
            return !browser.isLoading && browser.estimatedProgress >= 1 && browser.errorMessage == nil && browser.currentURL != nil ? .web : nil
        }
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
