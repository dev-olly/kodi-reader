import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// Portable representations of notes and their source passages.
public enum NoteExportFormat: String, CaseIterable, Sendable {
    case markdown, word, appleNotes, notion

    public var label: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .word: return "Word (.docx)"
        case .appleNotes: return "Apple Notes (.html)"
        case .notion: return "Notion (.md)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown, .notion: return "md"
        case .word: return "docx"
        case .appleNotes: return "html"
        }
    }

    public var instructions: String {
        switch self {
        case .markdown: return "Includes notes, passages, citations, and sketch images in a companion assets folder."
        case .word: return "Save a formatted Word document with notes, passages, citations, and sketch images."
        case .appleNotes: return "In Apple Notes, choose File → Import to Notes and select this HTML file."
        case .notion: return "Import the Markdown file with its companion sketch assets folder into Notion."
        }
    }
}

/// Preserve AppKit's prose formatting while adding portable DrawingML images.
/// AppKit's OOXML writer silently drops NSTextAttachment image contents.
#if os(macOS)
public enum SketchDOCX {
    public struct Image {
        public var marker: String
        public var title: String
        public var png: Data
        public var width: Double
        public var height: Double
        public init(marker: String, title: String, png: Data, width: Double, height: Double) {
            self.marker = marker; self.title = title; self.png = png; self.width = width; self.height = height
        }
    }

