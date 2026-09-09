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
}
#endif
