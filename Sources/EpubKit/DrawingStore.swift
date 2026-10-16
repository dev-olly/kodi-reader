import Foundation

/// Sidecar files for Excalidraw scenes, one JSON file per annotation.
///
/// Scenes live outside `library.json` because they can be large (especially
/// with embedded images) and the library file is decoded on every launch.
public final class DrawingStore: @unchecked Sendable {
    private struct PendingScene {
        var data: Data
        var bookID: String
        var work: DispatchWorkItem
        var completion: ((Result<Void, Error>) -> Void)?
    }

    private let rootDirectory: URL
    private let queue = DispatchQueue(label: "drawing-store", qos: .utility)
    private let lock = NSLock()
    private var pendingSaves: [UUID: PendingScene] = [:]

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var drawingsDirectory: URL {
        rootDirectory.appendingPathComponent("Drawings", isDirectory: true)
    }

    public func sceneURL(bookID: String, annotationID: UUID) -> URL {
        bookDirectory(for: bookID)
            .appendingPathComponent("\(annotationID.uuidString).excalidraw.json")
    }

    public func loadScene(bookID: String, annotationID: UUID) -> Data? {
        let url = sceneURL(bookID: bookID, annotationID: annotationID)
        return try? Data(contentsOf: url)
    }

    public func sketchDirectory(bookID: String, annotationID: UUID) -> URL {
        bookDirectory(for: bookID).appendingPathComponent(annotationID.uuidString, isDirectory: true)
    }

    public func sceneURL(bookID: String, annotationID: UUID, sketchID: UUID) -> URL {
        sketchDirectory(bookID: bookID, annotationID: annotationID).appendingPathComponent("\(sketchID.uuidString).excalidraw.json")
    }

    public func previewURL(bookID: String, annotationID: UUID, sketchID: UUID) -> URL {
        sketchDirectory(bookID: bookID, annotationID: annotationID).appendingPathComponent("\(sketchID.uuidString).png")
    }

    public func loadScene(bookID: String, annotationID: UUID, sketchID: UUID) -> Data? {
        try? Data(contentsOf: sceneURL(bookID: bookID, annotationID: annotationID, sketchID: sketchID))
    }

    public func loadPreview(bookID: String, annotationID: UUID, sketchID: UUID) -> Data? {
        try? Data(contentsOf: previewURL(bookID: bookID, annotationID: annotationID, sketchID: sketchID))
    }

