import AppKit
import CoreText
import EpubKit
import PDFKit
import XCTest
@testable import ReaderUI

final class ReminderMarkerPDFTests: XCTestCase {
    private var window: NSWindow?
    private var controller: ReaderController?
    private var urls: [URL] = []

    override func tearDown() {
        controller?.tearDown()
        window?.contentView = nil
        window?.orderOut(nil)
        for url in urls { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    func testResearchIconIsIndependentAccessibleAndActivatesWithoutChangingPDF() throws {
        let (reader, book, view) = try makeReader()
        let original = try Data(contentsOf: book.fileURL)
        let page = try XCTUnwrap(book.document.page(at: 0))
        let locator = try passage("database sharding", on: page, index: 0)
        var task = ResearchReminder(title: "Research database sharding", locator: locator, quotedText: "database sharding")
        reader.setReminders([task])
        let button = try XCTUnwrap(button(task.id, in: view))
        XCTAssertEqual(button.accessibilityLabel(), "Research reminder: " + task.title)
        XCTAssertEqual(button.toolTip, task.title)
        XCTAssertEqual(button.frame.width, 22)
        XCTAssertTrue(page.annotations.isEmpty, "Research icons must not become document annotations")
        XCTAssertNil(view.currentSelection)

        var activated: (UUID, CGRect)?
        reader.onReminderActivated = { activated = ($0, $1) }
        let expected = view.isFlipped ? button.frame : CGRect(x: button.frame.minX,
            y: view.bounds.height - button.frame.maxY, width: button.frame.width, height: button.frame.height)
        button.performClick(nil)
        XCTAssertEqual(activated?.0, task.id)
        XCTAssertEqual(activated?.1, expected)

        let monitor = PageTurnKeyMonitor.MonitorView()
        monitor.controller = reader
        view.addSubview(monitor)
        defer { monitor.tearDown(); monitor.removeFromSuperview() }
        var pageSpaceActions = 0
        monitor.spaceAction = { pageSpaceActions += 1 }
        XCTAssertTrue(try XCTUnwrap(view.window).makeFirstResponder(button))
        XCTAssertTrue(reader.isReminderBadgeFocused)
        XCTAssertTrue(ReaderKeyTarget.shouldSuppressPageTurns(for: button))
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: try XCTUnwrap(view.window).windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        XCTAssertTrue(monitor.keyEventHandler(space) === space,
                      "Space must activate a focused research button through AppKit, never turn the page")
        XCTAssertEqual(pageSpaceActions, 0)
        XCTAssertTrue(try XCTUnwrap(view.window).makeFirstResponder(view))
        XCTAssertFalse(reader.isReminderBadgeFocused)

        reader.toggleReadingMarkerPlacement()
        let point = CGPoint(x: button.frame.midX, y: button.frame.midY)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: try XCTUnwrap(view.window).windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(reader.handlePDFReadingMarkerInput(event) === event,
                      "The icon's button must keep its click in reading-marker mode")
        XCTAssertNil(reader.readingMarker)
        reader.cancelReadingMarkerPlacement()

        task.completedAt = Date()
        reader.setReminders([task])
        XCTAssertNil(self.button(task.id, in: view))
        XCTAssertNil(button.superview)
        task.completedAt = nil
        reader.setReminders([task])
        XCTAssertNotNil(self.button(task.id, in: view))
        reader.setReminders([])
        XCTAssertNil(self.button(task.id, in: view))
        XCTAssertEqual(try Data(contentsOf: book.fileURL), original)
    }

    func testSourceRepairZoomAndPageNavigationKeepIconsWithTheirPassage() throws {
        let (reader, book, view) = try makeReader()
        let page = try XCTUnwrap(book.document.page(at: 0))
        let correct = try passage("database sharding", on: page, index: 0)
        let stale = Locator.pdfPage(0, ranges: [PDFTextRange(pageIndex: 0, location: 0, length: 4)])
        let source = Annotation(locator: stale, text: "database sharding")
        let task = ResearchReminder(title: "Research sharding", source: .note,
            locator: .pdfPage(1), quotedText: "database sharding", annotationID: source.id)
        reader.setAnnotations([source])
        reader.setReminders([task])
        XCTAssertEqual(reader.annotations.first?.locator.pdfRanges, correct.pdfRanges)
        let first = try XCTUnwrap(button(task.id, in: view))
        let line = try XCTUnwrap(page.selection(for: NSRange(
            location: correct.pdfRanges![0].location, length: correct.pdfRanges![0].length)))
        XCTAssertEqual(first.frame.midY, view.convert(line.bounds(for: page), from: page).midY, accuracy: 1)

        view.autoScales = false
        view.scaleFactor *= 1.15
        spin()
        let zoomed = try XCTUnwrap(button(task.id, in: view))
        XCTAssertEqual(zoomed.frame.width, 22, "Native research icons retain a small click target while zooming")
        XCTAssertEqual(zoomed.frame.midY, view.convert(line.bounds(for: page), from: page).midY, accuracy: 1)
        XCTAssertEqual(page.annotations.count, 1, "Only the existing highlight belongs to PDFKit")

        reader.fitPDFPage(); spin()
        let pageTask = ResearchReminder(title: "Research this page", source: .page, locator: .pdfPage(1))
        reader.setReminders([task, pageTask])
        reader.go(to: .pdfPage(1)); spin()
        XCTAssertNil(button(task.id, in: view))
        XCTAssertNotNil(button(pageTask.id, in: view))
        reader.go(to: .pdfPage(0)); spin()
        XCTAssertNotNil(button(task.id, in: view))
        XCTAssertNil(button(pageTask.id, in: view))

        // Once the source note disappears, its independent saved page remains usable.
        reader.setAnnotations([])
        XCTAssertNil(button(task.id, in: view))
        reader.go(to: .pdfPage(1)); spin()
        reader.setReminders([pageTask])
        XCTAssertNotNil(button(pageTask.id, in: view))
    }

    func testMultipleIconsDoNotOverlapAndTeardownAndBookSwitchRemoveThem() throws {
        let (reader, book, view) = try makeReader()
        let page = try XCTUnwrap(book.document.page(at: 0))
        let locator = try passage("database sharding", on: page, index: 0)
        let tasks = (1...3).map { ResearchReminder(title: "Topic \($0)", locator: locator, quotedText: "database sharding") }
        reader.setReminders(tasks)
        let buttons = try tasks.map { try XCTUnwrap(button($0.id, in: view)) }
        for pair in zip(buttons, buttons.dropFirst()) {
            XCTAssertFalse(pair.0.frame.intersects(pair.1.frame))
        }
        let next = try PDFBook(fileURL: makePDF(), knownBookID: "replacement-book")
        let nextView = reader.makePDFView(for: next)
        XCTAssertTrue(reader.reminders.isEmpty)
        XCTAssertTrue(buttons.allSatisfy { $0.superview == nil })
        XCTAssertTrue(nextView.subviews.filter { $0.identifier?.rawValue.hasPrefix("kodi-research-reminder:") == true }.isEmpty)
        window?.contentView = nextView
        nextView.frame = view.frame
        reader.setReminders([ResearchReminder(title: "Page", source: .page, locator: .pdfPage(0))])
        spin()
        let remaining = nextView.subviews.filter { $0.identifier?.rawValue.hasPrefix("kodi-research-reminder:") == true }
        XCTAssertEqual(remaining.count, 1)
        reader.tearDown()
        XCTAssertTrue(reader.reminders.isEmpty)
        XCTAssertTrue(remaining.allSatisfy { $0.superview == nil })
    }

    private func button(_ id: UUID, in view: PDFView) -> NSButton? {
        view.subviews.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "kodi-research-reminder:\(id.uuidString)"
        }
    }

    private func passage(_ quote: String, on page: PDFPage, index: Int) throws -> Locator {
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: quote)
        XCTAssertNotEqual(range.location, NSNotFound)
        return .pdfPage(index, ranges: [.init(pageIndex: index, location: range.location, length: range.length)])
    }

    private func makeReader() throws -> (ReaderController, PDFBook, PDFView) {
        let book = try PDFBook(fileURL: makePDF())
        let reader = ReaderController()
        let view = reader.makePDFView(for: book)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        self.window = window
        controller = reader
        reader.updateViewport(width: 900, height: 700)
        reader.start(at: .pdfPage(0), annotations: [])
        spin()
        return (reader, book, view)
    }

    private func makePDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kodi-reminder-markers-\(UUID().uuidString).pdf")
        urls.append(url)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for number in 1...2 {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                string: "Page \(number): database sharding and read replicas")), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func spin() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
}
