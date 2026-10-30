import AppKit
import EpubKit
import WebKit
import XCTest
@testable import ReaderUI

final class ReadingMarkerTests: XCTestCase {
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

    func testPlacementRequiresAnOpenReadyBook() {
        let reader = ReaderController()
        reader.toggleReadingMarkerPlacement()
        XCTAssertFalse(reader.isPlacingReadingMarker)
    }

    func testMarkerUsesClickedCharacterAndFollowsTypographyChanges() throws {
        let reader = try makeReader()
        var placed: Locator?
        reader.onReadingMarkerPlaced = { placed = $0 }
        reader.toggleReadingMarkerPlacement()
        XCTAssertTrue(reader.isPlacingReadingMarker)

        let expected = try XCTUnwrap(evaluate(reader, """
        (() => {
          const node = document.querySelector('p').firstChild;
          const range = document.createRange();
          range.setStart(node, 120); range.setEnd(node, 121);
          const rect = range.getBoundingClientRect();
          const x = rect.left + rect.width / 3, y = rect.top + rect.height / 2;
          const caret = document.caretRangeFromPoint(x, y);
          let current = caret.startContainer, path = [];
          while (current && current !== document.body) {
            path.unshift(Array.prototype.indexOf.call(current.parentNode.childNodes, current));
            current = current.parentNode;
          }
          document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('click', {
            bubbles: true, cancelable: true, clientX: x, clientY: y
          }));
          return { elementPath: path, offset: caret.startOffset };
        })()
        """) as? [String: Any])
        XCTAssertTrue(wait { placed != nil && !reader.isPlacingReadingMarker })
        let marker = try XCTUnwrap(placed)
        XCTAssertEqual(marker.start.elementPath, expected["elementPath"] as? [Int])
        XCTAssertEqual(marker.start.offset, expected["offset"] as? Int)
        XCTAssertEqual(reader.readingMarker, marker)
        XCTAssertTrue(marker.start.offset > 0, "Placement must keep the clicked text offset")
        XCTAssertTrue(markerIsAligned(reader))

        var settings = reader.settings
        settings.fontSize += 7
        settings.lineHeight += 0.3
        reader.settings = settings
        XCTAssertTrue(wait { self.markerIsAligned(reader) })
        reader.setAnnotations([])
        XCTAssertTrue(markerIsAligned(reader), "Refreshing highlights must preserve the marker")

        let original = reader.readingMarker
        reader.readingMarker = Locator(spineIndex: 999, start: marker.start)
        XCTAssertEqual(evaluate(reader, "document.querySelectorAll('#reader-reading-marker').length") as? Int, 0)
        reader.readingMarker = original
        XCTAssertTrue(markerIsAligned(reader))
        try captureSnapshot()
    }

    func testGutterDoesNotPlaceMarkerAndCancellationRestoresCursor() throws {
        let reader = try makeReader()
        reader.toggleReadingMarkerPlacement()
        _ = evaluate(reader, """
        document.body.dispatchEvent(new MouseEvent('click', {
          bubbles: true, cancelable: true, clientX: 2, clientY: 2
        }))
        """)
        XCTAssertNil(reader.readingMarker)
        XCTAssertTrue(reader.isPlacingReadingMarker)
        reader.cancelReadingMarkerPlacement()
        XCTAssertFalse(reader.isPlacingReadingMarker)
        XCTAssertEqual(evaluate(reader, "document.documentElement.classList.contains('reader-placing-marker')") as? Bool, false)
    }

