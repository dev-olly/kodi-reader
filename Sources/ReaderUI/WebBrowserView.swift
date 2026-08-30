import SwiftUI
import WebKit

#if os(macOS)
import AppKit

/// Hosts the live browser `WKWebView` in SwiftUI.
public struct WebBrowserView: NSViewRepresentable {
    private let controller: WebBrowserController

    public init(controller: WebBrowserController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> WKWebView {
        controller.makeWebView()
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {}

    public static func dismantleNSView(_ webView: WKWebView, coordinator: ()) {
        webView.stopLoading()
    }
}
#endif
