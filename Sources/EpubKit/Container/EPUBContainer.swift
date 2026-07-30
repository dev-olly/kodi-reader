import Foundation
import ZIPFoundation

/// Random-access reader for the ZIP archive backing an EPUB.
///
/// Resources are read on demand rather than extracted to disk, so opening a
/// book costs only the package document and navigation parse.
public final class EPUBContainer: @unchecked Sendable {
    public let fileURL: URL

    private let archive: Archive
    private let lock = NSLock()
    /// Lowercased entry path to actual entry, so lookups survive the case
    /// mismatches that appear in hand-rolled EPUBs.
    private let entriesByLowercasedPath: [String: Entry]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL

        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw EPUBError.notAZipArchive(fileURL)
        }

        var index: [String: Entry] = [:]
        for entry in archive where entry.type == .file {
            index[entry.path.lowercased()] = entry
        }
        entriesByLowercasedPath = index
    }

    public func contains(_ path: String) -> Bool {
        entry(for: path) != nil
    }

    /// Uncompressed byte count, used to weight chapters in the progress bar
    /// so that a long chapter advances it more than a short one.
    public func uncompressedSize(at path: String) -> Int {
        Int(entry(for: path)?.uncompressedSize ?? 0)
    }

    /// Raw bytes of an archive entry.
    public func data(at path: String) throws -> Data {
        guard let entry = entry(for: path) else {
            throw EPUBError.resourceNotFound(path)
        }

        lock.lock()
        defer { lock.unlock() }

        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: true) { chunk in
                data.append(chunk)
            }
        } catch {
            throw EPUBError.resourceNotFound(path)
        }
        return data
    }

    /// Entry contents decoded as text, tolerating the handful of encodings
    /// that show up in older EPUBs.
    public func string(at path: String) throws -> String {
        let data = try data(at: path)
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw EPUBError.malformedXML(path: path, reason: "unrecognised text encoding")
    }

    private func entry(for path: String) -> Entry? {
        let normalized = EPUBPath.normalize(path)
        if let entry = entriesByLowercasedPath[normalized.lowercased()] {
            return entry
        }
        // Some archives store paths with percent-encoding intact.
        if let decoded = normalized.removingPercentEncoding {
            return entriesByLowercasedPath[decoded.lowercased()]
        }
        return nil
    }
}
