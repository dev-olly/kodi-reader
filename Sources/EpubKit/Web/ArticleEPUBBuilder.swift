import CryptoKit
import Foundation
import ZIPFoundation

/// Packages a reader-mode article as a single-chapter EPUB 3.
///
/// Images are downloaded and inlined so the snapshot is offline and so the
/// reader's `epubreader://` scheme (which refuses remote loads) can serve them.
public enum ArticleEPUBBuilder {
    public static let maxImageCount = 40
    public static let maxImageBytes = 8 * 1024 * 1024

    /// Writes a valid EPUB to `destination`. Existing files are replaced.
    @discardableResult
    public static func build(
        _ article: ArticleContent,
        to destination: URL,
        urlSession: URLSession = .shared
    ) async throws -> URL {
        let prepared = try await prepare(article, session: urlSession)
        try writeArchive(prepared, to: destination)
        return destination
    }

    public static func identifier(for sourceURL: URL) -> String {
        WebPageURL.identifier(for: sourceURL)
    }

    // MARK: - Prepare

    private struct Prepared {
        var identifier: String
        var title: String
        var author: String
        var language: String
        var sourceURL: URL
        var chapterXHTML: String
        var images: [InlinedImage]
        var modified: String
    }

    private struct InlinedImage {
        var href: String
        var mediaType: String
        var data: Data
        var itemID: String
    }

    private static func prepare(
        _ article: ArticleContent,
        session: URLSession
    ) async throws -> Prepared {
        let title = article.resolvedTitle
        guard !article.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArticleError.emptyArticle
        }

        let language = normalizedLanguage(article.language)
        let (body, images) = try await inlineImages(
            in: HTMLSanitizer.stripUnsafe(article.contentHTML),
            sourceURL: article.sourceURL,
            session: session
        )
        let xhtmlBody = HTMLSanitizer.toXHTMLFragment(body)
        let chapter = chapterDocument(
            title: title,
            author: article.resolvedAuthor,
            language: language,
            sourceURL: article.sourceURL,
            body: xhtmlBody
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
        // EPUB requires no fractional seconds.
        let modified = stamp.replacingOccurrences(
            of: #"\.\d+Z$"#,
            with: "Z",
            options: .regularExpression
        )

        return Prepared(
            identifier: identifier(for: article.sourceURL),
            title: title,
            author: article.resolvedAuthor,
            language: language,
            sourceURL: article.sourceURL,
            chapterXHTML: chapter,
            images: images,
            modified: modified
        )
    }

