import EpubKit
import SwiftUI

/// The same controls are hosted over native text attachments and in Preview.
@MainActor
struct AudioNoteEditorContext {
    let controller: AudioNoteController
    var recordings: [UUID: NoteAudio]
    var fileURL: (UUID) -> URL?
    var onRename: (UUID) -> Void
    var onExport: (UUID) -> Void
    var onDelete: (UUID) -> Void
    var draftID: UUID?
    var draftError: String?
    var onFinishDraft: () -> Void
    var onDiscardDraft: () -> Void
    var transcription: AudioTranscriptionController? = nil
    var transcriptionScope: AudioTranscriptionScope? = nil
    var transcriptionBusyID: UUID? = nil
    var transcriptionErrors: [UUID: String] = [:]
    var expandedTranscripts: Set<UUID> = []
    var onTranscribe: ((UUID) -> Void)? = nil
    var onToggleTranscript: ((UUID) -> Void)? = nil

    func player(id: UUID, title: String, isDark: Bool) -> some View {
        var recording = recordings[id] ?? NoteAudio(id: id, title: title, duration: 0, createdAt: .distantPast)
        recording.title = title
        return AudioNoteStrip(audio: recording,
                       url: fileURL(id), controller: controller, isDark: isDark,
                       onRename: { onRename(id) }, onExport: { onExport(id) }, onDelete: { onDelete(id) },
                       transcription: transcription, transcriptionScope: transcriptionScope,
                       expanded: expandedTranscripts.contains(id),
                       onTranscribe: onTranscribe.map { action in { action(id) } },
                       onToggleTranscript: onToggleTranscript.map { action in { action(id) } },
                       transcriptionError: transcriptionErrors[id])
    }

    func height(id: UUID, title: String, isDraft: Bool) -> CGFloat {
        if isDraft { return draftError == nil ? 44 : 70 }
        let audio = recordings[id] ?? NoteAudio(id: id, title: title)
        return AudioNoteCardLayout.height(audio: audio, expanded: expandedTranscripts.contains(id),
                                         hasStatus: transcriptionBusyID == id || transcriptionErrors[id] != nil)
    }

    func recorder(isDark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AudioRecordingStrip(controller: controller, isDark: isDark,
                                onDone: onFinishDraft, onDiscard: onDiscardDraft)
            if let draftError {
                HStack(spacing: 8) {
                    Text(draftError).lineLimit(1).help(draftError)
                    Spacer(minLength: 0)
                    Button("Retry", action: onFinishDraft)
                    Button("Discard", action: onDiscardDraft)
                }
                .font(.system(size: 11))
                .foregroundStyle(isDark ? Color(red: 0.95, green: 0.79, blue: 0.41) : Color(red: 0.48, green: 0.34, blue: 0.06))
                .padding(.horizontal, 8)
            }
        }
    }
}

/// An editor-only anchor; it is never a playable reference in the saved note.
enum AudioDraftReference {
    static func marker(_ id: UUID) -> String { "<!--kodi-audio-draft:\(id.uuidString)-->" }

    static func parse(_ line: String) -> UUID? {
        let prefix = "<!--kodi-audio-draft:"
        guard line.hasPrefix(prefix), line.hasSuffix("-->") else { return nil }
        return UUID(uuidString: String(line.dropFirst(prefix.count).dropLast(3)))
    }

    static func removing(_ id: UUID?, from note: String) -> String {
        guard let id else { return note }
        return note.replacingOccurrences(of: marker(id), with: "")
    }
}

/// Keep file-backed clipboard copies alive when Cut removes the source note's
/// last reference. The next media copy or normal app exit releases this cache.
@MainActor
enum AudioNoteClipboard {
    private static var directory: URL?
    private static var recordings: [UUID: (NoteAudio, URL)] = [:]

    static func retain(_ markdown: String, context: AudioNoteEditorContext?) {
        clear()
        guard let context else { return }
        let references = AudioReference.references(in: markdown)
        guard !references.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KodiAudioClipboard-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            for reference in references where recordings[reference.id] == nil {
                guard let metadata = context.recordings[reference.id], let source = context.fileURL(reference.id) else { continue }
                let copy = folder.appendingPathComponent(reference.id.uuidString + ".m4a")
                try FileManager.default.copyItem(at: source, to: copy)
                recordings[reference.id] = (metadata, copy)
            }
        } catch {
            // The Markdown still copies normally; unavailable assets keep the
            // same explicit unavailable state as a deferred synced recording.
        }
    }

    static func importing(into annotation: Annotation, note: String, audio: AudioStore, bookID: String) throws -> Annotation {
        var updated = annotation
        var created: [UUID] = []
        do {
            for reference in AudioReference.references(in: note) where !updated.audioRecordings.contains(where: { $0.id == reference.id }) {
                guard let archived = recordings[reference.id] else { continue }
                var metadata = archived.0
                let source = archived.1
                let target = audio.recordingURL(bookID: bookID, annotationID: annotation.id, audioID: reference.id)
                let existed = FileManager.default.fileExists(atPath: target.path)
                try audio.saveRecording(from: source, bookID: bookID, annotationID: annotation.id, audioID: reference.id)
                if !existed { created.append(reference.id) }
                metadata.title = reference.title
                updated.audioRecordings.append(metadata)
            }
            return updated
        } catch {
            for id in created { try? audio.deleteRecording(bookID: bookID, annotationID: annotation.id, audioID: id) }
            throw error
        }
    }

    static func clear() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        recordings.removeAll()
    }
}
