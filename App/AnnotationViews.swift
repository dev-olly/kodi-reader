import AppKit
import EpubKit
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

private enum NotesFilter: String, CaseIterable, Identifiable {
    case all
    case withNotes
    case highlightsOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .withNotes: return "With notes"
        case .highlightsOnly: return "Highlights only"
        }
    }
}

/// Sidebar listing bookmarks and a searchable notes library for the open book.
struct AnnotationsInspector: View {
    @Environment(AppModel.self) private var model
    let annotations: [Annotation]
    let bookmarks: [Bookmark]
    let chapterTitles: [String]
    let onSelect: (Locator) -> Void
    let onEdit: (Annotation) -> Void
    let onDelete: (Annotation) -> Void
    let onExport: (NoteExportFormat) -> Void

    @State private var query = ""
    @State private var filter: NotesFilter = .all
    @State private var chapterFilter: String = ""

    private var isEmpty: Bool { annotations.isEmpty && bookmarks.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                emptyState
            } else {
                controls
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !bookmarks.isEmpty && query.isEmpty && filter == .all && chapterFilter.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                marginLabel("BOOKMARKS")
                                ForEach(bookmarks) { bookmark in
                                    Button { onSelect(bookmark.locator) } label: {
                                        Label(
                                            bookmark.chapterTitle ?? "Bookmark",
                                            systemImage: "bookmark.fill"
                                        )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 18) {
                            marginLabel("A THOUGHT TO KEEP")
                            if filteredAnnotations.isEmpty {
                                Text("No matches")
                                    .foregroundStyle(model.settings.theme.muted)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 36) {
                                    ForEach(filteredAnnotations) { annotation in
                                        row(for: annotation)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(model.settings.theme.uiForeground)
        .background(model.settings.theme.surface)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "highlighter")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(model.settings.theme.accent)
                    .frame(width: 48, height: 48)
                    .background(model.settings.theme.accent.opacity(0.08), in: .rect(cornerRadius: 14))
                    .padding(.bottom, 22)

                Text("Keep a little of\nwhat you read.")
                    .font(.system(size: 25, weight: .regular, design: .serif))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)

                Text("Your highlights, notes, and bookmarks will collect here as you read.")
                    .font(.system(size: 13))
                    .foregroundStyle(model.settings.theme.muted)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle()
                    .fill(model.settings.theme.border.opacity(0.7))
                    .frame(height: 1)
                    .padding(.vertical, 24)

                Text("START WITH A PASSAGE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(model.settings.theme.muted)
                    .padding(.bottom, 16)

                emptyStateHint("cursorarrow", title: "Select a few words", detail: "Drag across a passage in the book.")
                    .padding(.bottom, 18)
                emptyStateHint("square.and.pencil", title: "Make it yours", detail: "Choose a highlight color or add a note.")
            }
            .frame(maxWidth: 300, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 28)
        }
    }

    private func emptyStateHint(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(model.settings.theme.accent)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(model.settings.theme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(NoteExportFormat.allCases, id: \.self) { format in
                Button(format.label) { onExport(format) }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.settings.theme.muted)
        .accessibilityLabel("Export all notes")
        .quickHelp("Export all notes with referenced passages")
    }

    private func marginLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .tracking(1)
            .foregroundStyle(model.settings.theme.muted)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(model.settings.theme.muted)
                TextField("Search your margin", text: $query, prompt: Text("Search your margin").foregroundColor(model.settings.theme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityLabel("Search notes")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
                if annotations.contains(where: \.hasContent) {
                    exportMenu
                }
            }
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(model.settings.theme.border.opacity(0.6)).frame(height: 1)
            }

            HStack(spacing: 16) {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(NotesFilter.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    filterLabel(filter == .all ? "All entries" : filter.label)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Filter notes and highlights")
                if !chapterTitles.isEmpty {
                    Menu {
                        Picker("Chapter", selection: $chapterFilter) {
                            Text("All chapters").tag("")
                            ForEach(chapterTitles, id: \.self) { title in
                                Text(title).tag(title)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        filterLabel(chapterFilter.isEmpty ? "All chapters" : chapterFilter)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Filter by chapter")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .font(.system(size: 10))
            .foregroundStyle(model.settings.theme.muted)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private func filterLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }

    private var filteredAnnotations: [Annotation] {
        annotations
            .sorted {
                ($0.locator.spineIndex, $0.createdAt) < ($1.locator.spineIndex, $1.createdAt)
            }
            .filter { annotation in
                switch filter {
                case .all: break
                case .withNotes:
                    if !annotation.hasContent { return false }
                case .highlightsOnly:
                    if annotation.hasContent { return false }
                }

                if !chapterFilter.isEmpty, annotation.chapterTitle != chapterFilter {
                    return false
                }

                guard !query.isEmpty else { return true }
                let haystack = [
                    annotation.text,
                    annotation.note ?? "",
                    annotation.chapterTitle ?? "",
                ].joined(separator: "\n")
                return haystack.localizedCaseInsensitiveContains(query)
            }
    }

    private func row(for annotation: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { onEdit(annotation) } label: {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(annotation.recoveredFrom == nil ? annotation.title : "Recovered version: " + annotation.title)
                            .font(.custom("Georgia", size: 20))
                            .fontWeight(.regular)
                            .lineSpacing(5)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if annotation.isOrphaned {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Quote not found in chapter")
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.vertical, 2)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(annotation.visibleHighlightColor.swiftUIColor)
                            .frame(width: 3)
                    }

                    if annotation.hasNote {
                        Text(annotation.plainNotePreview)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(model.settings.theme.uiForeground.opacity(0.85))
                            .lineSpacing(7)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if annotation.hasDrawing {
                        Text("Visual note")
                            .font(.system(size: 12))
                            .foregroundStyle(model.settings.theme.muted)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 8) {
                Text("\(chapterLabel(for: annotation))  ·  \(annotation.createdAt, format: .dateTime.month(.abbreviated).day().year())")
                    .font(.system(size: 9))
                    .lineSpacing(4)
                    .foregroundStyle(model.settings.theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Created " + annotation.createdAt.formatted(date: .complete, time: .shortened))

                Spacer(minLength: 0)

                if annotation.hasDrawing {
                    Image(systemName: "scribble")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(model.settings.theme.muted)
                        .frame(width: 20, height: 20)
                        .help(annotation.sketches.isEmpty ? "Visual note" : "\(annotation.sketches.count) sketches")
                }
                if !annotation.audioRecordings.isEmpty {
                    Image(systemName: "mic")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(model.settings.theme.muted)
                        .frame(width: 20, height: 20)
                        .help("\(annotation.audioRecordings.count) audio recordings")
                }

                Button { onEdit(annotation) } label: {
                    Image(systemName: annotation.hasContent ? "note.text" : "square.and.pencil")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(model.settings.theme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(annotation.hasContent ? "Edit note" : "Add note")
                .quickHelp(annotation.hasContent ? "Edit note" : "Add note")
            }
        }
        .contextMenu {
            Button(annotation.hasContent ? "Edit Note…" : "Add Note…") { onEdit(annotation) }
            Button("Copy Quote") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(annotation.text, forType: .string)
            }
            if annotation.hasNote {
                Button("Copy Note") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(annotation.note ?? "", forType: .string)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete(annotation) }
        }
    }

    private func chapterLabel(for annotation: Annotation) -> String {
        if let chapter = annotation.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !chapter.isEmpty {
            return chapter
        }
        let unit = annotation.locator.kind == .pdf ? "Page" : "Chapter"
        return "\(unit) \(annotation.locator.spineIndex + 1)"
    }
}

/// File exports use importable formats without requiring account access.
@MainActor
enum NotesExporter {
    struct Output {
        var data: Data
        var assets: [String: Data]
        var fileAssets: [String: URL] = [:]
    }

    static func output(format: NoteExportFormat, bookTitle: String, author: String, annotations: [Annotation], sketchImages: [UUID: Data] = [:], audioFiles: [UUID: URL] = [:], reminders: [ResearchReminder] = [], assetDirectory: String = "Sketches") throws -> Output {
        let references = annotations.flatMap { SketchReference.references(in: $0.note ?? "") }
        for reference in references where sketchImages[reference.id] == nil {
            throw NSError(domain: "KodiExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "The image for \(reference.title) is unavailable. Sync the sketch and try again."])
        }
        let audioReferences = annotations.flatMap { AudioReference.references(in: $0.note ?? "") }
        var fileAssets: [String: URL] = [:]
        var audioPaths: [UUID: String] = [:]
        let pathCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        for reference in audioReferences {
            guard let source = audioFiles[reference.id], source.isFileURL,
                  let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw NSError(domain: "KodiExport", code: 4, userInfo: [NSLocalizedDescriptionKey: "The recording for \(reference.title) is unavailable. Sync the audio and try again."])
            }
            let path = assetDirectory + "/" + reference.id.uuidString + ".m4a"
            fileAssets[path] = source
            audioPaths[reference.id] = path.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? path
        }
        switch format {
        case .markdown, .notion:
            var assets: [String: Data] = [:]
            var notes = annotations
            for index in notes.indices {
                let recordings = Dictionary(annotations[index].audioRecordings.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                notes[index].note = SketchReference.replacing(in: notes[index].note ?? "") { reference in
                    let path = assetDirectory + "/" + reference.id.uuidString + ".png"
                    assets[path] = sketchImages[reference.id]
                    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                    let title = reference.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
                    return "![\(title)](\(encoded))"
                }
                let audioSource = notes[index].note ?? ""
                let transcriptLocations = Dictionary(AudioReference.references(in: audioSource).map { ($0.id, $0.range.location) }, uniquingKeysWith: min)
                notes[index].note = AudioReference.replacing(in: audioSource) { reference in
                    let title = reference.title.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
                    let transcript = transcriptLocations[reference.id] == reference.range.location
                        ? transcriptMarkdown(recordings[reference.id]?.transcript) : ""
                    return "[\(title)](\(audioPaths[reference.id]!))" + transcript
                }
            }
            return Output(data: Data(NoteMarkdown.exportDocument(bookTitle: bookTitle, author: author, annotations: notes, reminders: reminders).utf8), assets: assets, fileAssets: fileAssets)
        case .appleNotes:
            return Output(data: Data(NoteExport.html(bookTitle: bookTitle, author: author, annotations: annotations, sketchImages: sketchImages, audioPaths: audioPaths, reminders: reminders).utf8), assets: [:], fileAssets: fileAssets)
        case .word:
            // Keep prose formatting, then embed images directly in the OOXML package.
            // AppKit's DOCX writer drops native image attachments.
            var notes = annotations
            var placeholders: [String: (UUID, String)] = [:]
            var audioLinks: [SketchDOCX.Link] = []
            for index in notes.indices {
                let recordings = Dictionary(annotations[index].audioRecordings.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                notes[index].note = SketchReference.replacing(in: notes[index].note ?? "") { reference in
                    let marker = "KODISKETCH" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    placeholders[marker] = (reference.id, reference.title)
                    return marker + "\n\n" + reference.title
                }
                let audioSource = notes[index].note ?? ""
                let transcriptLocations = Dictionary(AudioReference.references(in: audioSource).map { ($0.id, $0.range.location) }, uniquingKeysWith: min)
                notes[index].note = AudioReference.replacing(in: audioSource) { reference in
                    let marker = "KODIAUDIO" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    audioLinks.append(SketchDOCX.Link(marker: marker, title: reference.title, target: audioPaths[reference.id]!))
                    let transcript = transcriptLocations[reference.id] == reference.range.location
                        ? transcriptMarkdown(recordings[reference.id]?.transcript) : ""
                    return marker + transcript
                }
            }
            let html = Data(NoteExport.html(bookTitle: bookTitle, author: author, annotations: notes, audioPlayers: false, reminders: reminders).utf8)
            let document = try NSMutableAttributedString(data: html, options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ], documentAttributes: nil)
            var embedded: [SketchDOCX.Image] = []
            for (marker, value) in placeholders.sorted(by: { $0.key < $1.key }) {
                guard let png = sketchImages[value.0], let image = NSImage(data: png) else {
                    throw NSError(domain: "KodiExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "A sketch image could not be decoded."])
                }
                let range = (document.string as NSString).range(of: marker)
                guard range.location != NSNotFound else { throw NSError(domain: "KodiExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "A sketch's position was lost while exporting."]) }
                let scale = min(1, 460 / max(1, image.size.width), 600 / max(1, image.size.height))
                embedded.append(SketchDOCX.Image(marker: marker, title: value.1, png: png, width: image.size.width * scale, height: image.size.height * scale))
            }
            let prose = try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [
                .documentType: NSAttributedString.DocumentType.officeOpenXML,
            ])
            return Output(data: try SketchDOCX.embedding(embedded, in: prose, links: audioLinks), assets: [:], fileAssets: fileAssets)
        }
    }

    /// Speech and edited transcripts are literal prose, not executable HTML or
    /// Markdown supplied by an imported document. Keep their visible text intact.
    private static func transcriptMarkdown(_ transcript: String?) -> String {
        guard let transcript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty else { return "" }
        let text = transcript.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var literal = ""
        for character in text {
            if "\\`*_[]<>#|!()+-.".contains(character) { literal.append("\\") }
            literal.append(character)
        }
        return "\n\n**Transcript**\n\n" + literal
    }

    static func data(format: NoteExportFormat, bookTitle: String, author: String, annotations: [Annotation], sketchImages: [UUID: Data] = [:], audioFiles: [UUID: URL] = [:], reminders: [ResearchReminder] = []) throws -> Data {
        try output(format: format, bookTitle: bookTitle, author: author, annotations: annotations, sketchImages: sketchImages, audioFiles: audioFiles, reminders: reminders).data
    }

    /// Stage the document and its file-backed audio before replacing an existing
    /// export. A failed copy or commit leaves the previous document and assets intact.
    static func write(_ output: Output, to url: URL) throws {
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".kodi-export-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var removeStaging = true
        defer { if removeStaging { try? manager.removeItem(at: staging) } }
        let paths = Set(output.assets.keys).union(output.fileAssets.keys)
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), components.count >= 2,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains("\\") else {
                throw NSError(domain: "KodiExport", code: 5, userInfo: [NSLocalizedDescriptionKey: "An export asset has an invalid destination."])
            }
        }
        let roots = Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) })
        for root in roots {
            let existing = parent.appendingPathComponent(root)
            let destination = staging.appendingPathComponent(root)
            guard root != url.lastPathComponent,
                  (try? existing.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw NSError(domain: "KodiExport", code: 5, userInfo: [NSLocalizedDescriptionKey: "The companion assets folder must be a separate regular folder."])
            }
            // Preserve files that may already share the companion folder.
            if manager.fileExists(atPath: existing.path) { try manager.copyItem(at: existing, to: destination) }
        }
        for path in paths.sorted() {
            let destination = staging.appendingPathComponent(path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            if let data = output.assets[path] { try data.write(to: destination, options: .atomic) }
            else if let source = output.fileAssets[path] { try manager.copyItem(at: source, to: destination) }
        }
        let document = staging.appendingPathComponent("document")
        try output.data.write(to: document, options: .atomic)
        let backups = staging.appendingPathComponent("backups", isDirectory: true)
        try manager.createDirectory(at: backups, withIntermediateDirectories: true)
        var published: [URL] = []
        var saved: [(URL, URL)] = []
        do {
            for root in roots.sorted() {
                let destination = parent.appendingPathComponent(root)
                if manager.fileExists(atPath: destination.path) {
                    let backup = backups.appendingPathComponent(UUID().uuidString)
                    try manager.moveItem(at: destination, to: backup)
                    saved.append((backup, destination))
                }
                try manager.moveItem(at: staging.appendingPathComponent(root), to: destination)
                published.append(destination)
            }
            if manager.fileExists(atPath: url.path) {
                let backup = backups.appendingPathComponent(UUID().uuidString)
                try manager.moveItem(at: url, to: backup)
                saved.append((backup, url))
            }
            try manager.moveItem(at: document, to: url)
        } catch {
            var restored = true
            for destination in published.reversed() {
                do { try manager.removeItem(at: destination) } catch { restored = false }
            }
            for (backup, destination) in saved.reversed() {
                do { try manager.moveItem(at: backup, to: destination) } catch { restored = false }
            }
            if !restored {
                removeStaging = false
                throw NSError(domain: "KodiExport", code: 6, userInfo: [NSLocalizedDescriptionKey: "The export could not finish. Previous files are preserved in \(staging.path)."])
            }
            throw error
        }
    }

    static func presentSavePanel(format: NoteExportFormat, bookTitle: String, author: String, annotations: [Annotation], sketchImages: [UUID: Data] = [:], audioFiles: [UUID: URL] = [:], reminders: [ResearchReminder] = []) {
        let panel = NSSavePanel()
        let contentType = UTType(filenameExtension: format.fileExtension) ?? .data
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let safeTitle = bookTitle.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        panel.nameFieldStringValue = "Notes — \(safeTitle).\(format.fileExtension)"
        panel.title = "Export notes"
        panel.message = format.instructions

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let assetDirectory = url.deletingPathExtension().lastPathComponent + "-assets"
            let output = try output(format: format, bookTitle: bookTitle, author: author, annotations: annotations,
                                    sketchImages: sketchImages, audioFiles: audioFiles, reminders: reminders, assetDirectory: assetDirectory)
            try write(output, to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t export notes"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
