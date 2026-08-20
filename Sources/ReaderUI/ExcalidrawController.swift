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

    /// Reads the live scene, then tears the web view down.
    public func pullScene(completion: @escaping (Int, Data?) -> Void) {
        guard webView != nil, isReady else {
            completion(0, nil)
            return
        }
        evaluate("__excalidraw.getScene()") { result in
            let decoded = Self.decodeScene(result)
            completion(decoded.0, decoded.1)
        }
    }

    fileprivate func handle(message body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            applyPendingIfReady()
            onReady?()
        case "sceneChanged":
            pullScene { [weak self] count, data in
                guard let data else { return }
                self?.onSceneChanged?(count, data)
            }
        case "error":
            let message = body["message"] as? String ?? "unknown error"
            onError?(message)
        default:
            break
        }
    }

    fileprivate func reportLoadFailure(_ message: String) {
        onError?(message)
    }

    fileprivate func handleProcessTermination() {
        isReady = false
        webView?.load(URLRequest(url: ExcalidrawSchemeHandler.indexURL))
    }

    private func applyPendingIfReady() {
        guard isReady else { return }
        evaluate("__excalidraw.setTheme(\(jsString(pendingTheme)))")
        if let scene = pendingScene, let json = String(data: scene, encoding: .utf8), !json.isEmpty {
            evaluate("__excalidraw.load(\(jsString(json)))")
        } else {
            evaluate("__excalidraw.clear()")
        }
    }

    private func applyChrome() {
        #if os(macOS)
        guard let webView else { return }
        let color: NSColor = pendingTheme == "dark"
            ? NSColor(calibratedRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
            : .white
        webView.underPageBackgroundColor = color
        webView.wantsLayer = true
        webView.layer?.backgroundColor = color.cgColor
        #endif
    }

    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard let webView else {
            completion?(nil)
            return
        }
        webView.evaluateJavaScript(script) { result, _ in
            completion?(result)
        }
    }

    private func jsString(_ value: String) -> String {
        let wrapped = try? JSONSerialization.data(withJSONObject: [value])
        guard let wrapped, var encoded = String(data: wrapped, encoding: .utf8) else {
            return "\"\""
        }
        encoded.removeFirst()
        encoded.removeLast()
        return encoded
    }

