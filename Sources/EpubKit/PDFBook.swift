import CryptoKit
import Foundation
import PDFKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum PDFBookError: LocalizedError {
    case cannotOpen(URL)
    case locked
    case empty

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url):
            return "\(url.lastPathComponent) is not a readable PDF document."
        case .locked:
            return "Password-protected PDFs are not supported yet."
        case .empty:
            return "This PDF does not contain any pages."
        }
    }
}

public enum DocumentDestination: Hashable, Sendable {
    case epub(path: String, fragment: String?)
    case pdf(pageIndex: Int, pointX: Double?, pointY: Double?)
}

public struct DocumentOutlineEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let destination: DocumentDestination?
    public let children: [DocumentOutlineEntry]

    public init(
        id: UUID = UUID(),
        title: String,
        destination: DocumentDestination?,
        children: [DocumentOutlineEntry] = []
    ) {
        self.id = id
        self.title = title
        self.destination = destination
        self.children = children
    }

    public var flattened: [DocumentOutlineEntry] {
        [self] + children.flatMap(\.flattened)
    }
}

/// A PDF opened through PDFKit. The source is never mutated; Kodi annotations
/// are transient PDFKit annotations rebuilt from the library record.
public final class PDFBook: @unchecked Sendable {
    public let fileURL: URL
    public let document: PDFDocument
    public let bookID: String
    public let title: String
    public let author: String
    public let outline: [DocumentOutlineEntry]

    public var pageCount: Int { document.pageCount }
    public var allowsTextExtraction: Bool { document.allowsCopying }

    public init(fileURL: URL, knownBookID: String? = nil) throws {
        guard let document = PDFDocument(url: fileURL) else {
            throw PDFBookError.cannotOpen(fileURL)
        }
        guard !document.isLocked else { throw PDFBookError.locked }
        guard document.pageCount > 0 else { throw PDFBookError.empty }

        self.fileURL = fileURL
        self.document = document
        bookID = try knownBookID ?? ("pdf-sha256:" + Self.digest(fileURL))

        let attributes = document.documentAttributes ?? [:]
        let metadataTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataAuthor = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = metadataTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? fileURL.deletingPathExtension().lastPathComponent.nonEmpty
            ?? "Untitled PDF"
        author = metadataAuthor.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Author"
        outline = Self.makeOutline(document.outlineRoot, document: document)
    }

    public var coverImageData: Data? {
        guard let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 192, height: 280), for: .cropBox)
        #if os(macOS)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }

    public func sectionTitle(forPageIndex index: Int) -> String? {
        let entries = outline.flatMap(\.flattened).compactMap { entry -> (Int, String)? in
            guard case .pdf(let page, _, _) = entry.destination else { return nil }
            return (page, entry.title)
        }.sorted { $0.0 < $1.0 }
        return entries.last(where: { $0.0 <= index })?.1
    }

    private static func digest(_ url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PDFBookError.cannotOpen(url)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            throw PDFBookError.cannotOpen(url)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeOutline(
        _ root: PDFOutline?,
        document: PDFDocument
    ) -> [DocumentOutlineEntry] {
        guard let root else { return [] }
        return (0..<root.numberOfChildren).compactMap { index in
            root.child(at: index).map { makeOutlineEntry($0, document: document) }
        }
    }

    private static func makeOutlineEntry(
        _ item: PDFOutline,
        document: PDFDocument
    ) -> DocumentOutlineEntry {
        let destination = item.destination.flatMap { destination -> DocumentDestination? in
            guard let page = destination.page else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return nil }
            return .pdf(
                pageIndex: pageIndex,
                pointX: destination.point.x.isFinite ? destination.point.x : nil,
                pointY: destination.point.y.isFinite ? destination.point.y : nil
            )
        }
        let children = (0..<item.numberOfChildren).compactMap { index in
            item.child(at: index).map { makeOutlineEntry($0, document: document) }
        }
        return DocumentOutlineEntry(
            title: item.label?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled",
            destination: destination,
            children: children
        )
    }
}

public enum ReaderDocument: @unchecked Sendable {
    case epub(EPUBBook)
    case pdf(PDFBook)

    public init(fileURL: URL, knownBookID: String? = nil) throws {
        switch fileURL.pathExtension.lowercased() {
        case "pdf": self = .pdf(try PDFBook(fileURL: fileURL, knownBookID: knownBookID))
        default: self = .epub(try EPUBBook(fileURL: fileURL))
        }
    }

    public var kind: DocumentKind {
        switch self { case .epub: .epub; case .pdf: .pdf }
    }
    public var bookID: String {
        switch self { case .epub(let book): book.bookID; case .pdf(let book): book.bookID }
    }
    public var title: String {
        switch self { case .epub(let book): book.title; case .pdf(let book): book.title }
    }
    public var author: String {
        switch self { case .epub(let book): book.author; case .pdf(let book): book.author }
    }
    public var fileURL: URL {
        switch self { case .epub(let book): book.fileURL; case .pdf(let book): book.fileURL }
    }
    public var coverImageData: Data? {
        switch self { case .epub(let book): book.coverImageData; case .pdf(let book): book.coverImageData }
    }
    public var outline: [DocumentOutlineEntry] {
        switch self {
        case .epub(let book):
            func convert(_ entry: TOCEntry) -> DocumentOutlineEntry {
                DocumentOutlineEntry(
                    title: entry.title,
                    destination: entry.path.isEmpty ? nil : .epub(path: entry.path, fragment: entry.fragment),
                    children: entry.children.map(convert)
                )
            }
            return book.publication.toc.map(convert)
        case .pdf(let book): return book.outline
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