    func testNativeShortcutMarksHighlightedTextAndReturnsAfterPageTurn() throws {
        let reader = try makeReader()
        let window = try XCTUnwrap(window)
        let monitor = PageTurnKeyMonitor.MonitorView()
        monitor.controller = reader
        window.contentView?.addSubview(monitor)
        defer { monitor.tearDown(); monitor.removeFromSuperview() }
        window.makeFirstResponder(window.contentView)

        var settings = reader.settings
        settings.animatePageTurns = false
        reader.settings = settings
        let raw = try XCTUnwrap(evaluate(reader, """
        (() => {
          let node = document.querySelector('p').firstChild, path = [], current = node;
          while (current && current !== document.body) {
            path.unshift(Array.prototype.indexOf.call(current.parentNode.childNodes, current));
            current = current.parentNode;
          }
          return { path: path, text: node.textContent.slice(90, 155) };
        })()
        """) as? [String: Any])
        let path = try XCTUnwrap(raw["path"] as? [Int])
        let annotation = Annotation(locator: Locator(
            spineIndex: 0, start: TextPosition(elementPath: path, offset: 90),
            end: TextPosition(elementPath: path, offset: 155)
        ), text: try XCTUnwrap(raw["text"] as? String), color: .yellow)
        reader.setAnnotations([annotation])
        XCTAssertTrue(wait {
            (self.evaluate(reader, "document.querySelectorAll('.reader-highlight-rect').length") as? Int ?? 0) > 0
        })
        var activatedHighlights = 0
        reader.onHighlightActivated = { _, _ in activatedHighlights += 1 }

        XCTAssertNil(monitor.keyEventHandler(try keyEvent(46, characters: "m", in: window)))
        XCTAssertTrue(reader.isPlacingReadingMarker)
        _ = evaluate(reader, """
        (() => {
          const node = document.querySelector('p').firstChild, range = document.createRange();
          range.setStart(node, 120); range.setEnd(node, 121);
          const rect = range.getBoundingClientRect(), x = rect.left + rect.width / 3, y = rect.top + rect.height / 2;
          document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('click', {
            bubbles: true, cancelable: true, clientX: x, clientY: y
          }));
        })()
        """)
        XCTAssertTrue(wait { reader.readingMarker != nil && !reader.isPlacingReadingMarker })
        let marker = reader.readingMarker
        XCTAssertEqual(activatedHighlights, 0, "Placement clicks must not also activate highlight notes")
        XCTAssertTrue(markerIsAligned(reader))

        XCTAssertNil(monitor.keyEventHandler(try keyEvent(124, in: window)))
        XCTAssertTrue(wait { reader.page > 0 })
        XCTAssertFalse(markerIsAligned(reader), "A marker on a prior page must not appear on the current one")
        XCTAssertNil(monitor.keyEventHandler(try keyEvent(46, characters: "m", modifiers: .shift, in: window)))
        XCTAssertTrue(wait { reader.page == 0 && self.markerIsAligned(reader) })
        XCTAssertEqual(reader.readingMarker, marker)

        XCTAssertNil(monitor.keyEventHandler(try keyEvent(46, characters: "m", in: window)))
        XCTAssertTrue(reader.isPlacingReadingMarker)
        XCTAssertNil(monitor.keyEventHandler(try keyEvent(53, in: window)))
        XCTAssertFalse(reader.isPlacingReadingMarker)
    }

    func testDirectClickMarksWrappedLineAndRightColumnWithoutShortcut() throws {
        let reader = try makeReader(size: CGSize(width: 1400, height: 700))
        XCTAssertFalse(reader.isPlacingReadingMarker)
        for column in [0, 1] {
            let hit = try lineStart(in: reader, column: column)
            XCTAssertGreaterThan(hit.offset, 0, "Fixture must exercise a wrapped continuation line")
            click(reader, x: hit.x, y: hit.y)
            XCTAssertTrue(wait { reader.readingMarker?.start == TextPosition(elementPath: hit.path, offset: hit.offset) })
            let marker = try XCTUnwrap(reader.readingMarker)
            XCTAssertEqual(marker.start.offset, hit.offset)
            XCTAssertFalse(reader.isPlacingReadingMarker)
            XCTAssertTrue(markerIsAligned(reader))
        }
    }

    func testDirectLineStartClickPreservesOrdinaryTextLinksAndSelectionGestures() throws {
        let reader = try makeReader()
        _ = evaluate(reader, """
        (() => {
          const paragraph = document.querySelector('p');
          paragraph.style.textIndent = '0';
          paragraph.innerHTML = 'Opening words before <em id="inline-fragment">the emphasized fragment</em> and <a id="line-link" href="https://example.com/marker-test">a normal link</a>. ' + 'More ordinary reading text follows. '.repeat(20);
        })()
        """)
        let fragment = try XCTUnwrap(evaluate(reader, """
        (() => {
          const rect = document.getElementById('inline-fragment').getBoundingClientRect();
          return { x: rect.left - 5, y: rect.top + rect.height / 2 };
        })()
        """) as? [String: Double])
        hover(reader, x: try XCTUnwrap(fragment["x"]), y: try XCTUnwrap(fragment["y"]))
        XCTAssertFalse(cueExists(reader), "An inline text fragment is not a new visual line")
        click(reader, x: try XCTUnwrap(fragment["x"]), y: try XCTUnwrap(fragment["y"]))
        XCTAssertNil(reader.readingMarker, "Ordinary text clicks must remain ordinary text clicks")

        var openedURL: URL?
        reader.onExternalLink = { openedURL = $0 }
        let link = try XCTUnwrap(evaluate(reader, """
        (() => {
          const rect = document.getElementById('line-link').getBoundingClientRect();
          return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
        })()
        """) as? [String: Double])
        click(reader, x: try XCTUnwrap(link["x"]), y: try XCTUnwrap(link["y"]))
        XCTAssertTrue(wait { openedURL != nil })
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/marker-test")
        XCTAssertNil(reader.readingMarker)

        let hit = try lineStart(in: reader)
        click(reader, x: hit.x, y: hit.y, detail: 2)
        XCTAssertNil(reader.readingMarker, "Double clicks must preserve word selection")
        click(reader, x: hit.x, y: hit.y, shiftKey: true)
        XCTAssertNil(reader.readingMarker, "Shift-click must preserve selection extension")
        _ = evaluate(reader, """
        (() => {
          const x = \(hit.x), y = \(hit.y), target = document.elementFromPoint(x, y);
          target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, clientX: x + 45, clientY: y, button: 0, buttons: 1, detail: 1 }));
          target.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons: 1 }));
          target.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons: 0, detail: 1 }));
          target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons: 0, detail: 1 }));
        })()
        """)
        XCTAssertNil(reader.readingMarker, "Finishing a drag at a line start must not save a marker")

        _ = evaluate(reader, """
        (() => {
          const range = document.createRange(), node = document.querySelector('p').firstChild;
          range.setStart(node, 0); range.setEnd(node, 7);
          const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        })()
        """)
        click(reader, x: hit.x, y: hit.y)
        XCTAssertNil(reader.readingMarker, "A text selection must not turn into a marker")
        XCTAssertEqual(evaluate(reader, "window.getSelection().toString()") as? String, "Opening")
    }

