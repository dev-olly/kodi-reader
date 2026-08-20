import SwiftUI
import WebKit

#if os(macOS)
import AppKit

/// Hosts the Excalidraw `WKWebView` in SwiftUI.
public struct ExcalidrawWebView: NSViewRepresentable {
    private let controller: ExcalidrawController

    public init(controller: ExcalidrawController) {
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
