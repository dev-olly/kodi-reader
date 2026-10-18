import AppKit
import CoreText
import EpubKit
import PDFKit
import XCTest
@testable import ReaderUI

final class PDFReaderTests: XCTestCase {
    private var window: NSWindow?
    private var controller: ReaderController?
    private var pdfURL: URL?

    override func tearDown() {
        controller?.tearDown()
        window?.contentView = nil
        window?.orderOut(nil)
        if let pdfURL { try? FileManager.default.removeItem(at: pdfURL) }
        super.tearDown()
    }

    func testNavigationSelectionAndTransientHighlights() throws {
        let (reader, book, view) = try makeReader()
        var reported: Locator?
        reader.onPositionChanged = { reported = $0 }
        reader.start(at: .pdfPage(1), annotations: [])

        XCTAssertEqual(reader.spineIndex, 1)
        XCTAssertEqual(reader.pageCount, 3)
        XCTAssertEqual(reported?.kind, .pdf)

        reader.nextPage()
        XCTAssertEqual(reader.spineIndex, 2)
        reader.previousPage()
        XCTAssertEqual(reader.spineIndex, 1)

        let page = try XCTUnwrap(book.document.page(at: 1))
        let pdfSelection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
        view.setCurrentSelection(pdfSelection, animate: false)
        spinRunLoop()
        let selection = try XCTUnwrap(reader.selection)
        XCTAssertEqual(selection.locator.kind, .pdf)
        XCTAssertEqual(selection.locator.spineIndex, 1)
        XCTAssertFalse(selection.locator.pdfRanges?.isEmpty ?? true)

        var passage: ReaderSurroundingPassage?
        reader.extractSurroundingPassage(from: selection.locator) { passage = $0 }
        XCTAssertEqual(passage?.quote, selection.text)
        XCTAssertTrue(passage?.after.contains("selectable text") == true)

        let annotation = Annotation(
            locator: selection.locator,
            text: selection.text,
            color: .yellow
        )
        reader.setAnnotations([annotation])
        XCTAssertTrue(page.annotations.contains { $0.userName == "kodi:\(annotation.id.uuidString)" })

        reader.setAnnotations([])
        XCTAssertFalse(page.annotations.contains { $0.userName == "kodi:\(annotation.id.uuidString)" })
    }

    func testAdaptiveSpreadMode() throws {
        let (reader, _, view) = try makeReader()
        reader.start(at: nil, annotations: [])
        reader.updateViewport(width: 900, height: 700)
        XCTAssertEqual(view.displayMode, .singlePage)

        reader.updateViewport(width: 1_200, height: 700)
        XCTAssertEqual(view.displayMode, .twoUp)
        XCTAssertTrue(view.displaysAsBook)
    }

    func testReadingMarkerUsesClickedPDFCharacterAndReplacesItsFlag() throws {
        let (reader, book, view) = try makeReader()
        reader.start(at: .pdfPage(1), annotations: [])
        spinRunLoop()
        let page = try XCTUnwrap(book.document.page(at: 1))
        var placed: Locator?
        reader.onReadingMarkerPlaced = { placed = $0 }
        reader.toggleReadingMarkerPlacement()

        let character = page.characterBounds(at: 8)
        let click = view.convert(CGPoint(x: character.midX, y: character.midY), from: page)
        XCTAssertTrue(reader.placePDFReadingMarker(at: click))
        let marker = try XCTUnwrap(placed)
        XCTAssertEqual(marker.kind, .pdf)
        XCTAssertEqual(marker.spineIndex, 1)
        XCTAssertEqual(marker.pdfRanges?.first?.location, 8)
        XCTAssertEqual(marker.pdfRanges?.first?.length, 1)
        XCTAssertFalse(reader.isPlacingReadingMarker)
        XCTAssertEqual(page.annotations.filter { $0.userName == "kodi-reading-marker" }.count, 1)
        let flag = try XCTUnwrap(page.annotations.first { $0.userName == "kodi-reading-marker" })
        XCTAssertEqual(flag.bounds.midY, character.midY, accuracy: 0.1)
        XCTAssertLessThan(flag.bounds.maxX, character.minX)

        reader.toggleReadingMarkerPlacement()
        let nextCharacter = page.characterBounds(at: 14)
        XCTAssertTrue(reader.placePDFReadingMarker(at: view.convert(
            CGPoint(x: nextCharacter.midX, y: nextCharacter.midY), from: page
        )))
        XCTAssertEqual(page.annotations.filter { $0.userName == "kodi-reading-marker" }.count, 1)
        XCTAssertFalse(page.annotations.contains { $0 === flag })

        reader.toggleReadingMarkerPlacement()
        reader.nextPage()
        XCTAssertFalse(reader.isPlacingReadingMarker)
        reader.readingMarker = nil
        XCTAssertFalse(page.annotations.contains { $0.userName == "kodi-reading-marker" })
    }

