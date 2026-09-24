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

    func testNavigationKeysAreConsumedBeforeReachingAppKit() throws {
        let (window, monitor) = makeMonitoredWindow()
        defer { monitor.tearDown() }
        var spaceActions = 0
        monitor.spaceAction = { spaceActions += 1 }

        for keyCode: UInt16 in [123, 124, 125, 126, 116, 121, 49] {
            for modifiers: NSEvent.ModifierFlags in [[], .shift] {
                for isRepeat in [false, true] {
                    let event = try keyEvent(keyCode, in: window, modifiers: modifiers, isRepeat: isRepeat)
                    XCTAssertNil(monitor.keyEventHandler(event),
                                 "Handled navigation keys must not reach AppKit and trigger an alert or a second scroll")
                }
            }
        }

        XCTAssertEqual(spaceActions, 2, "Each space press or repeat should navigate exactly once")
    }

    func testUnhandledKeysAndDisabledMonitorPassEventsThrough() throws {
        let (window, monitor) = makeMonitoredWindow()
        defer { monitor.tearDown() }

        let letter = try keyEvent(0, in: window) // A
        XCTAssertTrue(monitor.keyEventHandler(letter) === letter)
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control] {
            let shortcut = try keyEvent(124, in: window, modifiers: modifier)
            XCTAssertTrue(monitor.keyEventHandler(shortcut) === shortcut)
        }
        monitor.enabled = false
        let arrow = try keyEvent(125, in: window)
        XCTAssertTrue(monitor.keyEventHandler(arrow) === arrow)
    }

    func testMonitorPreservesEditorAndOtherWindowNavigation() throws {
        let (window, monitor) = makeMonitoredWindow()
        defer { monitor.tearDown() }
        let editor = NSTextView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let editorArrow = try keyEvent(123, in: window)
        XCTAssertTrue(monitor.keyEventHandler(editorArrow) === editorArrow)

        let otherWindow = NSWindow(
            contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        let otherArrow = try keyEvent(124, in: otherWindow)
        XCTAssertTrue(monitor.keyEventHandler(otherArrow) === otherArrow)
    }

    private func makeMonitoredWindow() -> (NSWindow, PageTurnKeyMonitor.MonitorView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let monitor = PageTurnKeyMonitor.MonitorView()
        monitor.controller = ReaderController()
        window.contentView?.addSubview(monitor)
        return (window, monitor)
    }

    private func keyEvent(
        _ keyCode: UInt16,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: keyCode == 49 ? " " : "", charactersIgnoringModifiers: "",
            isARepeat: isRepeat, keyCode: keyCode
        ))
    }
}

#endif