    public static func embedding(_ images: [Image], in data: Data) throws -> Data {
        guard !images.isEmpty else { return data }
        let input = try Archive(data: data, accessMode: .read)
        var parts: [String: Data] = [:]
        for entry in input {
            var bytes = Data()
            _ = try input.extract(entry) { bytes.append($0) }
            parts[entry.path] = bytes
        }
        func xml(_ path: String) throws -> Foundation.XMLDocument {
            guard let bytes = parts[path] else { throw failure("The Word document is missing \(path).") }
            return try Foundation.XMLDocument(data: bytes)
        }
        let document = try xml("word/document.xml")
        let relationships = try xml("word/_rels/document.xml.rels")
        let types = try xml("[Content_Types].xml")
        for (index, image) in images.enumerated() {
            guard image.marker.allSatisfy({ $0.isLetter || $0.isNumber }),
                  let text = try document.nodes(forXPath: "//*[local-name()='t' and text()='\(image.marker)']").first,
                  let run = text.parent as? Foundation.XMLElement else { throw failure("A sketch's position was lost while exporting.") }
            let identifier = "rIdSketch\(index + 1)"
            let filename = "kodi-sketch-\(index + 1).png"
            let width = Int(max(1, image.width) * 12700), height = Int(max(1, image.height) * 12700)
            let drawing = try Foundation.XMLElement(xmlString: """
            <w:drawing xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="\(index + 1)" name="Sketch \(index + 1)"/>
                <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                  <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="0" name="\(filename)"/><pic:cNvPicPr/></pic:nvPicPr>
                    <pic:blipFill><a:blip r:embed="\(identifier)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                    <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
                  </pic:pic>
                </a:graphicData></a:graphic>
              </wp:inline>
            </w:drawing>
            """)
            if let properties = try drawing.nodes(forXPath: ".//*[local-name()='docPr']").first as? Foundation.XMLElement {
                properties.addAttribute(Foundation.XMLNode.attribute(withName: "descr", stringValue: image.title) as! Foundation.XMLNode)
            }
            text.detach()
            run.addChild(drawing)
            let relationship = Foundation.XMLElement(name: "Relationship", uri: "http://schemas.openxmlformats.org/package/2006/relationships")
            for (name, value) in [("Id", identifier), ("Type", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"), ("Target", "media/" + filename)] {
                relationship.addAttribute(Foundation.XMLNode.attribute(withName: name, stringValue: value) as! Foundation.XMLNode)
            }
            relationships.rootElement()?.addChild(relationship)
            parts["word/media/" + filename] = image.png
        }
        if try types.nodes(forXPath: "//*[local-name()='Default' and @Extension='png']").isEmpty {
            let type = Foundation.XMLElement(name: "Default", uri: "http://schemas.openxmlformats.org/package/2006/content-types")
            type.addAttribute(Foundation.XMLNode.attribute(withName: "Extension", stringValue: "png") as! Foundation.XMLNode)
            type.addAttribute(Foundation.XMLNode.attribute(withName: "ContentType", stringValue: "image/png") as! Foundation.XMLNode)
            types.rootElement()?.addChild(type)
        }
        parts["word/document.xml"] = document.xmlData
        parts["word/_rels/document.xml.rels"] = relationships.xmlData
        parts["[Content_Types].xml"] = types.xmlData
        let output = try Archive(accessMode: .create)
        for path in parts.keys.sorted() {
            let bytes = parts[path]!
            try output.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { position, size in
                bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + size))
            }
        }
        guard let result = output.data else { throw failure("Could not package the Word document.") }
        return result
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "KodiExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif

public enum NoteExport {
    public static func html(bookTitle: String, author: String, annotations: [Annotation], sketchImages: [UUID: Data] = [:]) -> String {
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown Author" : author
        let notes = annotations.filter(\.hasContent).sorted {
            ($0.locator.spineIndex, $0.createdAt) < ($1.locator.spineIndex, $1.createdAt)
        }
        var body = "<h1>\(escape("Notes — " + bookTitle))</h1><p>\(escape(author))</p>"
        if notes.isEmpty { body += "<p><em>No notes yet.</em></p>" }
        for note in notes {
            let chapter = note.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let section = chapter.isEmpty ? "Untitled section" : chapter
            body += "<h2>\(escape(section))</h2>"
            // Source text is always literal; book passages can contain Markdown or HTML.
            body += "<blockquote>\(escape(note.text).replacingOccurrences(of: "\n", with: "<br>"))</blockquote>"
            body += "<p><em>\(escape("— \(section), \(author), \(bookTitle)"))</em></p>"
            body += render(note.note ?? "", sketchImages: sketchImages)
            if note.hasDrawing && note.sketches.isEmpty { body += "<p><em>Visual note attached in Kodi Reader; drawing is not included in this export.</em></p>" }
            body += "<hr>"
        }
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape("Notes — " + bookTitle))</title>
        <style>body{font-family:Helvetica,Arial,sans-serif;font-size:12pt;line-height:1.5;max-width:760px;margin:40px auto;color:#222}blockquote{margin:16px 0;padding-left:18px;border-left:3px solid #888}pre,code{font-family:Menlo,monospace}table{border-collapse:collapse}td,th{border:1px solid #aaa;padding:6px}</style>
        </head><body>\(body)</body></html>
        """
    }

    private static func render(_ markdown: String, sketchImages: [UUID: Data]) -> String {
        NoteMarkdown.previewBlocks(of: markdown).map { block in
            switch block {
            case .sketch(let id, let title):
                if let image = sketchImages[id] {
                    return "<figure><img style=\"max-width:100%;height:auto\" alt=\"\(escape(title))\" src=\"data:image/png;base64,\(image.base64EncodedString())\"><figcaption>\(escape(title))</figcaption></figure>"
                }
                return "<p><em>\(escape(title)) — sketch image unavailable.</em></p>"
            case .paragraph(let text):
                return text.components(separatedBy: "\n").map { line in
                    if let prefix = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                        let level = line[prefix].count - 1
                        return "<h\(level)>\(inline(String(line[prefix.upperBound...])))</h\(level)>"
                    }
                    if line.hasPrefix("> ") { return "<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>" }
                    if ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) { return "<hr>" }
                    return "<p>\(inline(line))</p>"
                }.joined()
            case .unorderedList(let items):
                return "<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
            case .orderedList(let items):
                return "<ol>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ol>"
            case .taskList(let items):
                return "<ul>" + items.map { "<li>\($0.checked ? "☑" : "☐") \(inline($0.text))</li>" }.joined() + "</ul>"
            case .code(let code): return "<pre><code>\(escape(code))</code></pre>"
            case .table(let header, let rows, _):
                return "<table><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
                    + rows.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
            }
        }.joined()
    }

    private static func inline(_ text: String) -> String {
        let marked = text.replacingOccurrences(of: "<u>", with: "\u{E000}")
            .replacingOccurrences(of: "</u>", with: "\u{E001}")
        guard let parsed = try? AttributedString(markdown: marked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return escape(text) }
        var underlined = false
        var output = ""
        for run in parsed.runs {
            for chunk in String(parsed[run.range].characters).components(separatedBy: "\u{E000}").enumerated() {
                if chunk.offset > 0 { underlined = true }
                for end in chunk.element.components(separatedBy: "\u{E001}").enumerated() {
                    if end.offset > 0 { underlined = false }
                    var value = escape(end.element)
                    let intent = run.inlinePresentationIntent ?? []
                    if intent.contains(.code) { value = "<code>\(value)</code>" }
                    if intent.contains(.stronglyEmphasized) { value = "<strong>\(value)</strong>" }
                    if intent.contains(.emphasized) { value = "<em>\(value)</em>" }
                    if intent.contains(.strikethrough) { value = "<del>\(value)</del>" }
                    if underlined { value = "<u>\(value)</u>" }
                    if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                        value = "<a href=\"\(escape(link.absoluteString))\">\(value)</a>"
                    }
                    output += value
                }
            }
        }
        return output
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
