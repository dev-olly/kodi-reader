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
        // The controller still owns this view while an in-app browser preview
        // is on screen. Aborting the load would drop the chapter and jump to
        // the start when the preview closes.
    }
}

/// Decides when page-turn keys should yield to whatever currently has focus.
///
/// The reader web view swallows key events without paging, so shortcuts are
/// handled out of band. Anything else — the notes list, the markdown editor,
/// Excalidraw, a search field — must keep arrows, space, and page keys.
public enum ReaderKeyTarget {
    public static let pageWebViewIdentifier = NSUserInterfaceItemIdentifier("kodi-reader-page")

    public static func shouldSuppressPageTurns(for responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        if isInsideReaderPage(view) { return false }
        return ownsNavigation(view)
    }

    public static func isInsideReaderPage(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node.identifier == pageWebViewIdentifier { return true }
            current = node.superview
        }
        return false
    }

    /// Notes list, markdown editor, Excalidraw, search fields, and similar.
    public static func ownsNavigation(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node is NSTextView || node is NSTextField { return true }
            if node is NSTableView || node is NSOutlineView || node is NSCollectionView {
                return true
            }
            if node is WKWebView || node is NSScrollView { return true }
            current = node.superview
        }
        return false
    }

    /// Directs key events at the sidebar control the user clicked.
    @discardableResult
    public static func claimKeyFocus(from view: NSView, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        var current: NSView? = view
        while let node = current {
            if node is WKWebView || node is NSTextView || node is NSTextField
                || node is NSTableView || node is NSOutlineView
            {
                return window.makeFirstResponder(node)
            }
            current = node.superview
        }
        current = view
        while let node = current {
            if node is NSScrollView {
                return window.makeFirstResponder(node)
            }
            current = node.superview
        }
        return false
    }
}

/// Keyboard handling for page turns.
///
/// The web view swallows key events, so paging is driven by a local key
/// monitor rather than the responder chain. Keys pass through when focus is
/// outside the reading surface (sidebar, Excalidraw, text fields).
public struct ReaderKeyboardShortcuts: ViewModifier {
    private let controller: ReaderController
    private let enabled: Bool
    private let spaceAction: (() -> Void)?
    private let onSuppressChange: ((Bool) -> Void)?

    public init(
        controller: ReaderController,
        enabled: Bool = true,
        spaceAction: (() -> Void)? = nil,
        onSuppressChange: ((Bool) -> Void)? = nil
    ) {
        self.controller = controller
        self.enabled = enabled
        self.spaceAction = spaceAction
        self.onSuppressChange = onSuppressChange
    }

    public func body(content: Content) -> some View {
        content
            .background {
                PageTurnKeyMonitor(
                    controller: controller,
                    enabled: enabled,
                    spaceAction: spaceAction,
                    onSuppressChange: onSuppressChange
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

public extension View {
    func readerKeyboardShortcuts(
        _ controller: ReaderController,
        enabled: Bool = true,
        spaceAction: (() -> Void)? = nil,
        onSuppressChange: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(ReaderKeyboardShortcuts(
            controller: controller,
            enabled: enabled,
            spaceAction: spaceAction,
            onSuppressChange: onSuppressChange
        ))
    }
}

/// Invisible AppKit view that owns the local key monitor.
private struct PageTurnKeyMonitor: NSViewRepresentable {
    var controller: ReaderController
    var enabled: Bool
    var spaceAction: (() -> Void)?
    var onSuppressChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.controller = controller
        view.enabled = enabled
        view.spaceAction = spaceAction
        view.onSuppressChange = onSuppressChange
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.controller = controller
        view.enabled = enabled
        view.spaceAction = spaceAction
        view.onSuppressChange = onSuppressChange
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.tearDown()
    }

    final class MonitorView: NSView {
        var controller: ReaderController?
        var enabled: Bool = true
        var spaceAction: (() -> Void)?
        var onSuppressChange: ((Bool) -> Void)?

        private var keyMonitor: Any?
        private var mouseMonitor: Any?
        private var updateObserver: NSObjectProtocol?
        private var lastSuppress = false
        /// Last click was on the sidebar (or another non-reader control).
        private var clickedAwayFromReader = false

        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                install()
            } else {
                tearDown()
            }
        }

        func tearDown() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            if let updateObserver {
                NotificationCenter.default.removeObserver(updateObserver)
                self.updateObserver = nil
            }
        }

        private func install() {
            tearDown()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKey(event) ?? event
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event) ?? event
            }
            updateObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.publishSuppressIfNeeded()
            }
            publishSuppressIfNeeded()
        }

        private func handleMouseDown(_ event: NSEvent) -> NSEvent {
            guard enabled else { return event }
            guard let content = event.window?.contentView else { return event }
            let point = content.convert(event.locationInWindow, from: nil)
            guard let hit = content.hitTest(point) else { return event }

            if ReaderKeyTarget.isInsideReaderPage(hit) {
                clickedAwayFromReader = false
            } else if ReaderKeyTarget.ownsNavigation(hit) {
                clickedAwayFromReader = true
                ReaderKeyTarget.claimKeyFocus(from: hit, in: event.window)
            }
            publishSuppressIfNeeded()
            return event
        }

        private func handleKey(_ event: NSEvent) -> NSEvent? {
            publishSuppressIfNeeded()
            guard enabled else { return event }

            let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
            if clickedAwayFromReader || ReaderKeyTarget.shouldSuppressPageTurns(for: responder) {
                return event
            }

            let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
            if !mods.subtracting(.shift).isEmpty {
                return event
            }

            switch event.keyCode {
            case 123, 126, 116: // left, up, page up
                controller?.previousPage()
                return nil
            case 124, 125, 121: // right, down, page down
                controller?.nextPage()
                return nil
            case 49: // space
                if mods.contains(.shift) {
                    controller?.previousPage()
                } else if let spaceAction {
                    spaceAction()
                } else {
                    controller?.nextPage()
                }
                return nil
            default:
                return event
            }
        }

        private func publishSuppressIfNeeded() {
            let responder = window?.firstResponder ?? NSApp.keyWindow?.firstResponder
            if let view = responder as? NSView, ReaderKeyTarget.isInsideReaderPage(view) {
                clickedAwayFromReader = false
            }
            let next = clickedAwayFromReader
                || ReaderKeyTarget.shouldSuppressPageTurns(for: responder)
            guard next != lastSuppress else { return }
            lastSuppress = next
            onSuppressChange?(next)
        }
    }
}
#endif
