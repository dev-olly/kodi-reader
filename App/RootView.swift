import EpubKit
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("kodiAuthWelcomeSeen") private var authWelcomeSeen = false

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
        .sheet(isPresented: Binding(get: { !needsAuthWelcome && model.aiAuth.showingSignIn }, set: { model.aiAuth.showingSignIn = $0 })) {
            AISignInSheet(auth: model.aiAuth)
        }
        .sheet(isPresented: $model.isShowingOpenURLSheet) {
            OpenURLSheet()
                .environment(model)
        }
    }

    private var needsAuthWelcome: Bool { !authWelcomeSeen && !model.aiAuth.isSignedIn }

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
