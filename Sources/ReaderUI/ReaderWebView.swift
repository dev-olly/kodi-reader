import EpubKit
import SwiftUI
import WebKit

#if os(macOS)
import AppKit

/// Hosts the reader's `WKWebView` in SwiftUI.
public struct ReaderWebView: NSViewRepresentable {
    private let controller: ReaderController
    private let book: EPUBBook

    public init(controller: ReaderController, book: EPUBBook) {
        self.controller = controller
        self.book = book
    }

    public func makeNSView(context: Context) -> WKWebView {
        controller.makeWebView(for: book)
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        controller.updateViewport(width: webView.bounds.width, height: webView.bounds.height)
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: ()) {
        webView.stopLoading()
    }
}

/// Keyboard handling for page turns.
///
/// The web view swallows key events, so the shortcuts live on an invisible
/// SwiftUI layer above it rather than in the responder chain. Disabled while
/// the note editor is open so arrows/space move the caret instead.
public struct ReaderKeyboardShortcuts: ViewModifier {
    private let controller: ReaderController
    private let enabled: Bool
    private let spaceAction: (() -> Void)?

    public init(
        controller: ReaderController,
        enabled: Bool = true,
        spaceAction: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.enabled = enabled
        self.spaceAction = spaceAction
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if enabled {
                    VStack(spacing: 0) {
                        Button("") { controller.previousPage() }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("") { controller.nextPage() }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                        Button("") { controller.previousPage() }
                            .keyboardShortcut(.upArrow, modifiers: [])
                        Button("") { controller.nextPage() }
                            .keyboardShortcut(.downArrow, modifiers: [])
                        Button("") { controller.nextPage() }
                            .keyboardShortcut(.space, modifiers: [])
                        Button("") { controller.previousPage() }
                            .keyboardShortcut(.space, modifiers: [.shift])
                        Button("") { controller.previousPage() }
                            .keyboardShortcut(.pageUp, modifiers: [])
                        Button("") { controller.nextPage() }
                            .keyboardShortcut(.pageDown, modifiers: [])
                    }
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }
    }
}

public extension View {
    func readerKeyboardShortcuts(_ controller: ReaderController, enabled: Bool = true) -> some View {
        modifier(ReaderKeyboardShortcuts(controller: controller, enabled: enabled))
    }
}
#endif