    func testDirectLineStartClickWorksBesideHighlightedTextWithoutOpeningNote() throws {
        let reader = try makeReader()
        let hit = try lineStart(in: reader)
        let text = try XCTUnwrap(evaluate(reader, """
        ((path, offset) => {
          let node = document.body; for (const index of path) node = node.childNodes[index];
          return node.textContent.slice(offset, offset + 20);
        })(\(hit.path), \(hit.offset))
        """) as? String)
        reader.setAnnotations([Annotation(locator: Locator(
            spineIndex: 0,
            start: TextPosition(elementPath: hit.path, offset: hit.offset),
            end: TextPosition(elementPath: hit.path, offset: hit.offset + 20)
        ), text: text)])
        XCTAssertTrue(wait {
            (self.evaluate(reader, "document.querySelectorAll('.reader-highlight-rect').length") as? Int ?? 0) > 0
        })
        var activations = 0
        reader.onHighlightActivated = { _, _ in activations += 1 }
        click(reader, x: hit.x, y: hit.y)
        XCTAssertTrue(wait { reader.readingMarker != nil })
        XCTAssertEqual(reader.readingMarker?.start, TextPosition(elementPath: hit.path, offset: hit.offset))
        XCTAssertEqual(activations, 0)
        XCTAssertTrue(markerIsAligned(reader))
        let saved = reader.readingMarker
        let highlightedWord = try XCTUnwrap(evaluate(reader, """
        ((path, offset) => {
          let node = document.body; for (const index of path) node = node.childNodes[index];
          const range = document.createRange(); range.setStart(node, offset + 10); range.setEnd(node, offset + 11);
          const rect = range.getBoundingClientRect();
          return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
        })(\(hit.path), \(hit.offset))
        """) as? [String: Double])
        click(reader, x: try XCTUnwrap(highlightedWord["x"]), y: try XCTUnwrap(highlightedWord["y"]))
        XCTAssertTrue(wait { activations == 1 }, "Highlight clicks away from a line start must still open notes")
        XCTAssertEqual(reader.readingMarker, saved)
    }

    func testFirstGlyphSingleClickEventuallySavesMarker() throws {
        let reader = try makeReader()
        let hit = try lineStart(in: reader)
        click(reader, x: hit.glyphX, y: hit.y)
        XCTAssertTrue(wait(timeout: max(2, NSEvent.doubleClickInterval + 0.5)) {
            reader.readingMarker?.start == TextPosition(elementPath: hit.path, offset: hit.offset)
        })
        XCTAssertFalse(reader.isPlacingReadingMarker)
        XCTAssertTrue(markerIsAligned(reader))
    }

    func testFirstGlyphDoubleClickSelectsWordWithoutMovingMarker() throws {
        let reader = try makeReader()
        let hit = try lineStart(in: reader)
        let saved = Locator(spineIndex: 0, start: TextPosition(elementPath: hit.path, offset: hit.offset + 25))
        reader.readingMarker = saved

        // A real double click includes an initial ordinary click. Sending only
        // detail=2 would miss a marker incorrectly committed by that first click.
        click(reader, x: hit.glyphX, y: hit.y)
        let selectedWord = try XCTUnwrap(evaluate(reader, """
        ((path, offset) => {
          const x = \(hit.glyphX), y = \(hit.y), target = document.elementFromPoint(x, y);
          target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons: 1, detail: 2 }));
          let node = document.body; for (const index of path) node = node.childNodes[index];
          const word = node.textContent.slice(offset).match(/^\\S+/)[0];
          const range = document.createRange(); range.setStart(node, offset); range.setEnd(node, offset + word.length);
          const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
          for (const type of ['mouseup', 'click', 'dblclick']) {
            target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons: 0, detail: 2 }));
          }
          return word;
        })(\(hit.path), \(hit.offset))
        """) as? String)
        _ = wait(timeout: max(0.7, NSEvent.doubleClickInterval + 0.2)) { false }
        XCTAssertEqual(reader.readingMarker, saved)
        XCTAssertEqual(evaluate(reader, "window.getSelection().toString()") as? String, selectedWord)
    }

