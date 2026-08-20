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
