import AppKit
import EpubKit
import WebKit
import XCTest
@testable import ReaderUI

final class ReminderMarkerTests: XCTestCase {
    private var window: NSWindow?
    private var controller: ReaderController?
    private var bookURL: URL?

    override func tearDown() {
        controller?.tearDown()
        window?.contentView = nil
        window?.orderOut(nil)
        if let bookURL { try? FileManager.default.removeItem(at: bookURL) }
        super.tearDown()
    }

    func testReminderOnlyBadgePreservesContentSelectionAndPassageAndBridgesClick() throws {
        let reader = try makeReader()
        let locator = try firstPassage(in: reader)
        let reminder = ResearchReminder(title: "Research allegories", locator: locator, quotedText: locator.text ?? "")
        let originalHTML = evaluate(reader, "document.querySelector('p').innerHTML") as? String
        let originalPath = evaluate(reader, "JSON.stringify(__reader.state().position.elementPath)") as? String
        let originalPassage = try passage(reader, locator: locator)
        selectPassage(reader, locator: locator)
        let selected = evaluate(reader, "window.getSelection().toString()") as? String
        let page = reader.page
        var activated: (UUID, CGRect)?
        reader.onReminderActivated = { activated = ($0, $1) }

        reader.setReminders([reminder])
        XCTAssertTrue(wait { self.badgeCount(reader) == 1 })
        XCTAssertEqual(evaluate(reader, "document.querySelectorAll('.reader-highlight-rect').length") as? Int, 0)
        XCTAssertEqual(evaluate(reader, "document.querySelector('p').innerHTML") as? String, originalHTML)
        XCTAssertEqual(evaluate(reader, "JSON.stringify(__reader.state().position.elementPath)") as? String, originalPath)
        XCTAssertEqual(evaluate(reader, "window.getSelection().toString()") as? String, selected)
        let after = try passage(reader, locator: locator)
        XCTAssertEqual(after.before, originalPassage.before)
        XCTAssertEqual(after.quote, originalPassage.quote)
        XCTAssertEqual(after.after, originalPassage.after)
        XCTAssertTrue(badgesAvoidText(reader), "A reminder action must not cover book letters")
        XCTAssertEqual(evaluate(reader, "document.querySelector('.reader-reminder-badge').getAttribute('aria-label')") as? String,
                       "Research reminder: Research allegories")
        XCTAssertEqual(evaluate(reader, "document.querySelector('.reader-reminder-badge').title") as? String, reminder.title)

        // Exercise capture-phase routing with a nested SVG target, including
        // while a text selection remains active. It must not trigger paging.
        _ = evaluate(reader, "document.querySelector('.reader-reminder-badge svg').dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true}))")
        XCTAssertTrue(wait { activated != nil })
        XCTAssertEqual(activated?.0, reminder.id)
        XCTAssertEqual(activated?.1.width, 22)
        XCTAssertEqual(activated?.1.height, 22)
        XCTAssertEqual(reader.page, page)
        XCTAssertNil(reader.readingMarker)
    }

    func testReminderRepaintsIndependentlyAndCompletionOrDeletionLeavesHighlightsAlone() throws {
        let reader = try makeReader()
        let locator = try firstPassage(in: reader)
        let annotation = Annotation(locator: locator, text: locator.text ?? "", note: "A note", color: .green)
        var reminder = ResearchReminder(title: "Research this passage", source: .note,
            locator: locator, quotedText: annotation.text, annotationID: annotation.id)
        reader.setAnnotations([annotation])
        XCTAssertTrue(wait { (self.evaluate(reader, "document.querySelectorAll('.reader-highlight-rect').length") as? Int ?? 0) > 0 })
        let originalRects = evaluate(reader, "JSON.stringify(Array.from(document.querySelectorAll('.reader-highlight-rect')).map(r=>[r.dataset.style,r.style.backgroundColor,r.dataset.hasNote||'']))") as? String

        reader.setReminders([reminder])
        XCTAssertTrue(wait { self.badgeCount(reader) == 1 })
        XCTAssertEqual(evaluate(reader, "JSON.stringify(Array.from(document.querySelectorAll('.reader-highlight-rect')).map(r=>[r.dataset.style,r.style.backgroundColor,r.dataset.hasNote||'']))") as? String, originalRects)
        reminder.completedAt = Date()
        reader.setReminders([reminder])
        XCTAssertTrue(wait { self.badgeCount(reader) == 0 })
        XCTAssertEqual(evaluate(reader, "JSON.stringify(Array.from(document.querySelectorAll('.reader-highlight-rect')).map(r=>[r.dataset.style,r.style.backgroundColor,r.dataset.hasNote||'']))") as? String, originalRects)
        reminder.completedAt = nil
        reader.setReminders([reminder])
        XCTAssertTrue(wait { self.badgeCount(reader) == 1 })
        reader.setAnnotations([])
        XCTAssertTrue(wait { self.badgeCount(reader) == 1 })
        XCTAssertEqual(evaluate(reader, "document.querySelectorAll('.reader-highlight-rect').length") as? Int, 0)
        _ = evaluate(reader, "__reader.setReminders([])")
        XCTAssertEqual(badgeCount(reader), 0)
    }

