import AppKit
import EpubKit
import ZIPFoundation

@main
struct NoteExportSmokeTests {
    @MainActor
    static func main() throws {
        let annotation = Annotation(
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)),
            text: "Referenced passage <with> literal characters\nSecond line",
            note: "A **bold** note with <u>underline</u>\n\n- First item\n- Second item",
            chapterTitle: "Chapter One"
        )
        for format in NoteExportFormat.allCases {
            let output = try NotesExporter.data(format: format, bookTitle: "Test Book", author: "Test Author", annotations: [annotation])
            precondition(!output.isEmpty)
            if format == .word {
                precondition(output.starts(with: [0x50, 0x4b]), "DOCX must be a ZIP package")
                let document = try NSAttributedString(data: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
                for text in ["Test Book", "Test Author", "Chapter One", "Referenced passage <with> literal characters", "Second line", "bold", "underline", "First item", "Second item"] {
                    precondition(document.string.contains(text), "DOCX lost: \(text)")
                }
                var hasBold = false
                var hasUnderline = false
                document.enumerateAttributes(in: NSRange(location: 0, length: document.length)) { attributes, _, _ in
                    if let font = attributes[.font] as? NSFont, NSFontManager.shared.traits(of: font).contains(.boldFontMask) { hasBold = true }
                    if let underline = attributes[.underlineStyle] as? Int, underline != 0 { hasUnderline = true }
                }
                precondition(hasBold && hasUnderline, "DOCX should preserve note styling")
                try output.write(to: URL(fileURLWithPath: "/tmp/kodi-note-export-smoke.docx"))
            }
        }
        let first = NoteSketch(title: "Diagram One"), second = NoteSketch(title: "Diagram Two")
        let drawingNote = Annotation(locator: annotation.locator, text: annotation.text,
            note: "Before\n\n" + first.markdown + "\n\nBetween\n\n" + second.markdown + "\n\nAfter", sketches: [first, second])
        func png(_ color: NSColor) -> Data {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let rgb = color.usingColorSpace(.deviceRGB)!
            let bytes = bitmap.bitmapData!
            for y in 0..<30 { for x in 0..<60 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8(rgb.redComponent * 255)
                bytes[offset + 1] = UInt8(rgb.greenComponent * 255)
                bytes[offset + 2] = UInt8(rgb.blueComponent * 255)
                bytes[offset + 3] = 255
            } }
            return bitmap.representation(using: .png, properties: [:])!
        }
        let images = [first.id: png(.red), second.id: png(.blue)]
        for format in NoteExportFormat.allCases {
            let output = try NotesExporter.output(format: format, bookTitle: "Diagrams", author: "Author", annotations: [drawingNote], sketchImages: images, assetDirectory: "Diagram assets")
            switch format {
            case .markdown, .notion:
                let text = String(data: output.data, encoding: .utf8)!
                precondition(!text.contains("kodi-sketch://"))
                precondition(text.contains("![Diagram One](Diagram%20assets/"))
                precondition(output.assets.count == 2)
                precondition(output.assets["Diagram assets/" + first.id.uuidString + ".png"] == images[first.id])
                precondition(text.range(of: "Before")!.lowerBound < text.range(of: "Diagram One")!.lowerBound)
                precondition(text.range(of: "Diagram One")!.lowerBound < text.range(of: "Between")!.lowerBound)
            case .appleNotes:
                try output.data.write(to: URL(fileURLWithPath: "/tmp/kodi-sketch-note-export.html"))
                let html = String(data: output.data, encoding: .utf8)!
                precondition(html.components(separatedBy: "data:image/png;base64,").count == 3)
                precondition(html.contains(images[first.id]!.base64EncodedString()))
                precondition(html.contains("<figcaption>Diagram Two</figcaption>"))
            case .word:
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("sketch-export-" + UUID().uuidString + ".docx")
                defer { try? FileManager.default.removeItem(at: url) }
                try output.data.write(to: url)
                let archive = try Archive(url: url, accessMode: .read)
                precondition(archive.filter { $0.path.hasPrefix("word/media/") }.count == 2, "DOCX should contain both images")
                let document = try NSAttributedString(data: output.data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
                var xml = Data()
                _ = try archive.extract(archive["word/document.xml"]!) { xml.append($0) }
                let documentXML = try Foundation.XMLDocument(data: xml)
                let drawingCount = try documentXML.nodes(forXPath: "//*[local-name()='drawing']").count
                precondition(drawingCount == 2, "DOCX should contain two native drawings")
                let descriptions = try documentXML.nodes(forXPath: "//*[local-name()='docPr']/@descr").compactMap(\.stringValue)
                precondition(descriptions == ["Diagram One", "Diagram Two"], "DOCX image order should match the note")
                var relationshipData = Data()
                _ = try archive.extract(archive["word/_rels/document.xml.rels"]!) { relationshipData.append($0) }
                let relationships = try Foundation.XMLDocument(data: relationshipData)
                let imageRelationshipCount = try relationships.nodes(forXPath: "//*[local-name()='Relationship' and contains(@Type, '/image')]").count
                precondition(imageRelationshipCount == 2)
                precondition(!String(data: xml, encoding: .utf8)!.contains("KODISKETCH"))
                precondition(document.string.contains("Diagram One") && document.string.contains("Diagram Two"))
            }
        }
        do {
            _ = try NotesExporter.data(format: .markdown, bookTitle: "Test", author: "Author", annotations: [drawingNote])
            preconditionFailure("Missing sketch images must fail the export")
        } catch { }
        print("All four sketch exports preserve diagrams and ordering; DOCX media, drawing positions, and image relationships verified; missing assets fail explicitly")
        print("All four note export formats passed; DOCX text and formatting round-trip passed.")
    }
}
