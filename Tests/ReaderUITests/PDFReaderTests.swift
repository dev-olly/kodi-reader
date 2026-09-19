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
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func spinRunLoop() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
}
