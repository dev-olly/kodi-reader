import Foundation

public enum EPUBError: LocalizedError, Equatable {
    case notAZipArchive(URL)
    /// The file exists (or did) but the process cannot read it — typical when
    /// a sandboxed app loses its security-scoped bookmark.
    case cannotAccessFile(URL)
    case missingContainerXML
    case missingRootFile
    case missingOPF(String)
    case malformedXML(path: String, reason: String)
    case emptySpine
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .notAZipArchive(url):
            return "\"\(url.lastPathComponent)\" is not a readable EPUB archive."
        case let .cannotAccessFile(url):
            return "Folio doesn’t have permission to read \"\(url.lastPathComponent)\". Open it again with File → Open, or choose Locate when prompted from Recents."
        case .missingContainerXML:
            return "The archive is missing META-INF/container.xml, so it is not a valid EPUB."
        case .missingRootFile:
            return "META-INF/container.xml does not point to a package document."
        case let .missingOPF(path):
            return "The package document could not be read at \(path)."
        case let .malformedXML(path, reason):
            return "Could not parse \(path): \(reason)"
        case .emptySpine:
            return "The book declares no readable content."
        case let .resourceNotFound(path):
            return "Missing resource: \(path)"
        }
    }
}
