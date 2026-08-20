import Foundation
import WebKit

#if os(macOS)
import AppKit
#endif

/// Owns the Excalidraw `WKWebView` and the JS bridge.
public final class ExcalidrawController {
    public var onReady: (() -> Void)?
    public var onSceneChanged: ((Int, Data) -> Void)?
    public var onError: ((String) -> Void)?

    private var webView: WKWebView?
    private var schemeHandler: ExcalidrawSchemeHandler?
    private var messageProxy: ExcalidrawMessageProxy?
    private var navigationProxy: ExcalidrawNavigationProxy?
    private var isReady = false
    private var pendingScene: Data?
    private var pendingTheme = "light"

    public init() {}

    /// Builds the web view, or returns the existing one across SwiftUI updates.
    public func makeWebView() -> WKWebView {
        if let existing = webView {
            return existing
        }

        let handler = ExcalidrawSchemeHandler()
        schemeHandler = handler

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: ExcalidrawSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = true

        let messages = ExcalidrawMessageProxy(controller: self)
        messageProxy = messages
        configuration.userContentController.add(messages, name: "excalidraw")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = false
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #endif

        let navigation = ExcalidrawNavigationProxy(controller: self)
        navigationProxy = navigation
        webView.navigationDelegate = navigation

        self.webView = webView
        applyChrome()
        webView.load(URLRequest(url: ExcalidrawSchemeHandler.indexURL))
        return webView
    }

    public func tearDown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "excalidraw")
        webView?.navigationDelegate = nil
        webView = nil
        messageProxy = nil
        navigationProxy = nil
        schemeHandler = nil
        isReady = false
    }

    public func load(scene: Data?) {
        pendingScene = scene
        applyPendingIfReady()
    }

    public func setTheme(_ theme: String) {
        pendingTheme = theme == "dark" ? "dark" : "light"
        applyChrome()
        guard isReady else { return }
        evaluate("__excalidraw.setTheme(\(jsString(pendingTheme)))")
    }

