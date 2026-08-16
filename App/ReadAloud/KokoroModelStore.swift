import Foundation

/// Downloads and caches the Kokoro weights and voice pack in Application Support.
enum KokoroModelStore {
    static let modelFileName = "kokoro-v1_0.safetensors"
    static let voicesFileName = "voices.npz"

    private static let modelURL = URL(
        string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors?download=true"
    )!
    private static let voicesURL = URL(
        string: "https://github.com/mlalma/KokoroTestApp/raw/main/Resources/voices.npz"
    )!

    private static let minimumModelBytes: Int64 = 80_000_000
    private static let minimumVoicesBytes: Int64 = 1_000_000

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("EpubReader", isDirectory: true)
            .appendingPathComponent("Kokoro", isDirectory: true)
    }

    static var modelPath: URL {
        directory.appendingPathComponent(modelFileName)
    }

    static var voicesPath: URL {
        directory.appendingPathComponent(voicesFileName)
    }

    static var isReady: Bool {
        fileExists(modelPath, minimum: minimumModelBytes)
            && fileExists(voicesPath, minimum: minimumVoicesBytes)
    }

    /// Ensures both files are on disk. `progress` is a fraction 0...1 when known.
    static func ensureAvailable(
        progress: @escaping @Sendable (_ message: String, _ fraction: Double?) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if isReady {
            progress("Voice model ready", 1)
            return
        }

        if !fileExists(modelPath, minimum: minimumModelBytes) {
            progress("Downloading voice model…", nil)
            try await download(modelURL, to: modelPath, minimum: minimumModelBytes, label: "voice model") { message, fraction in
                progress(message, fraction.map { $0 * 0.95 })
            }
        } else {
            progress("Downloading voices…", 0.95)
        }

        if !fileExists(voicesPath, minimum: minimumVoicesBytes) {
            try await download(voicesURL, to: voicesPath, minimum: minimumVoicesBytes, label: "voices") { message, fraction in
                progress(message, fraction.map { 0.95 + $0 * 0.05 })
            }
        }
        progress("Voice model ready", 1)
    }

    private static func fileExists(_ url: URL, minimum: Int64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return false }
        return Int64(size) >= minimum
    }

    private static func download(
        _ remote: URL,
        to destination: URL,
        minimum: Int64,
        label: String,
        progress: @escaping @Sendable (_ message: String, _ fraction: Double?) -> Void
    ) async throws {
        try await FileDownloader.download(from: remote, to: destination, label: label, progress: progress)
        guard fileExists(destination, minimum: minimum) else {
            try? FileManager.default.removeItem(at: destination)
            throw KokoroModelError.incompleteDownload(destination.lastPathComponent)
        }
    }
}

enum KokoroModelError: LocalizedError, Sendable {
    case incompleteDownload(String)
    case engineUnavailable
    case missingVoice(String)
    case emptyChapter
    case requiresAppleSilicon
    case httpFailure(Int)
    case timedOut
    case loadTimedOut

    var errorDescription: String? {
        switch self {
        case .incompleteDownload(let name):
            return "The downloaded file “\(name)” was incomplete. Check the network and try again."
        case .engineUnavailable:
            return "The read-aloud engine could not start."
        case .missingVoice(let id):
            return "The voice “\(id)” is not in the downloaded voice pack."
        case .emptyChapter:
            return "This page has no readable text."
        case .requiresAppleSilicon:
            return "Read-aloud needs an Apple Silicon Mac."
        case .httpFailure(let code):
            return "Download failed (HTTP \(code)). Try again in a moment."
        case .timedOut:
            return "The download timed out. Check the network and try again."
        case .loadTimedOut:
            return "Loading the voice model took too long. Try again."
        }
    }
}

/// URLSession download with byte-level progress and HTTP status checks.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var progress: ((String, Double?) -> Void)?
    private var session: URLSession?
    private var label = "file"
    private var downloadResult: Result<Void, Error>?

    static func download(
        from remote: URL,
        to destination: URL,
        label: String,
        progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws {
        let downloader = FileDownloader()
        try await downloader.run(remote: remote, destination: destination, label: label, progress: progress)
    }

    private func run(
        remote: URL,
        destination: URL,
        label: String,
        progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.destination = destination
            self.progress = progress
            self.label = label

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 8 * 60
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: remote)
            request.setValue(
                "KodiReader/1.0 (Macintosh; Intel Mac OS X) gzip",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progress?("Downloading \(label)… \(Int(fraction * 100))%", fraction)
        } else {
            progress?("Downloading \(label)… \(Self.formatBytes(totalBytesWritten))", nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            downloadResult = .failure(KokoroModelError.httpFailure(http.statusCode))
            return
        }
        if let mime = downloadTask.response?.mimeType?.lowercased(), mime.contains("html") {
            downloadResult = .failure(
                KokoroModelError.incompleteDownload(destination?.lastPathComponent ?? label)
            )
            return
        }

        guard let destination else {
            downloadResult = .failure(URLError(.cannotCreateFile))
            return
        }

        do {
            let staging = destination.appendingPathExtension("download")
            let files = FileManager.default
            if files.fileExists(atPath: staging.path) {
                try files.removeItem(at: staging)
            }
            try files.copyItem(at: location, to: staging)
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: destination)
            }
            try files.moveItem(at: staging, to: destination)
            downloadResult = .success(())
        } catch {
            downloadResult = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .timedOut {
                finish(.failure(KokoroModelError.timedOut))
            } else {
                finish(.failure(error))
            }
            return
        }
        finish(downloadResult ?? .failure(URLError(.unknown)))
    }

    private func finish(_ result: Result<Void, Error>) {
        session?.finishTasksAndInvalidate()
        session = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 10 {
            return "\(Int(mb)) MB"
        }
        return String(format: "%.1f MB", mb)
    }
}
