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

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kodi-audio-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstAudio = NoteAudio(title: "Thought [one]", duration: 12)
        let secondAudio = NoteAudio(title: "Second thought", duration: 3)
        let firstFile = root.appendingPathComponent("one.m4a"), secondFile = root.appendingPathComponent("two.m4a")
        try Data("first audio bytes".utf8).write(to: firstFile)
        try Data("second audio bytes".utf8).write(to: secondFile)
        let files = [firstAudio.id: firstFile, secondAudio.id: secondFile]
        let audioNote = Annotation(locator: annotation.locator, text: "Passage", note: "Before\n\n" + first.markdown + "\n\n" + firstAudio.markdown + "\n\nBetween\n\n" + secondAudio.markdown + "\n\nAfter", sketches: [first], audioRecordings: [firstAudio, secondAudio])
        for format in NoteExportFormat.allCases {
            let output = try NotesExporter.output(format: format, bookTitle: "Audio", author: "Author", annotations: [audioNote], sketchImages: images, audioFiles: files, assetDirectory: "Audio assets")
            precondition(output.fileAssets.count == 2)
            let firstPath = "Audio%20assets/" + firstAudio.id.uuidString + ".m4a"
            let secondPath = "Audio%20assets/" + secondAudio.id.uuidString + ".m4a"
            if format == .word {
                let archive = try Archive(data: output.data, accessMode: .read)
                var rels = Data()
                _ = try archive.extract(archive["word/_rels/document.xml.rels"]!) { rels.append($0) }
                let xml = try Foundation.XMLDocument(data: rels)
                let targets = try xml.nodes(forXPath: "//*[local-name()='Relationship' and @TargetMode='External']/@Target").compactMap(\.stringValue)
                precondition(Set(targets).isSuperset(of: [firstPath, secondPath]), "Word must keep portable relative audio links")
                precondition(!String(data: rels, encoding: .utf8)!.contains("kodi.invalid"))
                precondition(archive.filter { $0.path.hasPrefix("word/media/") }.count == 1, "Mixed audio notes must retain sketch images")
            } else {
                let text = String(data: output.data, encoding: .utf8)!
                precondition(text.contains(firstPath) && text.contains(secondPath))
                precondition(!text.contains("kodi-audio://"))
                if format == .appleNotes {
                    precondition(text.components(separatedBy: "<audio controls").count == 3)
                    precondition(text.contains("<a href=\"" + firstPath + "\">"))
                }
            }
            let destination = root.appendingPathComponent(format.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let document = destination.appendingPathComponent("Notes." + format.fileExtension)
            try NotesExporter.write(output, to: document)
            let writtenDocument = try Data(contentsOf: document)
            precondition(writtenDocument == output.data)
            for (path, source) in output.fileAssets {
                let copied = try Data(contentsOf: destination.appendingPathComponent(path))
                let original = try Data(contentsOf: source)
                precondition(copied == original)
            }
            do {
                _ = try NotesExporter.output(format: format, bookTitle: "Audio", author: "Author", annotations: [audioNote], sketchImages: images)
                preconditionFailure("Missing audio must fail every export format")
            } catch { }
        }

        // Saved transcript text belongs to each annotation's attachment metadata,
        // even when copied recordings share the same immutable audio identity.
        var transcribed = firstAudio
        transcribed.transcript = "FIRSTTRANSCRIPT <script>alert(1)</script> & **literal** [link](javascript:evil)\nSecond transcript line"
        var independentCopy = firstAudio
        independentCopy.title = "Copied recording"
        independentCopy.transcript = "SECONDTRANSCRIPT independent text"
        let transcriptNote = Annotation(locator: annotation.locator, text: "First transcript passage",
            note: "Lead\n\n" + transcribed.markdown + "\n\nBETWEENTRANSCRIPTLINKS\n\n" + transcribed.markdown + "\n\nTail",
            createdAt: Date(timeIntervalSince1970: 1_000), audioRecordings: [transcribed])
        let copiedTranscriptNote = Annotation(locator: annotation.locator, text: "Copied transcript passage",
            note: independentCopy.markdown, createdAt: Date(timeIntervalSince1970: 2_000), audioRecordings: [independentCopy])
        let originalAudioBytes = try Data(contentsOf: firstFile)
        for format in NoteExportFormat.allCases {
            let output = try NotesExporter.output(format: format, bookTitle: "Transcripts", author: "Author",
                annotations: [transcriptNote, copiedTranscriptNote], audioFiles: [firstAudio.id: firstFile], assetDirectory: "Transcript assets")
            precondition(output.fileAssets.count == 1, "Copied audio should keep one immutable exported asset")
            let visible: String
            if format == .word {
                let archive = try Archive(data: output.data, accessMode: .read)
                var xml = Data()
                _ = try archive.extract(archive["word/document.xml"]!) { xml.append($0) }
                let document = try Foundation.XMLDocument(data: xml)
                visible = try document.nodes(forXPath: "//*[local-name()='t']").compactMap(\.stringValue).joined(separator: "\n")
                precondition(visible.contains("<script>alert(1)</script> & **literal** [link](javascript:evil)"), "Word transcript text must remain literal")
            } else {
                visible = String(data: output.data, encoding: .utf8)!
                if format == .appleNotes {
                    precondition(visible.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; **literal**"))
                    precondition(!visible.contains("<script>"))
                } else {
                    precondition(visible.contains(#"\<script\>alert\(1\)\</script\> & \*\*literal\*\* \[link\]\(javascript:evil\)"#), "Markdown transcript text must remain literal")
                }
            }
            precondition(visible.components(separatedBy: "FIRSTTRANSCRIPT").count == 2, "Repeated links must not repeat a saved transcript")
            precondition(visible.components(separatedBy: "SECONDTRANSCRIPT").count == 2, "Copied notes keep their independent transcript")
            precondition(visible.range(of: "FIRSTTRANSCRIPT")!.lowerBound < visible.range(of: "BETWEENTRANSCRIPTLINKS")!.lowerBound,
                         "The transcript should appear beside the first occurrence of its audio link")
            let folder = root.appendingPathComponent("transcript-" + format.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try NotesExporter.write(output, to: folder.appendingPathComponent("Notes." + format.fileExtension))
            let exported = folder.appendingPathComponent("Transcript assets/" + firstAudio.id.uuidString + ".m4a")
            let exportedBytes = try Data(contentsOf: exported)
            let remainingSource = try Data(contentsOf: firstFile)
            precondition(exportedBytes == originalAudioBytes)
            precondition(remainingSource == originalAudioBytes, "Transcript export must not rewrite audio")
        }
        let existingDocument = root.appendingPathComponent("Existing.md")
        let existingFolder = root.appendingPathComponent("Existing-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: true)
        try Data("existing document".utf8).write(to: existingDocument)
        let oldAsset = existingFolder.appendingPathComponent("kept.m4a")
        try Data("existing asset".utf8).write(to: oldAsset)
        let missingOutput = NotesExporter.Output(data: Data("replacement".utf8), assets: [:], fileAssets: ["Existing-assets/new.m4a": root.appendingPathComponent("missing.m4a")])
        do {
            try NotesExporter.write(missingOutput, to: existingDocument)
            preconditionFailure("An audio copy failure must fail the export")
        } catch { }
        let previousDocument = try Data(contentsOf: existingDocument)
        let previousAsset = try Data(contentsOf: oldAsset)
        precondition(previousDocument == Data("existing document".utf8))
        precondition(previousAsset == Data("existing asset".utf8))
        precondition(!FileManager.default.fileExists(atPath: existingFolder.appendingPathComponent("new.m4a").path))
        let reminder = ResearchReminder(title: "Research sharding", source: .note,
            locator: annotation.locator, completedAt: Date())
        var reminderNote = annotation
        reminderNote.note = "Before\n\n" + ReminderReference.markdown(id: reminder.id, title: "Stale fallback title")
            + "\n\n- [ ] Ordinary checklist\n\nAfter"
        for format in NoteExportFormat.allCases {
            let exported = try NotesExporter.output(format: format, bookTitle: "Research", author: "Author",
                annotations: [reminderNote], reminders: [reminder])
            let text: String
            if format == .word {
                text = try NSAttributedString(data: exported.data,
                    options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
            } else { text = String(data: exported.data, encoding: .utf8)! }
            precondition(text.contains("Research sharding") && text.contains("Ordinary checklist"))
            precondition(!text.contains("kodi-reminder://") && !text.contains("Stale fallback title"))
            if format == .markdown || format == .notion { precondition(text.contains("- [x] Research sharding")) }
            else { precondition(text.contains("☑")) }
        }
        print("All reminder exports resolve current titles and completion, preserve ordinary checklists, and omit app-specific links")
        print("Audio exports preserve .m4a bytes and relative links in all four formats; Word keeps mixed sketches; failed copies preserve prior exports")
        print("Saved transcripts export literally once per recording per note in all four formats; copied notes keep independent text and audio bytes remain unchanged")
        print("All four sketch exports preserve diagrams and ordering; DOCX media, drawing positions, and image relationships verified; missing assets fail explicitly")
        print("All four note export formats passed; DOCX text and formatting round-trip passed.")
    }
}
