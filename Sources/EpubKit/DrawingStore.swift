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

    /// Debounced atomic write. Call `flush()` before quitting or closing a note.
    public func saveScene(_ data: Data, bookID: String, annotationID: UUID) {
        lock.lock()
        pendingSaves[annotationID]?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.write(data, bookID: bookID, annotationID: annotationID)
            self?.lock.lock()
            self?.pendingSaves[annotationID] = nil
            self?.lock.unlock()
        }
        pendingSaves[annotationID] = PendingScene(data: data, bookID: bookID, work: work)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes any pending scenes immediately.
    public func flush() {
        lock.lock()
        let pending = pendingSaves
        pendingSaves.removeAll()
        lock.unlock()
        for (annotationID, scene) in pending {
            scene.work.cancel()
            write(scene.data, bookID: scene.bookID, annotationID: annotationID)
        }
    }

    public func deleteScene(bookID: String, annotationID: UUID) {
        lock.lock()
        pendingSaves[annotationID]?.work.cancel()
        pendingSaves[annotationID] = nil
        lock.unlock()
        let url = sceneURL(bookID: bookID, annotationID: annotationID)
        try? FileManager.default.removeItem(at: url)
    }

