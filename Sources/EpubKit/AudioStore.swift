import Foundation

/// File-backed note recordings. No audio bytes are loaded into library.json.
public final class AudioStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let queue = DispatchQueue(label: "audio-store", qos: .utility)

    public init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

    public var recordingsDirectory: URL {
        rootDirectory.appendingPathComponent("Audio", isDirectory: true)
    }

    public func recordingURL(bookID: String, annotationID: UUID, audioID: UUID) -> URL {
        annotationDirectory(bookID: bookID, annotationID: annotationID)
            .appendingPathComponent(audioID.uuidString + ".m4a")
    }

    /// Copy first, then atomically publish the complete file. The draft is kept
    /// until the caller also commits its annotation metadata successfully.
    public func saveRecording(from source: URL, bookID: String, annotationID: UUID, audioID: UUID) throws {
        try queue.sync {
            try Self.copyAtomically(from: source, to: recordingURL(bookID: bookID, annotationID: annotationID, audioID: audioID))
        }
    }

    public func deleteRecording(bookID: String, annotationID: UUID, audioID: UUID) throws {
        try queue.sync {
            let url = recordingURL(bookID: bookID, annotationID: annotationID, audioID: audioID)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    public func deleteRecordings(bookID: String, annotationID: UUID) {
        queue.sync { _ = try? FileManager.default.removeItem(at: annotationDirectory(bookID: bookID, annotationID: annotationID)) }
    }

    public func deleteAllRecordings(bookID: String) {
        queue.sync { _ = try? FileManager.default.removeItem(at: bookDirectory(bookID: bookID)) }
    }

    private func bookDirectory(bookID: String) -> URL {
        recordingsDirectory.appendingPathComponent(LibraryStore.sanitizedFileName(for: bookID), isDirectory: true)
    }

    private func annotationDirectory(bookID: String, annotationID: UUID) -> URL {
        bookDirectory(bookID: bookID).appendingPathComponent(annotationID.uuidString, isDirectory: true)
    }

    fileprivate func undoDirectory(session: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(".Undo", isDirectory: true)
            .appendingPathComponent(session.uuidString, isDirectory: true)
    }

    fileprivate static func copyAtomically(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        // URL resource values can cache a draft's old size as it is rewritten.
        let attributes = try manager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw NSError(domain: "KodiAudio", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The recorded audio file is empty or unavailable."])
        }
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }
}

/// Retain removed recordings on disk for the lifetime of native note Undo.
/// The caller deletes live files only after checkpointing the returned metadata.
public final class AudioUndoHistory {
    private struct ArchivedAudio {
        var recording: NoteAudio
        var file: URL?
    }

    private let session = UUID()
    private var archiveDirectory: URL?
    private var archived: [UUID: ArchivedAudio] = [:]
    public init() {}
    deinit { discard() }

    public func reconciling(_ annotation: Annotation, note: String, audio: AudioStore, bookID: String) throws -> Annotation {
        let references = Set(AudioReference.references(in: note).map(\.id))
        var updated = annotation
        for recording in annotation.audioRecordings where !references.contains(recording.id) {
            let source = audio.recordingURL(bookID: bookID, annotationID: annotation.id, audioID: recording.id)
            var savedFile = archived[recording.id]?.file
            if FileManager.default.fileExists(atPath: source.path) {
                let directory = audio.undoDirectory(session: session)
                archiveDirectory = directory
                let destination = directory.appendingPathComponent(recording.id.uuidString + ".m4a")
                try AudioStore.copyAtomically(from: source, to: destination)
                savedFile = destination
            }
            archived[recording.id] = ArchivedAudio(recording: recording, file: savedFile)
        }
        updated.audioRecordings.removeAll { !references.contains($0.id) }
        for id in references where !updated.audioRecordings.contains(where: { $0.id == id }) {
            if let saved = archived[id] {
                if let source = saved.file {
                    try audio.saveRecording(from: source, bookID: bookID, annotationID: annotation.id, audioID: id)
                }
                updated.audioRecordings.append(saved.recording)
            }
        }
        updated.audioRecordings.sort { $0.createdAt < $1.createdAt }
        updated.note = note.isEmpty ? nil : note
        return updated
    }

    public func discard() {
        if let archiveDirectory { try? FileManager.default.removeItem(at: archiveDirectory) }
        archiveDirectory = nil
        archived.removeAll()
    }
}
