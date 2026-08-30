import EpubKit
import ReaderUI
import SwiftUI

/// Live webpage browsing, with a Save action that freezes the article into the library.
struct WebBrowserScreen: View {
    @Environment(AppModel.self) private var model
    @Bindable var browser: WebBrowserController

    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if browser.isLoading {
                ProgressView(value: browser.estimatedProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 2)
            }

            WebBrowserView(controller: browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(model.settings.theme.uiBackground)
        .toolbar { toolbarContent }
        .onAppear { syncAddress() }
        .onChange(of: browser.currentURL) { _, _ in
            if !addressFocused { syncAddress() }
        }
        .alert(
            "Could not open page",
            isPresented: Binding(
                get: { browser.errorMessage != nil },
                set: { if !$0 { browser.clearError() } }
            ),
            actions: { Button("OK", role: .cancel) { browser.clearError() } },
            message: { Text(browser.errorMessage ?? "") }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { browser.goBack() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .quickHelp("Back")

            Button { browser.goForward() } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .quickHelp("Forward")

            Button { browser.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .quickHelp("Reload")
        }

        ToolbarItem(placement: .principal) {
            TextField("Enter address", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280, idealWidth: 440)
                .focused($addressFocused)
                .onSubmit { goToAddress() }
                .padding(.top, 8)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.isSavingWebPage {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                model.saveCurrentWebPage()
            } label: {
                Label("Save to Library", systemImage: "square.and.arrow.down")
            }
            .disabled(
                model.isSavingWebPage
                    || browser.isLoading
                    || browser.currentURL == nil
            )
            .quickHelp("Save a reader-mode snapshot you can highlight and annotate")

            Button {
                model.closeBrowser()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .disabled(model.isSavingWebPage)
            .quickHelp("Close webpage")
        }
    }

    private func goToAddress() {
        addressFocused = false
        guard let url = WebPageURL.normalized(from: addressText) else {
            model.errorMessage = ArticleError.invalidURL.localizedDescription
            return
        }
        browser.load(url)
    }

    private func syncAddress() {
        if let url = browser.currentURL {
            addressText = url.absoluteString
        }
    }
}

struct OpenURLSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool
    @State private var urlError: String?

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            Text("Open Webpage")
                .font(.headline)

            Text("The live page opens in the reader. Save it to freeze a clean article you can highlight and attach notes to.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://", text: $model.pendingWebURLText)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit() }

            if let urlError {
                Text(urlError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.isShowingOpenURLSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Open") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.pendingWebURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard WebPageURL.normalized(from: model.pendingWebURLText) != nil else {
            urlError = ArticleError.invalidURL.localizedDescription
            return
        }
        urlError = nil
        model.submitOpenURL()
    }
}