    func testDismissingSelectionAtFirstGlyphDoesNotMoveMarker() throws {
        let reader = try makeReader()
        let hit = try lineStart(in: reader)
        let saved = Locator(spineIndex: 0, start: TextPosition(elementPath: hit.path, offset: hit.offset + 25))
        reader.readingMarker = saved
        _ = evaluate(reader, """
        ((path, offset) => {
          let node = document.body; for (const index of path) node = node.childNodes[index];
          const range = document.createRange(); range.setStart(node, offset + 2); range.setEnd(node, offset + 10);
          const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
          const x = \(hit.glyphX), y = \(hit.y), target = document.elementFromPoint(x, y);
          target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons: 1, detail: 1 }));
          // Trusted mousedown collapses a selection before mouseup/click.
          // Synthetic events need that browser default reproduced explicitly.
          selection.collapse(node, offset);
          for (const type of ['mouseup', 'click']) {
            target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons: 0, detail: 1 }));
          }
        })(\(hit.path), \(hit.offset))
        """)
        _ = wait(timeout: max(0.7, NSEvent.doubleClickInterval + 0.2)) { false }
        XCTAssertEqual(reader.readingMarker, saved)
        XCTAssertEqual(evaluate(reader, "window.getSelection().isCollapsed") as? Bool, true)
    }

    func testLineStartHoverCueClearsForSelectionModeLayoutAndPaging() throws {
        let reader = try makeReader()
        var hit = try lineStart(in: reader)
        hover(reader, x: hit.x, y: hit.y)
        XCTAssertTrue(wait { self.cueExists(reader) })
        XCTAssertEqual(evaluate(reader, "getComputedStyle(document.getElementById('reader-reading-marker-cue')).pointerEvents") as? String, "none")
        XCTAssertNil(reader.readingMarker, "Hovering must never save a marker")

        hover(reader, x: 2, y: 2)
        XCTAssertTrue(wait { !self.cueExists(reader) }, "The cue must disappear away from the line-start target")
        hover(reader, x: hit.x, y: hit.y)
        XCTAssertTrue(wait { self.cueExists(reader) })
        reader.toggleReadingMarkerPlacement()
        XCTAssertTrue(wait { !self.cueExists(reader) })
        reader.cancelReadingMarkerPlacement()

        hover(reader, x: hit.x, y: hit.y)
        XCTAssertTrue(wait { self.cueExists(reader) })
        _ = evaluate(reader, """
        (() => {
          const node = document.querySelector('p').firstChild, range = document.createRange();
          range.setStart(node, 4); range.setEnd(node, 15);
          const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
          document.dispatchEvent(new Event('selectionchange'));
        })()
        """)
        XCTAssertTrue(wait { !self.cueExists(reader) })
        reader.clearSelection()

        hover(reader, x: hit.x, y: hit.y)
        XCTAssertTrue(wait { self.cueExists(reader) })
        var settings = reader.settings
        settings.fontSize += 3
        settings.animatePageTurns = false
        reader.settings = settings
        XCTAssertTrue(wait { !self.cueExists(reader) })
        hit = try lineStart(in: reader)
        hover(reader, x: hit.x, y: hit.y)
        XCTAssertTrue(wait { self.cueExists(reader) })
        reader.nextPage()
        XCTAssertTrue(wait { reader.page > 0 && !self.cueExists(reader) })
        XCTAssertNil(reader.readingMarker)
    }

    func testEveryVisualLineAtNarrowWidthCanBeHoveredAndMarked() throws {
        try assertEveryHyphenatedLineCanBeMarked(width: 420)
    }

    func testEveryVisualLineAtMediumWidthCanBeHoveredAndMarked() throws {
        try assertEveryHyphenatedLineCanBeMarked(width: 540, plainPassage: true)
    }