    public func replaceSketch(scene: Data, preview: Data?, bookID: String, annotationID: UUID, sketchID: UUID) throws {
        try queue.sync {
            let url = sceneURL(bookID: bookID, annotationID: annotationID, sketchID: sketchID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try scene.write(to: url, options: .atomic)
            let image = previewURL(bookID: bookID, annotationID: annotationID, sketchID: sketchID)
            if let preview { try preview.write(to: image, options: .atomic) }
            else if FileManager.default.fileExists(atPath: image.path) { try FileManager.default.removeItem(at: image) }
        }
    }

    public func deleteSketch(bookID: String, annotationID: UUID, sketchID: UUID) throws {
        try queue.sync {
            for url in [sceneURL(bookID: bookID, annotationID: annotationID, sketchID: sketchID), previewURL(bookID: bookID, annotationID: annotationID, sketchID: sketchID)] {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    public func deleteSketches(bookID: String, annotationID: UUID) {
        queue.sync { _ = try? FileManager.default.removeItem(at: sketchDirectory(bookID: bookID, annotationID: annotationID)) }
    }

    /// Prepare a repeatable migration; the caller commits the returned metadata.
    /// Keep the legacy file until its replacement and library checkpoint succeed.
    public func migratingLegacyDrawing(_ annotation: Annotation, bookID: String) throws -> Annotation {
        guard annotation.hasDrawing, annotation.sketches.isEmpty else { return annotation }
        var updated = annotation
        let sketch = NoteSketch(id: annotation.id, title: "Sketch 1", createdAt: annotation.createdAt, modifiedAt: annotation.modifiedAt)
        if let scene = loadScene(bookID: bookID, annotationID: annotation.id) {
            try replaceSketch(scene: scene, preview: nil, bookID: bookID, annotationID: annotation.id, sketchID: sketch.id)
        }
        updated.sketches = [sketch]
        let note = annotation.note ?? ""
        updated.note = note + (note.isEmpty ? "" : "\n\n") + sketch.markdown
        return updated
    }

    /// Debounced atomic write. Call `flush()` before quitting or closing a note.
    public func saveScene(
        _ data: Data,
        bookID: String,
        annotationID: UUID,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        lock.lock()
        pendingSaves[annotationID]?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try self?.write(data, bookID: bookID, annotationID: annotationID) }
            self?.lock.lock()
            self?.pendingSaves[annotationID] = nil
            self?.lock.unlock()
            DispatchQueue.main.async {
                completion?(result.map { _ in () })
            }
        }
        pendingSaves[annotationID] = PendingScene(
            data: data,
            bookID: bookID,
            work: work,
            completion: completion
        )
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Commit an editor checkpoint before updating its annotation metadata.
    public func replaceScene(_ data: Data?, bookID: String, annotationID: UUID) throws {
        lock.lock()
        pendingSaves[annotationID]?.work.cancel()
        pendingSaves[annotationID] = nil
        lock.unlock()
        // Serialize with previously scheduled writes before checkpointing metadata.
        try queue.sync {
            if let data { try write(data, bookID: bookID, annotationID: annotationID) }
            else {
                let url = sceneURL(bookID: bookID, annotationID: annotationID)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    /// Writes any pending scenes immediately.
    public func flush() {
        lock.lock()
        let pending = pendingSaves
        pendingSaves.removeAll()
        lock.unlock()
        for (annotationID, scene) in pending {
            scene.work.cancel()
            let result = Result { try write(scene.data, bookID: scene.bookID, annotationID: annotationID) }
            DispatchQueue.main.async {
                scene.completion?(result.map { _ in () })
            }
        }
    }

    public func deleteScene(
        bookID: String,
        annotationID: UUID,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        lock.lock()
        pendingSaves[annotationID]?.work.cancel()
        pendingSaves[annotationID] = nil
        lock.unlock()
        deleteSketches(bookID: bookID, annotationID: annotationID)
        let url = sceneURL(bookID: bookID, annotationID: annotationID)
        let result = Result {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        DispatchQueue.main.async {
            completion?(result.map { _ in () })
        }
    }

    public func deleteAllScenes(bookID: String) {
        lock.lock()
        let ids = pendingSaves.compactMap { id, scene in
            scene.bookID == bookID ? id : nil
        }
        for id in ids {
            pendingSaves[id]?.work.cancel()
            pendingSaves[id] = nil
        }
        lock.unlock()
        try? FileManager.default.removeItem(at: bookDirectory(for: bookID))
    }

    private func bookDirectory(for bookID: String) -> URL {
        drawingsDirectory.appendingPathComponent(
            LibraryStore.sanitizedFileName(for: bookID),
            isDirectory: true
        )
    }

    private func write(_ data: Data, bookID: String, annotationID: UUID) throws {
        let directory = bookDirectory(for: bookID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = sceneURL(bookID: bookID, annotationID: annotationID)
        try data.write(to: url, options: .atomic)
    }
}

/// Retain deleted resources for the lifetime of the note's native undo manager.
/// Restoration writes assets before the caller publishes restored references.
public final class SketchUndoHistory {
    private struct ArchivedSketch {
        var sketch: NoteSketch
        var scene: Data?
        var preview: Data?
    }
    private var archived: [UUID: ArchivedSketch] = [:]
    public init() {}

    public func reconciling(_ annotation: Annotation, note: String, drawings: DrawingStore, bookID: String) throws -> Annotation {
        let references = Set(SketchReference.references(in: note).map(\.id))
        var updated = annotation
        for sketch in annotation.sketches where !references.contains(sketch.id) {
            archived[sketch.id] = ArchivedSketch(sketch: sketch,
                scene: drawings.loadScene(bookID: bookID, annotationID: annotation.id, sketchID: sketch.id),
                preview: drawings.loadPreview(bookID: bookID, annotationID: annotation.id, sketchID: sketch.id))
        }
        updated.sketches.removeAll { !references.contains($0.id) }
        for id in references where !updated.sketches.contains(where: { $0.id == id }) {
            if let saved = archived[id] {
                if let scene = saved.scene {
                    try drawings.replaceSketch(scene: scene, preview: saved.preview, bookID: bookID, annotationID: annotation.id, sketchID: id)
                }
                updated.sketches.append(saved.sketch)
            }
        }
        updated.sketches.sort { $0.createdAt < $1.createdAt }
        updated.hasDrawing = !updated.sketches.isEmpty
        updated.note = note.isEmpty ? nil : note
        return updated
    }
}
