#if os(macOS)
import AppKit
import WebKit
import XCTest
@testable import ReaderUI

final class PageTurnKeyTests: XCTestCase {
    func testReaderWebViewKeepsPageTurnKeys() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        webView.identifier = ReaderKeyTarget.pageWebViewIdentifier
        XCTAssertFalse(ReaderKeyTarget.shouldSuppressPageTurns(for: webView))
        XCTAssertTrue(ReaderKeyTarget.isInsideReaderPage(webView))
    }

    func testNestedViewInsideReaderKeepsPageTurnKeys() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        webView.identifier = ReaderKeyTarget.pageWebViewIdentifier
        let child = NSView(frame: .zero)
        webView.addSubview(child)
        XCTAssertFalse(ReaderKeyTarget.shouldSuppressPageTurns(for: child))
    }

    func testExcalidrawWebViewTakesNavigationKeys() {
        let drawing = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(ReaderKeyTarget.shouldSuppressPageTurns(for: drawing))
        XCTAssertTrue(ReaderKeyTarget.ownsNavigation(drawing))
        XCTAssertFalse(ReaderKeyTarget.isInsideReaderPage(drawing))
    }

    func testNoteTextViewTakesNavigationKeys() {
        let text = NSTextView(frame: .zero)
        XCTAssertTrue(ReaderKeyTarget.shouldSuppressPageTurns(for: text))
        XCTAssertTrue(ReaderKeyTarget.ownsNavigation(text))
    }

    func testNotesListTakesNavigationKeys() {
        let table = NSTableView()
        XCTAssertTrue(ReaderKeyTarget.shouldSuppressPageTurns(for: table))
    }

    func testWindowDoesNotSuppressPageTurns() {
        XCTAssertFalse(ReaderKeyTarget.shouldSuppressPageTurns(for: nil))
    }

    func testVisibleButUnfocusedSidebarDoesNotTakePageTurnKeys() {
        let window = makeWindow()
        let sidebar = NSScrollView(frame: .zero)
        window.contentView?.addSubview(sidebar)

        XCTAssertTrue(
            ReaderKeyTarget.shouldHandlePageTurn(
                for: nil,
                eventWindow: window,
                readerWindow: window
            ),
            "Opening the sidebar must not send page-turn keys into AppKit's responder chain"
        )
    }

    func testFocusedSidebarEditorKeepsNavigationKeys() {
        let window = makeWindow()
        let text = NSTextView(frame: .zero)
        window.contentView?.addSubview(text)

        XCTAssertFalse(
            ReaderKeyTarget.shouldHandlePageTurn(
                for: text,
                eventWindow: window,
                readerWindow: window
            )
        )
    }

    func testReaderMonitorIgnoresNavigationKeysFromAnotherWindow() {
        let readerWindow = makeWindow()
        let otherWindow = makeWindow()

        XCTAssertFalse(
            ReaderKeyTarget.shouldHandlePageTurn(
                for: nil,
                eventWindow: otherWindow,
                readerWindow: readerWindow
            )
        )
    }

    func testDetachedSidebarControlDoesNotSuppressPageTurns() {
        let window = makeWindow()
        let text = NSTextView(frame: .zero)
        window.contentView?.addSubview(text)

        XCTAssertTrue(ReaderKeyTarget.shouldSuppressPageTurns(for: text, in: window))

        text.removeFromSuperview()

        XCTAssertFalse(
            ReaderKeyTarget.shouldSuppressPageTurns(for: text, in: window),
            "A removed Notes or Ask AI control must return keyboard navigation to the reader"
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentLayoutRect)
        return window
    }
}
#endif
