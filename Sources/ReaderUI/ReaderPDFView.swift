import EpubKit
import PDFKit
import SwiftUI

#if os(macOS)
/// Hosts PDFKit's native renderer while the shared controller owns its state.
public struct ReaderPDFView: NSViewRepresentable {
    private let controller: ReaderController
    private let book: PDFBook

    public init(controller: ReaderController, book: PDFBook) {
        self.controller = controller
        self.book = book
    }

    public func makeNSView(context: Context) -> PDFView {
        controller.makePDFView(for: book)
    }

    public func updateNSView(_ view: PDFView, context: Context) {
        controller.updateViewport(width: view.bounds.width, height: view.bounds.height)
    }
}
#endif
