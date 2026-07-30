import EpubKit
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            if let book = model.book, let reader = model.reader {
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
        .preferredColorScheme(model.settings.theme.colorScheme)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedBook(from: providers)
        }
        .alert(
            "Could not open book",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
    }

    private func loadDroppedBook(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "epub" else { return }
            DispatchQueue.main.async { model.open(url: url) }
        }
        return true
    }
}