    func testWideFirstGlyphCentersCanBeHoveredAndMarked() throws {
        let reader = try makeReader(size: CGSize(width: 540, height: 700), fontSize: 32)
        _ = evaluate(reader, """
        (() => {
          const paragraph = document.querySelector('p');
          paragraph.id = 'marker-regression'; paragraph.style.textIndent = '0';
          paragraph.innerHTML = 'Widespread appearances.<br/>Mighty heroes continue.';
        })()
        """)
        _ = wait(timeout: 0.2) { false }
        let lines = try allVisibleLineStarts(in: reader)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let x = try XCTUnwrap(line["glyphCenterX"] as? Double)
            let y = try XCTUnwrap(line["y"] as? Double)
            let left = try XCTUnwrap(line["left"] as? Double)
            XCTAssertGreaterThan(x - left, 8, "Fixture must click beyond the previous fixed 8px band")
            let expected = TextPosition(
                elementPath: try XCTUnwrap(line["path"] as? [Int]),
                offset: try XCTUnwrap(line["offset"] as? Int)
            )
            hover(reader, x: x, y: y)
            XCTAssertTrue(wait(timeout: 0.4) { self.cueIsAtLine(reader, y: y) }, "Missing cue at wide glyph: \(line)")
            click(reader, x: x, y: y)
            XCTAssertTrue(wait(timeout: max(2, NSEvent.doubleClickInterval + 0.5)) {
                reader.readingMarker?.start == expected
            }, "Wide first-glyph center did not mark its line: \(line)")
            XCTAssertTrue(wait(timeout: 0.3) { self.savedMarkerIsAtLine(reader, y: y) },
                          "Saved flag must align with the actual wide glyph: \(line)")
        }
    }

    func testMPlacementWorksAtEveryHyphenatedFirstGlyph() throws {
        let reader = try makeHyphenatedReader(width: 540, plainPassage: true)
        let lines = try allVisibleLineStarts(in: reader).filter { line in
            guard let rects = line["firstGlyphRects"] as? [[String: Double]] else { return false }
            return rects.count > 1 && rects.contains { ($0["width"] ?? 0) == 0 }
        }
        XCTAssertFalse(lines.isEmpty, "Fixture must include a hyphenated first glyph with a prior-line zero-width fragment")
        for line in lines {
            let x = try XCTUnwrap(line["glyphCenterX"] as? Double)
            let y = try XCTUnwrap(line["y"] as? Double)
            let expected = TextPosition(
                elementPath: try XCTUnwrap(line["path"] as? [Int]),
                offset: try XCTUnwrap(line["offset"] as? Int)
            )
            reader.toggleReadingMarkerPlacement()
            XCTAssertTrue(reader.isPlacingReadingMarker)
            click(reader, x: x, y: y)
            XCTAssertTrue(wait(timeout: 0.5) { reader.readingMarker?.start == expected },
                          "M placement failed at a hyphenated first glyph: \(line)")
            XCTAssertFalse(reader.isPlacingReadingMarker)
            XCTAssertTrue(wait(timeout: 0.3) { self.savedMarkerIsAtLine(reader, y: y) },
                          "M placement flag must align with the actual glyph: \(line)")
        }
    }

    func testShiftMReturnsToHyphenatedColumnBoundary() throws {
        let reader = try makeReader(size: CGSize(width: 540, height: 780), fontSize: 26)
        _ = evaluate(reader, """
        (() => {
          document.documentElement.lang = 'en';
          const paragraph = document.querySelector('p');
          paragraph.id = 'marker-regression'; paragraph.style.textIndent = '0';
          paragraph.textContent = 'extra\\u00adordi\\u00adnary\\u00adap\\u00adpear\\u00adances\\u00adhe\\u00adroes\\u00ad'.repeat(60);
        })()
        """)
        _ = wait(timeout: 0.25) { false }
        let boundary = try XCTUnwrap(evaluate(reader, """
        (() => {
          const node = document.getElementById('marker-regression').firstChild, width = window.innerWidth;
          let best = null;
          for (let offset = 0; offset < node.length; offset++) {
            if (node.textContent[offset] === '\\u00ad') continue;
            const range = document.createRange(); range.setStart(node, offset); range.setEnd(node, offset + 1);
            for (const rect of Array.from(range.getClientRects())) {
              if (rect.width <= 0 || rect.height <= 0 || rect.left < width || rect.left >= 2 * width) continue;
              if (!best || rect.top < best.top - 1 || (Math.abs(rect.top - best.top) < 1 && rect.left < best.left)) {
                const caret = document.createRange(); caret.setStart(node, offset); caret.collapse(true);
                const caretRect = caret.getBoundingClientRect();
                let current = node, path = [];
                while (current && current !== document.body) {
                  path.unshift(Array.prototype.indexOf.call(current.parentNode.childNodes, current));
                  current = current.parentNode;
                }
                best = { path: path, offset: offset, top: rect.top, left: rect.left,
                  x: rect.left - width + rect.width / 3, y: rect.top + rect.height / 2,
                  afterSoftHyphen: node.textContent[offset - 1] === '\\u00ad',
                  caretLeft: caretRect.left, caretTop: caretRect.top,
                  fragments: Array.from(range.getClientRects()).map(part => ({
                    left: part.left, top: part.top, width: part.width, height: part.height
                  })) };
              }
            }
          }
          __reader.state();
          return best;
        })()
        """) as? [String: Any], "Fixture must continue into a second CSS column")
        XCTAssertEqual(boundary["afterSoftHyphen"] as? Bool, true, "Column must begin after a discretionary hyphen: \(boundary)")
        let expected = TextPosition(
            elementPath: try XCTUnwrap(boundary["path"] as? [Int]),
            offset: try XCTUnwrap(boundary["offset"] as? Int)
        )
        let x = try XCTUnwrap(boundary["x"] as? Double)
        let y = try XCTUnwrap(boundary["y"] as? Double)
        _ = evaluate(reader, "__reader.goToPage(1, false)")
        XCTAssertTrue(wait { reader.page == 1 })
        reader.toggleReadingMarkerPlacement()
        click(reader, x: x, y: y)
        XCTAssertTrue(wait(timeout: 0.5) { reader.readingMarker?.start == expected }, "Boundary M placement failed: \(boundary)")
        XCTAssertTrue(savedMarkerIsAtLine(reader, y: y))

        _ = evaluate(reader, "__reader.goToPage(2, false)")
        XCTAssertTrue(wait { reader.page == 2 })
        let window = try XCTUnwrap(window)
        let monitor = PageTurnKeyMonitor.MonitorView()
        monitor.controller = reader
        window.contentView?.addSubview(monitor)
        defer { monitor.tearDown(); monitor.removeFromSuperview() }
        window.makeFirstResponder(window.contentView)
        XCTAssertNil(monitor.keyEventHandler(try keyEvent(46, characters: "m", modifiers: .shift, in: window)))
        XCTAssertTrue(wait(timeout: 2) { reader.page == 1 }, "Shift+M must use the glyph's column, not prior-column caret affinity: \(boundary)")
        XCTAssertTrue(savedMarkerIsAtLine(reader, y: y))
    }

    private func makeHyphenatedReader(width: CGFloat, plainPassage: Bool = false) throws -> ReaderController {
        let reader = try makeReader(size: CGSize(width: width, height: 780), fontSize: 26)
        _ = evaluate(reader, """
        (() => {
          document.documentElement.lang = 'en';
          const paragraph = document.querySelector('p');
          paragraph.id = 'marker-regression'; paragraph.style.textIndent = '0';
          if (\(plainPassage)) {
            paragraph.textContent = 'Greatness appeals to the future. If today I can be firm enough to do right and disregard watching eyes, I must have done enough right before to defend me now. However that may be, do right now. Always disregard appearances, and you will always be able to do what is right. Strength of character builds up over time. All the past days of virtue contribute their health to this one. What gives the heroes of the senate and the battlefield that majesty which so fills the imagination? '.repeat(3);
          } else {
            paragraph.innerHTML = ('<span>Appear\\u00adances and </span><em>he\\u00adroes</em><span> are extraordinary manifestations of independent character. We recognize their responsibilities and possibilities in every circumstance. </span>').repeat(12);
          }
        })()
        """)
        _ = wait(timeout: 0.25) { false }
        return reader
    }

    private func assertEveryHyphenatedLineCanBeMarked(width: CGFloat, plainPassage: Bool = false) throws {
        let reader = try makeHyphenatedReader(width: width, plainPassage: plainPassage)
        let lines = try allVisibleLineStarts(in: reader)
        XCTAssertGreaterThan(lines.count, 8, "Fixture must exercise many independently chosen lines")
        XCTAssertTrue(lines.contains { $0["continuesWord"] as? Bool == true }, "Fixture must include a wrapped or hyphenated word")
        var failures: [String] = []
        for (index, line) in lines.enumerated() {
            let x = try XCTUnwrap(line["gutterX"] as? Double)
            let y = try XCTUnwrap(line["y"] as? Double)
            let expected = TextPosition(
                elementPath: try XCTUnwrap(line["path"] as? [Int]),
                offset: try XCTUnwrap(line["offset"] as? Int)
            )
            hover(reader, x: x, y: y)
            if !wait(timeout: 0.3, { self.cueIsAtLine(reader, y: y) }) {
                failures.append("Line \(index) has no hover cue: \(line)")
            }
            click(reader, x: x, y: y)
            if !wait(timeout: 0.3, { reader.readingMarker?.start == expected }) {
                failures.append("Line \(index) did not mark its first visible character: \(line); actual=\(String(describing: reader.readingMarker?.start))")
            }
            if !wait(timeout: 0.3, { self.savedMarkerIsAtLine(reader, y: y) }) {
                failures.append("Line \(index) saved flag is not aligned with its first visible glyph: \(line)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "Line-start failures at width \(width):\n" + failures.joined(separator: "\n"))
    }

    /// Derive every visible line from actual character rectangles. Unlike the
    /// original helper, this never skips a line because its caret or full-node
    /// rectangle disagrees with its first glyph at a discretionary hyphen.
    private func allVisibleLineStarts(in reader: ReaderController) throws -> [[String: Any]] {
        try XCTUnwrap(evaluate(reader, """
        (() => {
          const paragraph = document.getElementById('marker-regression');
          const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT), lines = [];
          let node;
          function pathOf(node) {
            const path = []; let current = node;
            while (current && current !== document.body) {
              path.unshift(Array.prototype.indexOf.call(current.parentNode.childNodes, current));
              current = current.parentNode;
            }
            return path;
          }
          function caretAt(x, y) {
            const caret = document.caretRangeFromPoint(x, y);
            if (!caret) return null;
            const node = caret.startContainer, offset = caret.startOffset;
            let glyph = null;
            if (node.nodeType === Node.TEXT_NODE && node.length) {
              const range = document.createRange(), start = Math.min(offset, node.length - 1);
              range.setStart(node, start); range.setEnd(node, start + 1);
              const rect = range.getBoundingClientRect();
              glyph = { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
            }
            return { path: pathOf(node), offset: offset, type: node.nodeType,
              nearby: node.textContent.slice(Math.max(0, offset - 8), offset + 20), glyph: glyph };
          }
          while ((node = walker.nextNode())) {
            for (let offset = 0; offset < node.length; offset++) {
              if (/[\\s\\u00ad\\u200b]/.test(node.textContent[offset])) continue;
              const range = document.createRange(); range.setStart(node, offset); range.setEnd(node, offset + 1);
              for (const rect of Array.from(range.getClientRects())) {
                if (rect.width <= 0 || rect.height <= 0 || rect.left < 0 || rect.right > window.innerWidth ||
                    rect.top < 0 || rect.bottom > window.innerHeight) continue;
                const y = rect.top + rect.height / 2;
                let line = lines.find(candidate => Math.abs(candidate.y - y) < 2);
                if (!line) {
                  line = { left: Infinity, y: y }; lines.push(line);
                }
                if (rect.left < line.left - 0.1) {
                  Object.assign(line, { left: rect.left, y: y, top: rect.top,
                    gutterX: rect.left - 8, glyphCenterX: rect.left + rect.width / 2,
                    path: pathOf(node), offset: offset, snippet: node.textContent.slice(offset, offset + 50),
                    firstGlyphRects: Array.from(range.getClientRects()).map(part => ({
                      left: part.left, top: part.top, width: part.width, height: part.height
                    })),
                    continuesWord: offset > 0 && /[A-Za-z\\u00ad]/.test(node.textContent[offset - 1]) && /[A-Za-z]/.test(node.textContent[offset]) });
                }
              }
            }
          }
          return lines.sort((a, b) => a.y - b.y).map(line => Object.assign(line, {
            gutterCaret: caretAt(line.gutterX, line.y), leadingCaret: caretAt(line.left + 0.5, line.y)
          }));
        })()
        """) as? [[String: Any]])
    }

    private func cueIsAtLine(_ reader: ReaderController, y: Double) -> Bool {
        evaluate(reader, """
        (() => {
          const cue = document.getElementById('reader-reading-marker-cue');
          if (!cue) return false;
          const rect = cue.getBoundingClientRect();
          return Math.abs(rect.top + rect.height / 2 - \(y)) < 2;
        })()
        """) as? Bool == true
    }

    private func savedMarkerIsAtLine(_ reader: ReaderController, y: Double) -> Bool {
        evaluate(reader, """
        (() => {
          const marker = document.getElementById('reader-reading-marker');
          if (!marker) return false;
          const rect = marker.getBoundingClientRect();
          return Math.abs(rect.top + rect.height / 2 - \(y)) < 2;
        })()
        """) as? Bool == true
    }

    private struct LineStartHit {
        let x: Double
        let glyphX: Double
        let y: Double
        let path: [Int]
        let offset: Int
    }

    private func lineStart(in reader: ReaderController, column: Int = 0) throws -> LineStartHit {
        let raw = try XCTUnwrap(evaluate(reader, """
        (() => {
          const width = window.innerWidth / __reader.state().columns;
          for (const paragraph of document.querySelectorAll('p')) {
            const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
              const range = document.createRange(); range.selectNodeContents(node);
              const rects = Array.from(range.getClientRects());
              for (let r = 1; r < rects.length; r++) {
                const rect = rects[r];
                if (rect.width < 10 || rect.top < 0 || rect.bottom > window.innerHeight ||
                    rect.left < \(column) * width || rect.left >= (\(column) + 1) * width) continue;
                for (let offset = 1; offset < node.textContent.length; offset++) {
                  if (/\\s/.test(node.textContent[offset])) continue;
                  const character = document.createRange(); character.setStart(node, offset); character.setEnd(node, offset + 1);
                  const glyph = character.getBoundingClientRect();
                  if (glyph.width <= 0 || Math.abs(glyph.top - rect.top) > 1 || Math.abs(glyph.left - rect.left) > 1) continue;
                  let current = node, path = [];
                  while (current && current !== document.body) {
                    path.unshift(Array.prototype.indexOf.call(current.parentNode.childNodes, current));
                    current = current.parentNode;
                  }
                  return { x: rect.left - 8, glyphX: glyph.left + Math.min(1, glyph.width / 3), y: glyph.top + glyph.height / 2, path: path, offset: offset };
                }
              }
            }
          }
          return null;
        })()
        """) as? [String: Any], "Fixture must contain a visible wrapped line in column \(column)")
        return LineStartHit(
            x: try XCTUnwrap(raw["x"] as? Double),
            glyphX: try XCTUnwrap(raw["glyphX"] as? Double),
            y: try XCTUnwrap(raw["y"] as? Double),
            path: try XCTUnwrap(raw["path"] as? [Int]),
            offset: try XCTUnwrap(raw["offset"] as? Int)
        )
    }

    private func click(_ reader: ReaderController, x: Double, y: Double, detail: Int = 1, shiftKey: Bool = false) {
        _ = evaluate(reader, """
        (() => {
          const x = \(x), y = \(y), target = document.elementFromPoint(x, y);
          for (const type of ['mousedown', 'mouseup', 'click']) {
            target.dispatchEvent(new MouseEvent(type, {
              bubbles: true, cancelable: true, clientX: x, clientY: y,
              button: 0, buttons: type === 'mousedown' ? 1 : 0,
              detail: \(detail), shiftKey: \(shiftKey)
            }));
          }
        })()
        """)
    }

    private func hover(_ reader: ReaderController, x: Double, y: Double) {
        _ = evaluate(reader, """
        document.elementFromPoint(\(x), \(y)).dispatchEvent(new MouseEvent('mousemove', {
          bubbles: true, cancelable: true, clientX: \(x), clientY: \(y), buttons: 0
        }))
        """)
    }

    private func cueExists(_ reader: ReaderController) -> Bool {
        evaluate(reader, "document.getElementById('reader-reading-marker-cue') !== null") as? Bool == true
    }

    private func makeReader(size: CGSize = CGSize(width: 900, height: 700), fontSize: Double = 19) throws -> ReaderController {
        let url = try CalibreFixture.writeEPUB()
        bookURL = url
        let book = try EPUBBook(fileURL: url)
        var settings = ReaderSettings()
        settings.animatePageTurns = false
        settings.fontSize = fontSize
        let reader = ReaderController(settings: settings)
        controller = reader
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
        return reader
    }

    private func markerIsAligned(_ reader: ReaderController) -> Bool {
        guard let marker = reader.readingMarker,
              let data = try? JSONEncoder().encode(marker.start),
              let position = String(data: data, encoding: .utf8)
        else { return false }
        return evaluate(reader, """
        ((position) => {
          const marker = document.getElementById('reader-reading-marker');
          if (!marker) return false;
          let node = document.body;
          for (const index of position.elementPath) node = node.childNodes[index];
          const range = document.createRange();
          range.setStart(node, position.offset); range.setEnd(node, position.offset + 1);
          const text = range.getBoundingClientRect(), flag = marker.getBoundingClientRect();
          return Math.abs((flag.top + flag.height / 2) - (text.top + text.height / 2)) < 1
            && flag.width > 0 && flag.right < text.left && flag.top >= 0
            && flag.right > 0 && flag.left < window.innerWidth;
        })(\(position))
        """) as? Bool == true
    }

    private func evaluate(_ reader: ReaderController, _ script: String) -> Any? {
        var result: Any?
        var completed = false
        reader.evaluateForTesting(script) { result = $0; completed = true }
        XCTAssertTrue(wait { completed })
        return result
    }

    private func keyEvent(
        _ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    private func captureSnapshot() throws {
        guard let webView = window?.contentView as? WKWebView else { return }
        var snapshot: NSImage?
        webView.takeSnapshot(with: nil) { image, _ in snapshot = image }
        XCTAssertTrue(wait { snapshot != nil })
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(snapshot?.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/kodi-reading-marker.png"))
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
