import Foundation
import WebKit

#if os(macOS)
import AppKit
#endif

/// Owns the Excalidraw `WKWebView` and the JS bridge.
public struct SketchCheckpoint {
    public let scene: Data
    public let preview: Data?
    public let elementCount: Int
}

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
    private var session = 0
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

        #if os(macOS)
        let webView = ExcalidrawHostWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        webView.allowsMagnification = false

        let navigation = ExcalidrawNavigationProxy(controller: self)
        navigationProxy = navigation
        webView.navigationDelegate = navigation

        self.webView = webView
        applyChrome()
        webView.load(URLRequest(url: ExcalidrawSchemeHandler.indexURL))
        return webView
    }

    public func tearDown() {
        session += 1
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "excalidraw")
        webView?.navigationDelegate = nil
        webView = nil
        messageProxy = nil
        navigationProxy = nil
        schemeHandler = nil
        isReady = false
    }

    /// Gives the canvas key focus so arrows nudge shapes instead of paging.
    public func focusCanvas() {
        #if os(macOS)
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        #endif
    }

    public func load(scene: Data?) {
        session += 1
        pendingScene = scene
        applyPendingIfReady()
    }

    public func setTheme(_ theme: String) {
        pendingTheme = theme == "dark" ? "dark" : "light"
        applyChrome()
        guard isReady else { return }
        evaluate("__excalidraw.setTheme(\(jsString(pendingTheme)))")
    }

    /// Reads the live scene and retains it for recovery after a WebKit restart.
    public func pullScene(completion: @escaping (Int, Data?) -> Void) {
        guard webView != nil, isReady else {
            completion(0, nil)
            return
        }
        let token = session
        evaluate("__excalidraw.getScene()") { [weak self] result in
            guard let self, self.session == token else { completion(0, nil); return }
            let decoded = Self.decodeScene(result)
            if let data = decoded.1 { self.pendingScene = data }
            completion(decoded.0, decoded.1)
        }
    }

    public func checkpoint(completion: @escaping (Result<SketchCheckpoint, Error>) -> Void) {
        guard let webView, isReady else { completion(.failure(Self.error("The drawing surface is not ready."))); return }
        let token = session
        var completed = false
        let finish: (Result<SketchCheckpoint, Error>) -> Void = { result in
            guard !completed else { return }
            completed = true
            completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(.failure(Self.error("Saving the sketch timed out. Try again."))) }
        webView.callAsyncJavaScript("return await window.__excalidraw.checkpoint();", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard !completed else { return }
            guard let self, self.session == token else { finish(.failure(Self.error("The active sketch changed."))); return }
            finish(result.flatMap { value in
                guard let body = value as? [String: Any], (body["session"] as? Int) == token else { return .failure(Self.error("Invalid drawing checkpoint.")) }
                let decoded = Self.decodeScene(body)
                guard let scene = decoded.1 else { return .failure(Self.error("Could not read the drawing.")) }
                let preview = (body["preview"] as? String).flatMap { Data(base64Encoded: $0) }
                guard decoded.0 == 0 || preview != nil else { return .failure(Self.error("Could not render the drawing.")) }
                self.pendingScene = scene
                return .success(SketchCheckpoint(scene: scene, preview: preview, elementCount: decoded.0))
            })
        }
    }

    /// A separate host renders assets without touching the user's canvas or undo history.
    public static func renderPreview(scene: Data, completion: @escaping (Result<Data, Error>) -> Void) {
        let renderer = ExcalidrawController()
        var finished = false
        let finish: (Result<Data, Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            renderer.onReady = nil; renderer.onError = nil
            renderer.tearDown()
            completion(result)
        }
        renderer.onError = { finish(.failure(error($0))) }
        renderer.onReady = {
            guard let view = renderer.webView, let json = String(data: scene, encoding: .utf8) else { finish(.failure(error("Invalid sketch scene."))); return }
            view.callAsyncJavaScript("return await window.__excalidraw.renderScene(scene);", arguments: ["scene": json], in: nil, in: .page) { result in
                finish(result.flatMap { value in
                    guard let encoded = value as? String, let data = Data(base64Encoded: encoded) else { return .failure(error("Could not render the sketch preview.")) }
                    return .success(data)
                })
            }
        }
        renderer.makeWebView().frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(.failure(error("Sketch rendering timed out. Try exporting again."))) }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "KodiSketch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    fileprivate func handle(message body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            applyPendingIfReady()
            onReady?()
        case "sceneChanged":
            guard (body["session"] as? Int) == session else { return }
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
            evaluate("__excalidraw.load(\(jsString(json)), \(session))")
        } else {
            evaluate("__excalidraw.clear(\(session))")
        }
    }

    private func applyChrome() {
        #if os(macOS)
        guard let webView else { return }
        let color: NSColor = pendingTheme == "dark"
            ? NSColor(calibratedRed: 32 / 255, green: 37 / 255, blue: 34 / 255, alpha: 1)
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

    private static func decodeScene(_ result: Any?) -> (Int, Data?) {
        guard let body = result as? [String: Any] else { return (0, nil) }
        let count: Int
        if let number = body["elementCount"] as? NSNumber {
            count = number.intValue
        } else {
            count = body["elementCount"] as? Int ?? 0
        }
        guard let json = body["scene"] as? String else { return (count, nil) }
        return (count, json.data(using: .utf8))
    }
}

private final class ExcalidrawMessageProxy: NSObject, WKScriptMessageHandler {
    weak var controller: ExcalidrawController?

    init(controller: ExcalidrawController) {
        self.controller = controller
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        controller?.handle(message: body)
    }
}

private final class ExcalidrawNavigationProxy: NSObject, WKNavigationDelegate {
    weak var controller: ExcalidrawController?

    init(controller: ExcalidrawController) {
        self.controller = controller
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            return decisionHandler(.cancel)
        }
        decisionHandler(url.scheme == ExcalidrawSchemeHandler.scheme ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        controller?.reportLoadFailure(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        controller?.handleProcessTermination()
    }
}

#if os(macOS)
/// Takes first responder on click so canvas shortcuts reach Excalidraw, not the book.
private final class ExcalidrawHostWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}
#endif