    func testQuoteRepairTypographyAndSidebarResizeKeepMarkerBesideItsPassage() throws {
        let reader = try makeReader()
        let locator = try firstPassage(in: reader)
        let broken = Locator(spineIndex: reader.spineIndex,
            start: TextPosition(elementPath: [999, 999], offset: 0),
            end: TextPosition(elementPath: [999, 999], offset: 40))
        let reminder = ResearchReminder(title: "Research later", locator: broken, quotedText: locator.text ?? "")
        reader.setReminders([reminder])
        XCTAssertTrue(wait { self.badgeIsBesidePassage(reader, locator: locator) })

        var settings = reader.settings
        settings.fontSize += 6
        settings.lineHeight += 0.2
        reader.settings = settings
        XCTAssertTrue(wait { self.badgeIsBesidePassage(reader, locator: locator) && self.badgesAvoidText(reader) })

        var pinned = false
        reader.beginWorkspaceRestore { pinned = true }
        XCTAssertTrue(wait { pinned })
        window?.setContentSize(NSSize(width: 820, height: 700))
        reader.updateViewport(width: 820, height: 700)
        XCTAssertTrue(wait { self.badgeIsBesidePassage(reader, locator: locator) && self.badgesAvoidText(reader) })
        reader.endWorkspaceRestore()
        window?.setContentSize(NSSize(width: 900, height: 700))
        reader.updateViewport(width: 900, height: 700)
        XCTAssertTrue(wait { self.badgeIsBesidePassage(reader, locator: locator) && self.badgesAvoidText(reader) })
    }

    func testValidButWrongLocatorRepairsFromQuoteAndMissingQuoteDoesNotPaint() throws {
        let reader = try makeReader()
        let locator = try firstPassage(in: reader)
        let wrong = Locator(spineIndex: reader.spineIndex,
            start: TextPosition(elementPath: locator.start.elementPath, offset: 80),
            end: TextPosition(elementPath: locator.start.elementPath, offset: 100))
        let reminder = ResearchReminder(title: "Repair this research topic", locator: wrong, quotedText: locator.text ?? "")
        reader.setReminders([reminder])
        XCTAssertTrue(wait { self.badgeIsBesidePassage(reader, locator: locator) })
        var missing = reminder
        missing.quotedText = "A research quote that is absent from this EPUB"
        reader.setReminders([missing])
        XCTAssertTrue(wait { self.badgeCount(reader) == 0 })
    }

    func testPointReminderAndGroupedPassagesHaveAccessibleKeyboardActions() throws {
        let reader = try makeReader()
        let locator = try firstPassage(in: reader)
        let point = Locator(spineIndex: reader.spineIndex, start: locator.start)
        let pageReminder = ResearchReminder(title: "Read more about this page", source: .page, locator: point)
        reader.setReminders([pageReminder])
        XCTAssertTrue(wait { self.badgeCount(reader) == 1 })
        XCTAssertTrue(badgesAvoidText(reader))

        let first = ResearchReminder(title: "Research allegories", locator: locator, quotedText: locator.text ?? "")
        let second = ResearchReminder(title: "Compare another interpretation", locator: locator, quotedText: locator.text ?? "")
        reader.setReminders([first, second])
        XCTAssertTrue(wait { self.badgeCount(reader) == 1 })
        XCTAssertEqual(evaluate(reader, "JSON.parse(document.querySelector('.reader-reminder-badge').dataset.reminderIds).length") as? Int, 2)
        XCTAssertEqual(evaluate(reader, "document.querySelector('.reader-reminder-count').textContent") as? String, "2")
        XCTAssertTrue((evaluate(reader, "document.querySelector('.reader-reminder-badge').title") as? String ?? "").contains(second.title))
        var activations = 0
        reader.onReminderActivated = { id, _ in XCTAssertEqual(id, first.id); activations += 1 }
        let page = reader.page
        _ = evaluate(reader, "document.querySelector('.reader-reminder-badge').focus({preventScroll:true})")
        XCTAssertTrue(wait { reader.isReminderBadgeFocused }, "Native page shortcuts must yield while a research action has keyboard focus")
        for key in ["Enter", " "] {
            let value = String(data: try JSONEncoder().encode(key), encoding: .utf8)!
            _ = evaluate(reader, "document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:\(value),bubbles:true,cancelable:true}))")
        }
        XCTAssertTrue(wait { activations == 2 })
        XCTAssertEqual(reader.page, page)
        _ = evaluate(reader, "__reader.setHighlights([])")
        XCTAssertEqual(badgeCount(reader), 1, "A highlight repaint must retain independent research markers")
        XCTAssertEqual(evaluate(reader, "document.activeElement.classList.contains('reader-reminder-badge')") as? Bool, true)
        reader.setReminders([])
        XCTAssertTrue(wait { self.badgeCount(reader) == 0 && !reader.isReminderBadgeFocused })
    }

