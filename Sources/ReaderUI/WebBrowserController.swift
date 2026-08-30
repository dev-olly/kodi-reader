import EpubKit
import Foundation
import Observation
import WebKit

#if os(macOS)
import AppKit
#endif

/// Drives a live `WKWebView` for browsing the open web, and extracts a
/// reader-mode article from the current page when the user saves it.
@Observable
public final class WebBrowserController {
    public private(set) var currentURL: URL?
    public private(set) var title: String?
    public private(set) var isLoading: Bool = false
    public private(set) var estimatedProgress: Double = 0
    public private(set) var canGoBack: Bool = false
    public private(set) var canGoForward: Bool = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var navigationProxy: BrowserNavigationProxy?
    @ObservationIgnored private var uiProxy: BrowserUIProxy?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pendingURL: URL?

    public init() {}

    /// Builds the web view, or returns the existing one across SwiftUI updates.
    public func makeWebView() -> WKWebView {
        if let existing = webView {
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        #if os(macOS)
        webView.allowsMagnification = true
        #endif

        let navigation = BrowserNavigationProxy(controller: self)
        navigationProxy = navigation
        webView.navigationDelegate = navigation

        let ui = BrowserUIProxy(controller: self)
        uiProxy = ui
        webView.uiDelegate = ui

        observe(webView)
        self.webView = webView

        if let pendingURL {
            self.pendingURL = nil
            load(pendingURL)
        }
        return webView
    }

    public func tearDown() {
        observations.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        navigationProxy = nil
        uiProxy = nil
    }

    public func load(_ url: URL) {
        errorMessage = nil
        guard WebPageURL.isAllowed(url) else {
            errorMessage = ArticleError.invalidURL.localizedDescription
            return
        }
        guard let webView else {
            pendingURL = url
            currentURL = url
            return
        }
        webView.load(URLRequest(url: url))
    }

    public func goBack() { webView?.goBack() }
    public func goForward() { webView?.goForward() }
    public func reload() { webView?.reload() }

    public func clearError() {
        errorMessage = nil
    }

    /// Runs Mozilla Readability against the live DOM.
    ///
    /// Library and runner are concatenated so the `function Readability`
    /// declaration stays in scope — `evaluateJavaScript` does not leak locals
    /// across separate calls.
    public func extractArticle(completion: @escaping (Result<ArticleContent, Error>) -> Void) {
        guard let webView else {
            completion(.failure(ArticleError.extractionFailed("The page is not loaded yet.")))
            return
        }
        guard let sourceURL = webView.url ?? currentURL, WebPageURL.isAllowed(sourceURL) else {
            completion(.failure(ArticleError.invalidURL))
            return
        }
        guard
            let library = bundledScript("Readability.js"),
            let runner = bundledScript("readability-extract.js")
        else {
            completion(.failure(ArticleError.extractionFailed("The article extractor is missing.")))
            return
        }

        webView.evaluateJavaScript(library + "\n" + runner) { result, error in
            if let error {
                completion(.failure(ArticleError.extractionFailed(error.localizedDescription)))
                return
            }
            completion(Self.decodeArticle(result, sourceURL: sourceURL))
        }
    }

    private func bundledScript(_ name: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeArticle(_ result: Any?, sourceURL: URL) -> Result<ArticleContent, Error> {
        let json: Data?
        if let string = result as? String {
            json = Data(string.utf8)
        } else if let data = result as? Data {
            json = data
        } else {
            json = nil
        }
        guard let json, let payload = try? JSONDecoder().decode(ExtractPayload.self, from: json) else {
            return .failure(ArticleError.emptyArticle)
        }
        if let error = payload.error, !error.isEmpty {
            return .failure(ArticleError.extractionFailed(error))
        }
        let html = (payload.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !html.isEmpty else {
            return .failure(ArticleError.emptyArticle)
        }
        let title = (payload.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let byline = (payload.byline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = (payload.lang ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            ArticleContent(
                title: title.isEmpty ? (sourceURL.host ?? sourceURL.absoluteString) : title,
                byline: byline.isEmpty ? nil : byline,
                sourceURL: sourceURL,
                contentHTML: html,
                language: lang.isEmpty ? nil : lang
            )
        )
    }

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.currentURL = view.url }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.title = view.title }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.estimatedProgress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    fileprivate func reportLoadFailure(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    fileprivate func decidePolicy(for url: URL?) -> WKNavigationActionPolicy {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" {
            return .allow
        }
        return WebPageURL.isAllowed(url) ? .allow : .cancel
    }

    private struct ExtractPayload: Decodable {
        var title: String?
        var byline: String?
        var content: String?
        var textContent: String?
        var excerpt: String?
        var lang: String?
        var error: String?
    }
}

private final class BrowserNavigationProxy: NSObject, WKNavigationDelegate {
    weak var controller: WebBrowserController?

    init(controller: WebBrowserController) {
        self.controller = controller
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(controller?.decidePolicy(for: navigationAction.request.url) ?? .cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        controller?.reportLoadFailure(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        controller?.reportLoadFailure(error.localizedDescription)
    }
}

private final class BrowserUIProxy: NSObject, WKUIDelegate {
    weak var controller: WebBrowserController?

    init(controller: WebBrowserController) {
        self.controller = controller
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            controller?.load(url)
        }
        return nil
    }
}