    func testReturningToMarkerRevealsExactTextWhenPDFIsZoomed() throws {
        let (reader, book, view) = try makeReader()
        reader.start(at: .pdfPage(1), annotations: [])
        spinRunLoop()
        let page = try XCTUnwrap(book.document.page(at: 1))
        let text = try XCTUnwrap(page.string) as NSString
        let offset = text.range(of: "Lower").location
        guard offset != NSNotFound else { return XCTFail("Missing lower text fixture") }
        let marker = Locator.pdfPage(1, ranges: [PDFTextRange(pageIndex: 1, location: offset, length: 1)])
        reader.readingMarker = marker
        view.autoScales = false
        view.scaleFactor = 3
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 792)))
        spinRunLoop()
        let character = page.characterBounds(at: offset)
        XCTAssertFalse(view.visibleRect.intersects(view.convert(character, from: page)))

        reader.go(to: marker)
        spinRunLoop()
        XCTAssertTrue(view.visibleRect.intersects(view.convert(character, from: page)),
                      "Returning to a marker must reveal its text, including below a zoomed page's top")
        XCTAssertNil(view.currentSelection, "Returning to a marker must not create a text selection")
    }

    func testPlainLineStartClickPlacesPDFMarkerWithoutShortcut() throws {
        let (reader, book, view) = try makeReader()
        reader.start(at: .pdfPage(1), annotations: [])
        spinRunLoop()
        let page = try XCTUnwrap(book.document.page(at: 1))
        let first = view.convert(page.characterBounds(at: 0), from: page)
        let point = CGPoint(x: first.minX - 8, y: first.midY)
        var placed: Locator?
        reader.onReadingMarkerPlaced = { placed = $0 }
        let down = try mouseEvent(.leftMouseDown, at: point, in: view)
        XCTAssertTrue(reader.handlePDFReadingMarkerInput(down) === down)
        XCTAssertNil(reader.readingMarker, "Mouse-down must leave a selection drag available")
        XCTAssertNil(reader.handlePDFReadingMarkerInput(try mouseEvent(.leftMouseUp, at: point, in: view)))
        let marker = try XCTUnwrap(placed)
        XCTAssertEqual(marker.spineIndex, 1)
        XCTAssertEqual(marker.pdfRanges?.first?.location, 0)
        XCTAssertFalse(reader.isPlacingReadingMarker)
        XCTAssertEqual(page.annotations.filter { $0.userName == "kodi-reading-marker" }.count, 1)

        reader.readingMarker = nil
        let middle = view.convert(page.characterBounds(at: 12), from: page)
        let regularText = CGPoint(x: middle.midX, y: middle.midY)
        let textDown = try mouseEvent(.leftMouseDown, at: regularText, in: view)
        let textUp = try mouseEvent(.leftMouseUp, at: regularText, in: view)
        XCTAssertTrue(reader.handlePDFReadingMarkerInput(textDown) === textDown)
        XCTAssertTrue(reader.handlePDFReadingMarkerInput(textUp) === textUp)
        XCTAssertNil(reader.readingMarker, "Regular text away from the line start must remain ordinary PDF interaction")
    }

    func testDirectPDFMarkerPreservesDragsLinksModifiersAndOverlays() throws {
        let (reader, book, view) = try makeReader()
        reader.start(at: .pdfPage(1), annotations: [])
        spinRunLoop()
        let page = try XCTUnwrap(book.document.page(at: 1))
        let first = view.convert(page.characterBounds(at: 0), from: page)
        let point = CGPoint(x: first.midX, y: first.midY)
        _ = reader.handlePDFReadingMarkerInput(try mouseEvent(.leftMouseDown, at: point, in: view))
        let dragged = CGPoint(x: point.x + 40, y: point.y)
        _ = reader.handlePDFReadingMarkerInput(try mouseEvent(.leftMouseDragged, at: dragged, in: view))
        _ = reader.handlePDFReadingMarkerInput(try mouseEvent(.leftMouseUp, at: dragged, in: view))
        XCTAssertNil(reader.readingMarker)

        for modifiers: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try mouseEvent(type, at: point, modifiers: modifiers, in: view)
                XCTAssertTrue(reader.handlePDFReadingMarkerInput(event) === event)
            }
            XCTAssertNil(reader.readingMarker)
        }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let doubleClick = try mouseEvent(type, at: point, clicks: 2, in: view)
            XCTAssertTrue(reader.handlePDFReadingMarkerInput(doubleClick) === doubleClick)
        }
        XCTAssertNil(reader.readingMarker)

        let link = PDFAnnotation(bounds: page.characterBounds(at: 0), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/reader-test")))
        page.addAnnotation(link)
        XCTAssertTrue(link.bounds.contains(view.convert(point, to: page)), "Link test click must be inside its page bounds")
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try mouseEvent(type, at: point, in: view)
            XCTAssertTrue(reader.handlePDFReadingMarkerInput(event) === event)
        }
        XCTAssertNil(reader.readingMarker)
        reader.toggleReadingMarkerPlacement()
        XCTAssertFalse(reader.placePDFReadingMarker(at: point), "Explicit marker mode must also preserve links")
        reader.cancelReadingMarkerPlacement()
        page.removeAnnotation(link)
        reader.readingMarker = nil

        let container = NSView(frame: view.frame)
        window?.contentView = container
        container.addSubview(view)
        let overlay = NSView(frame: container.convert(
            CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), from: view
        ))
        container.addSubview(overlay)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try mouseEvent(type, at: point, in: view)
            XCTAssertTrue(reader.handlePDFReadingMarkerInput(event) === event)
        }
        XCTAssertNil(reader.readingMarker, "A control over the PDF must keep its click")
    }

    func testFirstGlyphSingleClickWaitsAndCompleteDoubleClickKeepsWordSelection() throws {
        let (reader, book, view) = try makeReader()
        reader.start(at: .pdfPage(1), annotations: [])
        spinRunLoop()
        let page = try XCTUnwrap(book.document.page(at: 1))
        let first = view.convert(page.characterBounds(at: 0), from: page)
        let point = CGPoint(x: first.midX, y: first.midY)
        var placements = 0
        reader.onReadingMarkerPlaced = { _ in placements += 1 }

        for clicks in [1, 2] {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try mouseEvent(type, at: point, clicks: clicks, in: view)
                XCTAssertTrue(reader.handlePDFReadingMarkerInput(event) === event,
                              "Glyph clicks must remain available to PDFKit's word selection gesture")
            }
            XCTAssertNil(reader.readingMarker)
        }
        let word = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 4)))
        view.setCurrentSelection(word, animate: false)
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
        XCTAssertNil(reader.readingMarker, "A full double-click sequence must not change the marker after the pending delay")
        XCTAssertEqual(placements, 0)
        XCTAssertEqual(view.currentSelection?.string, "Page")

        view.clearSelection()
        spinRunLoop()
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try mouseEvent(type, at: point, in: view)
            XCTAssertTrue(reader.handlePDFReadingMarkerInput(event) === event)
        }
        XCTAssertNil(reader.readingMarker, "First-glyph single clicks must wait out the double-click interval")
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
        XCTAssertEqual(reader.readingMarker?.pdfRanges?.first?.location, 0)
        XCTAssertEqual(placements, 1)
    }

    func testClickDismissingPDFSelectionDoesNotPlaceMarker() throws {
        let (reader, book, view) = try makeReader()
        reader.start(at: .pdfPage(1), annotations: [])
        spinRunLoop()
        let page = try XCTUnwrap(book.document.page(at: 1))
        let word = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 4)))
        view.setCurrentSelection(word, animate: false)
        spinRunLoop()
        let first = view.convert(page.characterBounds(at: 0), from: page)
        let point = CGPoint(x: first.minX - 8, y: first.midY)
        let down = try mouseEvent(.leftMouseDown, at: point, in: view)
        XCTAssertTrue(reader.handlePDFReadingMarkerInput(down) === down)
        // PDFKit clears the previous selection during mouse-down, before up.
        view.clearSelection()
        let up = try mouseEvent(.leftMouseUp, at: point, in: view)
        XCTAssertTrue(reader.handlePDFReadingMarkerInput(up) === up)
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
        XCTAssertNil(reader.readingMarker)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = [],
        clicks: Int = 1, in view: PDFView
    ) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1
        ))
    }

    private func makeReader() throws -> (ReaderController, PDFBook, PDFView) {
        let url = try makePDF(pages: 3)
        pdfURL = url
        let book = try PDFBook(fileURL: url)
        let reader = ReaderController()
        let view = reader.makePDFView(for: book)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        self.window = window
        controller = reader
        reader.updateViewport(width: 900, height: 700)
        return (reader, book, view)
    }

    private func makePDF(pages: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodi-reader-ui-\(UUID().uuidString).pdf")
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: "Page \(index + 1) selectable text for Kodi Reader")
                ),
                context
            )
            context.textPosition = CGPoint(x: 72, y: 180)
            CTLineDraw(
                CTLineCreateWithAttributedString(NSAttributedString(string: "Lower text to resume reading")),
                context
            )
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func spinRunLoop() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
}