    private func makeReader() throws -> ReaderController {
        let url = try CalibreFixture.writeEPUB()
        bookURL = url
        let book = try EPUBBook(fileURL: url)
        var settings = ReaderSettings()
        settings.animatePageTurns = false
        settings.twoPageSpread = false
        let reader = ReaderController(settings: settings)
        controller = reader
        let size = CGSize(width: 900, height: 700)
        let view = reader.makeWebView(for: book)
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        self.window = window
        reader.updateViewport(width: size.width, height: size.height)
        reader.start(at: nil, annotations: [])
        XCTAssertTrue(wait { !reader.isLoading })
        XCTAssertEqual(evaluate(reader, "typeof __reader.setReminders") as? String, "function")
        return reader
    }

    private func firstPassage(in reader: ReaderController) throws -> Locator {
        let raw = try XCTUnwrap(evaluate(reader, """
        (() => {
          const node = document.querySelector('p').firstChild, path = [];
          let current = node;
          while (current && current !== document.body) {
            path.unshift(Array.prototype.indexOf.call(current.parentNode.childNodes,current));
            current = current.parentNode;
          }
          return JSON.stringify({spineIndex:\(reader.spineIndex),start:{elementPath:path,offset:0},
            end:{elementPath:path,offset:56},text:node.textContent.slice(0,56)});
        })()
        """) as? String)
        return try JSONDecoder().decode(Locator.self, from: Data(raw.utf8))
    }

    private func selectPassage(_ reader: ReaderController, locator: Locator) {
        _ = evaluate(reader, """
        (() => {
          let node=document.body;
          for(const index of \(locator.start.elementPath)) node=node.childNodes[index];
          const range=document.createRange();range.setStart(node,\(locator.start.offset));range.setEnd(node,\(locator.end?.offset ?? locator.start.offset));
          const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
        })()
        """)
    }

    private func badgeCount(_ reader: ReaderController) -> Int {
        evaluate(reader, "document.querySelectorAll('.reader-reminder-badge').length") as? Int ?? -1
    }

    private func badgeIsBesidePassage(_ reader: ReaderController, locator: Locator) -> Bool {
        evaluate(reader, """
        (() => {
          const badge=document.querySelector('.reader-reminder-badge');if(!badge)return false;
          let node=document.body;for(const index of \(locator.start.elementPath))node=node.childNodes[index];
          const range=document.createRange();range.setStart(node,\(locator.start.offset));range.setEnd(node,\(locator.end?.offset ?? locator.start.offset + 1));
          const rects=Array.from(range.getClientRects()).filter(r=>r.width>0&&r.height>0);
          const text=rects[rects.length-1],mark=badge.getBoundingClientRect();
          return !!text&&Math.abs((text.top+text.bottom-mark.top-mark.bottom)/2)<1&&mark.width===22&&mark.height===22;
        })()
        """) as? Bool == true
    }

    private func badgesAvoidText(_ reader: ReaderController) -> Bool {
        evaluate(reader, """
        (() => {
          const layer=document.getElementById('reader-highlight-layer'),rects=[];
          const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;
          while((node=walker.nextNode())){
            if(layer.contains(node)||!node.textContent.trim())continue;
            const range=document.createRange();range.selectNodeContents(node);
            rects.push(...Array.from(range.getClientRects()).filter(r=>r.width>0&&r.height>0));
          }
          return Array.from(document.querySelectorAll('.reader-reminder-badge')).every(badge=>{
            const a=badge.getBoundingClientRect();return !rects.some(b=>a.left<b.right&&a.right>b.left&&a.top<b.bottom&&a.bottom>b.top);
          });
        })()
        """) as? Bool == true
    }

    private func passage(_ reader: ReaderController, locator: Locator) throws -> ReaderSurroundingPassage {
        var result: ReaderSurroundingPassage?
        reader.extractSurroundingPassage(from: locator) { result = $0 }
        XCTAssertTrue(wait { result != nil })
        return try XCTUnwrap(result)
    }

    private func evaluate(_ reader: ReaderController, _ script: String) -> Any? {
        var result: Any?, complete = false
        reader.evaluateForTesting(script) { result = $0; complete = true }
        XCTAssertTrue(wait { complete })
        return result
    }

    @discardableResult
    private func wait(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
