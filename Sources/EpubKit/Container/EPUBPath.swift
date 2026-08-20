import Foundation

/// Path arithmetic for locations inside an EPUB archive.
///
/// EPUB hrefs are relative URL references resolved against the document that
/// contains them, so they may be percent-encoded and may walk upwards with
/// `..`. Archive entry names are plain, unencoded, slash-separated strings.
public enum EPUBPath {
    /// Directory portion of an archive path, without a trailing slash.
    public static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// Resolves `href` against the directory of `base`, collapsing `.` and `..`.
    ///
    /// The fragment is stripped; use `splitFragment` first when it matters.
    public static func resolve(href: String, relativeTo base: String) -> String {
        let href = splitFragment(href).path
        let decoded = href.removingPercentEncoding ?? href

        // An absolute-looking href is relative to the archive root in practice.
        if decoded.hasPrefix("/") {
            return normalize(String(decoded.dropFirst()))
        }

        let baseDirectory = directory(of: base)
        let combined = baseDirectory.isEmpty ? decoded : baseDirectory + "/" + decoded
        return normalize(combined)
    }

    /// Collapses `.` and `..` segments and removes empty ones.
    public static func normalize(_ path: String) -> String {
        var stack: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(segment))
            }
        }
        return stack.joined(separator: "/")
    }

    /// Splits `chapter.xhtml#section-2` into its path and fragment.
    public static func splitFragment(_ href: String) -> (path: String, fragment: String?) {
        guard let hash = href.firstIndex(of: "#") else { return (href, nil) }
        let path = String(href[href.startIndex..<hash])
        let fragment = String(href[href.index(after: hash)...])
        return (path, fragment.isEmpty ? nil : fragment)
    }

    /// Best-effort MIME type for an archive entry, used when serving resources.
    public static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "xhtml", "xht": return "application/xhtml+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "map": return "application/json"
        case "wasm": return "application/wasm"
        case "xml", "opf", "ncx": return "application/xml"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "video/mp4"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }

    /// True when the resource should have the reader stylesheet and script injected.
    public static func isHTMLDocument(mimeType: String) -> Bool {
        mimeType == "application/xhtml+xml" || mimeType == "text/html"
    }
}