    private static func normalizedLanguage(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "en" }
        return String(trimmed.prefix(16))
    }

    // MARK: - Images

    private static func inlineImages(
        in html: String,
        sourceURL: URL,
        session: URLSession
    ) async throws -> (String, [InlinedImage]) {
        let matches = HTMLSanitizer.imageSources(in: html)
        guard !matches.isEmpty else { return (html, []) }

        var uniqueSources: [String] = []
        var seen = Set<String>()
        for source in matches {
            if seen.insert(source).inserted {
                uniqueSources.append(source)
            }
        }

        let limited = Array(uniqueSources.prefix(maxImageCount))
        var rewritten = html
        var images: [InlinedImage] = []
        var hrefBySource: [String: String] = [:]

        await withTaskGroup(of: (String, InlinedImage?).self) { group in
            for source in limited {
                group.addTask {
                    let image = await downloadImage(
                        source: source,
                        sourceURL: sourceURL,
                        session: session
                    )
                    return (source, image)
                }
            }
            for await (source, image) in group {
                if let image {
                    hrefBySource[source] = image.href
                    images.append(image)
                }
            }
        }

        images.sort { $0.itemID < $1.itemID }

        for source in uniqueSources {
            if let href = hrefBySource[source] {
                rewritten = HTMLSanitizer.replaceImageSource(source, with: href, in: rewritten)
            } else {
                rewritten = HTMLSanitizer.removeImages(withSource: source, from: rewritten)
            }
        }

        rewritten = HTMLSanitizer.stripAttribute("srcset", from: rewritten)
        rewritten = HTMLSanitizer.stripAttribute("sizes", from: rewritten)
        return (rewritten, images)
    }

    private static func downloadImage(
        source: String,
        sourceURL: URL,
        session: URLSession
    ) async -> InlinedImage? {
        if source.lowercased().hasPrefix("data:") {
            return inlinedDataURL(source)
        }

        let resolved = resolveURL(source, relativeTo: sourceURL)
        guard let resolved, WebPageURL.isAllowed(resolved) else { return nil }

        do {
            let (data, response) = try await session.data(from: resolved)
            guard data.count > 16, data.count <= maxImageBytes else { return nil }
            let mime = (response as? HTTPURLResponse)
                .flatMap { $0.value(forHTTPHeaderField: "Content-Type") }?
                .split(separator: ";").first
                .map(String.init)
                ?? EPUBPath.mimeType(forPath: resolved.path)
            guard mime.hasPrefix("image/") else { return nil }
            return makeInlinedImage(data: data, mimeType: mime)
        } catch {
            return nil
        }
    }

    private static func resolveURL(_ source: String, relativeTo base: URL) -> URL? {
        if source.hasPrefix("//"), let scheme = base.scheme {
            return URL(string: "\(scheme):\(source)")
        }
        return URL(string: source, relativeTo: base)?.absoluteURL
    }

    private static func inlinedDataURL(_ source: String) -> InlinedImage? {
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let header = String(source[source.startIndex..<comma])
        let payload = String(source[source.index(after: comma)...])
        let mime = header
            .dropFirst("data:".count)
            .split(separator: ";")
            .first
            .map(String.init)
            ?? "image/png"
        guard mime.hasPrefix("image/") else { return nil }

        let data: Data?
        if header.lowercased().contains(";base64") {
            data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
        } else {
            data = payload.removingPercentEncoding.flatMap { Data($0.utf8) }
        }
        guard let data, data.count > 16, data.count <= maxImageBytes else { return nil }
        return makeInlinedImage(data: data, mimeType: mime)
    }

    private static func makeInlinedImage(data: Data, mimeType: String) -> InlinedImage {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let name = String(hex.prefix(16))
        let ext = extensionForMIME(mimeType)
        let href = "images/\(name).\(ext)"
        return InlinedImage(
            href: href,
            mediaType: mimeType,
            data: data,
            itemID: "img-\(name)"
        )
    }

    private static func extensionForMIME(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "image/avif": return "avif"
        default: return "img"
        }
    }

    // MARK: - Archive

    private static func writeArchive(_ prepared: Prepared, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let archive: Archive
        do {
            archive = try Archive(url: destination, accessMode: .create)
        } catch {
            throw ArticleError.writeFailed(error.localizedDescription)
        }

        do {
            try addEntry(
                to: archive,
                path: "mimetype",
                data: Data("application/epub+zip".utf8),
                stored: true
            )
            try addEntry(to: archive, path: "META-INF/container.xml", data: Data(containerXML.utf8))
            try addEntry(to: archive, path: "OEBPS/content.opf", data: Data(packageDocument(prepared).utf8))
            try addEntry(to: archive, path: "OEBPS/nav.xhtml", data: Data(navDocument(prepared).utf8))
            try addEntry(to: archive, path: "OEBPS/chapter.xhtml", data: Data(prepared.chapterXHTML.utf8))
            for image in prepared.images {
                try addEntry(to: archive, path: "OEBPS/\(image.href)", data: image.data)
            }
        } catch let error as ArticleError {
            throw error
        } catch {
            throw ArticleError.writeFailed(error.localizedDescription)
        }
    }

    private static func addEntry(
        to archive: Archive,
        path: String,
        data: Data,
        stored: Bool = false
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: stored ? .none : .deflate,
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        )
    }

    // MARK: - Documents

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static func packageDocument(_ prepared: Prepared) -> String {
        var manifest = """
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        """
        for image in prepared.images {
            manifest += """

            <item id="\(xmlEscape(image.itemID))" href="\(xmlEscape(image.href))" media-type="\(xmlEscape(image.mediaType))"/>
        """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">\(xmlEscape(prepared.identifier))</dc:identifier>
            <dc:title>\(xmlEscape(prepared.title))</dc:title>
            <dc:creator>\(xmlEscape(prepared.author))</dc:creator>
            <dc:language>\(xmlEscape(prepared.language))</dc:language>
            <dc:source>\(xmlEscape(prepared.sourceURL.absoluteString))</dc:source>
            <meta property="dcterms:modified">\(prepared.modified)</meta>
          </metadata>
          <manifest>
        \(manifest)
          </manifest>
          <spine>
            <itemref idref="chapter"/>
          </spine>
        </package>
        """
    }

    private static func navDocument(_ prepared: Prepared) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(xmlEscape(prepared.language))" xml:lang="\(xmlEscape(prepared.language))">
        <head><title>\(xmlEscape(prepared.title))</title></head>
        <body>
          <nav epub:type="toc">
            <ol>
              <li><a href="chapter.xhtml">\(xmlEscape(prepared.title))</a></li>
            </ol>
          </nav>
        </body>
        </html>
        """
    }

    private static func chapterDocument(
        title: String,
        author: String,
        language: String,
        sourceURL: URL,
        body: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(xmlEscape(language))" xml:lang="\(xmlEscape(language))">
        <head>
          <title>\(xmlEscape(title))</title>
        </head>
        <body>
          <h1>\(xmlEscape(title))</h1>
          <p>\(xmlEscape(author)) · <a href="\(xmlEscape(sourceURL.absoluteString))">\(xmlEscape(sourceURL.host ?? sourceURL.absoluteString))</a></p>
          \(body)
        </body>
        </html>
        """
    }

    static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - HTML helpers

enum HTMLSanitizer {
    private static let removedBlocks = ["script", "style", "iframe", "object", "embed", "form", "noscript"]
    private static let voidTags = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]

    static func stripUnsafe(_ html: String) -> String {
        var result = html
        for name in removedBlocks {
            result = replace(
                pattern: "<\(name)\\b[^>]*>[\\s\\S]*?</\(name)\\s*>",
                in: result,
                with: ""
            )
            result = replace(pattern: "<\(name)\\b[^>]*/?>", in: result, with: "")
        }
        result = replace(pattern: #"\son[a-zA-Z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, in: result, with: "")
        return result
    }

    static func toXHTMLFragment(_ html: String) -> String {
        var result = escapeBareAmpersands(html)
        for tag in voidTags {
            result = selfClose(tag, in: result)
        }
        return result
    }

    static func imageSources(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                if range.location != NSNotFound, range.length > 0 {
                    return ns.substring(with: range)
                }
            }
            return nil
        }
    }

    static func replaceImageSource(_ source: String, with href: String, in html: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: source)
        return replace(
            pattern: #"(<img\b[^>]*?\bsrc\s*=\s*)(?:"\#(escaped)"|'\#(escaped)'|\#(escaped))"#,
            in: html,
            with: "$1\"\(href)\""
        )
    }

    static func removeImages(withSource source: String, from html: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: source)
        return replace(
            pattern: #"<img\b[^>]*?\bsrc\s*=\s*(?:"\#(escaped)"|'\#(escaped)'|\#(escaped))[^>]*/?>"#,
            in: html,
            with: ""
        )
    }

    static func stripAttribute(_ name: String, from html: String) -> String {
        replace(
            pattern: #"\s\#(name)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            in: html,
            with: ""
        )
    }

    private static func selfClose(_ tag: String, in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)\\b([^>]*)>",
            options: [.caseInsensitive]
        ) else { return html }
        let ns = html as NSString
        var result = html
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches {
            let full = ns.substring(with: match.range)
            if full.hasSuffix("/>") { continue }
            let attrs: String
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                attrs = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            } else {
                attrs = ""
            }
            let trimmed = attrs.hasSuffix("/") ? String(attrs.dropLast()).trimmingCharacters(in: .whitespaces) : attrs
            let replacement = trimmed.isEmpty ? "<\(tag)/>" : "<\(tag) \(trimmed)/>"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func escapeBareAmpersands(_ html: String) -> String {
        replace(
            pattern: #"&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);)"#,
            in: html,
            with: "&amp;"
        )
    }

    private static func replace(pattern: String, in string: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return string
        }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }
}
