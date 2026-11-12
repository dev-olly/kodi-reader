import AppKit
import EpubKit
import ReaderUI
import SwiftUI
import WebKit

/// Turns a public article into the same offline EPUB used by the reader.
struct SaveWebpageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importer = WebpageImporter()
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private var palette: LibraryPalette { .init(isDark: model.settings.theme.isDark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "link")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(palette.accent)
                .frame(width: 46, height: 46)
                .background(palette.accentSoft, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text("Save a webpage")
                    .font(.system(size: 24, weight: .semibold))
                Text("Keep an article in your library to read and annotate offline.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("https://example.com/article", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(12)
                .background(palette.surface, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(addressFocused ? palette.accent : palette.line))
                .focused($addressFocused)
                .disabled(importer.isLoading)
                .accessibilityLabel("Webpage address")
                .onSubmit(save)
            if let error = importer.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if importer.isLoading {
                    ProgressView().controlSize(.small)
                    Text(importer.status)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    importer.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save webpage", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(importer.isLoading || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(palette.background)
        .foregroundStyle(palette.ink)
        .tint(palette.accent)
        .onAppear { addressFocused = true }
        .onDisappear { importer.cancel() }
    }

    private func save() {
        importer.save(address: address) { file, source in
            model.open(url: file, sourceURL: source)
            dismiss()
        }
    }
}

@MainActor
private final class WebpageImporter: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var status = "Loading article…"
    @Published private(set) var error: String?
    private var webView: WKWebView?
    private var operation: UUID?
    private var timeout: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    private var onSaved: ((URL, URL) -> Void)?

    func save(address: String, onSaved: @escaping (URL, URL) -> Void) {
        guard !isLoading else { return }
        guard let url = WebPageURL.normalized(from: address), Self.isAllowed(url) else {
            error = "Enter an http or https webpage address without a username or password."
            return
        }
        error = nil
        isLoading = true
        status = "Loading article…"
        self.onSaved = onSaved
        let operation = UUID()
        self.operation = operation

        let configuration = WKWebViewConfiguration()
        // Public pages never inherit the user's browser cookies or sign-in.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        view.load(URLRequest(url: url, timeoutInterval: 25))
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.operation == operation else { return }
            fail("The page took too long to load. Try again or choose another article.")
        }
    }

    func cancel() {
        operation = nil
        timeout?.cancel()
        timeout = nil
        buildTask?.cancel()
        buildTask = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
        onSaved = nil
        isLoading = false
    }

    private func fail(_ message: String) {
        cancel()
        error = message
    }

    private static func isAllowed(_ url: URL) -> Bool {
        WebPageURL.isAllowed(url) && url.user == nil && url.password == nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, let url = navigationAction.request.url,
              Self.isAllowed(url), navigationAction.targetFrame != nil else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if navigationResponse.isForMainFrame {
            if let response = navigationResponse.response as? HTTPURLResponse,
               !(200..<400).contains(response.statusCode) {
                decisionHandler(.cancel)
                fail("The page could not be opened (HTTP \(response.statusCode)).")
                return
            }
            let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
            guard mime == "text/html" || mime == "application/xhtml+xml" else {
                decisionHandler(.cancel)
                fail("Choose an article webpage. Use Add books for EPUB and PDF files.")
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { fail(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { fail(error.localizedDescription) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { fail("The page could not be read. Try saving it again.") }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let operation,
              let source = webView.url, Self.isAllowed(source) else { return }
        status = "Saving article…"
        webView.evaluateJavaScript(Self.extractionScript, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, self.operation == operation else { return }
            switch result {
            case .failure:
                fail("This page could not be read. Try another article.")
            case let .success(value):
                guard let result = value as? [String: Any], let html = result["html"] as? String,
                      !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    fail("No article text was found. Choose a public article that does not require signing in.")
                    return
                }
                let article = ArticleContent(title: result["title"] as? String ?? "", byline: result["byline"] as? String,
                                             sourceURL: source, contentHTML: html, language: result["language"] as? String)
                self.webView?.navigationDelegate = nil
                self.webView?.stopLoading()
                self.webView = nil
                self.buildTask = Task { [weak self] in
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Kodi-Webpage-\(UUID().uuidString).epub")
                    do {
                        try Task.checkCancellation()
                        try await ArticleEPUBBuilder.build(article, to: destination)
                        try Task.checkCancellation()
                        guard let self, self.operation == operation else {
                            try? FileManager.default.removeItem(at: destination)
                            return
                        }
                        let saved = self.onSaved
                        self.buildTask = nil
                        self.cancel()
                        // AppModel imports a durable copy asynchronously, so its source
                        // must remain available after this sheet has closed.
                        saved?(destination, source)
                    } catch is CancellationError {
                        try? FileManager.default.removeItem(at: destination)
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        guard let self, self.operation == operation else { return }
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Copies only article text and basic semantic markup; no scripts, forms,
    /// embedded players, or remote images are included in the offline document.
    private static let extractionScript = #"""
    (() => {
      const text = node => (node?.textContent || '').replace(/\s+/g, ' ').trim();
      const meta = name => document.querySelector(`meta[name="${name}"], meta[property="${name}"]`)?.content?.trim();
      const title = meta('og:title') || text(document.querySelector('article h1, main h1, h1')) || document.title;
      const byline = meta('author') || text(document.querySelector('[rel="author"], [itemprop="author"], .byline'));
      const roots = Array.from(document.querySelectorAll('article, main, [role="main"], .article-body, .post-content, .entry-content'));
      const candidates = (roots.length ? roots : [document.body]).filter(Boolean).map(root => {
        const clone = root.cloneNode(true);
        clone.querySelectorAll('script, style, noscript, nav, footer, aside, form, button, iframe, svg, video, audio, dialog, [hidden], [aria-hidden="true"]').forEach(node => node.remove());
        const total = text(clone).length;
        const links = Array.from(clone.querySelectorAll('a')).reduce((sum, node) => sum + text(node).length, 0);
        const paragraphs = Array.from(clone.querySelectorAll('p')).reduce((sum, node) => sum + text(node).length, 0);
        return { clone, score: paragraphs * 2 + total - links * 2 };
      }).sort((a, b) => b.score - a.score);
      const root = candidates[0]?.clone;
      if (!root || text(root).length < 80) return { html: '' };
      const escape = value => value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
      const allowed = new Set(['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'ul', 'ol', 'li', 'pre', 'code', 'em', 'strong', 'b', 'i', 'u', 's', 'sup', 'sub', 'br', 'hr', 'figure', 'figcaption', 'table', 'thead', 'tbody', 'tr', 'th', 'td']);
      function serialize(node) {
        if (node.nodeType === Node.TEXT_NODE) return escape(node.textContent || '');
        if (node.nodeType !== Node.ELEMENT_NODE) return '';
        const tag = node.tagName.toLowerCase();
        if (['img', 'input', 'select', 'textarea', 'canvas', 'object', 'embed'].includes(tag)) return '';
        const children = Array.from(node.childNodes).map(serialize).join('');
        if (tag === 'a') {
          try {
            const url = new URL(node.getAttribute('href'), document.baseURI);
            if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password)
              return `<a href="${escape(url.href)}">${children}</a>`;
          } catch (_) {}
          return children;
        }
        if (!allowed.has(tag)) return ['div', 'section', 'article', 'main'].includes(tag) ? `<div>${children}</div>` : children;
        if (tag === 'br' || tag === 'hr') return `<${tag} />`;
        return `<${tag}>${children}</${tag}>`;
      }
      const html = Array.from(root.childNodes).map(serialize).join('');
      return { title, byline, html, language: document.documentElement.lang || '' };
    })()
    """#
}
