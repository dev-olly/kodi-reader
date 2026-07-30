import EpubKit
import Foundation
import WebKit

/// Serves book resources to the web view over a private URL scheme.
///
/// Using a scheme handler rather than a local HTTP server means nothing is
/// listening on a port, resources never touch disk, and the whole book stays
/// inside one origin so relative links between chapters resolve naturally.
///
/// URLs take the form `epubreader://book/<path within the archive>`, plus
/// `epubreader://reader/<asset>` for the injected stylesheet and script.
public final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "epubreader"
    private static let bookHost = "book"
    private static let readerHost = "reader"

    private let book: EPUBBook
    private let queue = DispatchQueue(label: "epub-scheme-handler", qos: .userInitiated)
    /// Tasks WebKit has stopped; replying to one of these raises an exception.
    private var cancelledTasks = Set<ObjectIdentifier>()
    private let cancelledLock = NSLock()

    public init(book: EPUBBook) {
        self.book = book
    }

    /// URL for a resource path inside the archive.
    public static func url(forArchivePath path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = bookHost
        components.path = "/" + path
        return components.url ?? URL(string: "\(scheme)://\(bookHost)/")!
    }

    /// Archive path for a URL previously produced by `url(forArchivePath:)`.
    public static func archivePath(for url: URL) -> String? {
        guard url.scheme == scheme, url.host == bookHost else { return nil }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        return path.removingPercentEncoding ?? path
    }

    // MARK: - WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            finish(task, with: .failure(URLError(.badURL)))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let result = self.load(url: url)
            DispatchQueue.main.async {
                self.finish(task, with: result)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        cancelledLock.lock()
        cancelledTasks.insert(ObjectIdentifier(task))
        cancelledLock.unlock()
    }

    // MARK: - Loading

    private struct Response {
        let data: Data
        let mimeType: String
    }

    private func load(url: URL) -> Result<Response, Error> {
        let rawPath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let path = rawPath.removingPercentEncoding ?? rawPath

        switch url.host {
        case Self.readerHost:
            return loadReaderAsset(named: path)
        case Self.bookHost:
            return loadBookResource(at: path)
        default:
            return .failure(URLError(.unsupportedURL))
        }
    }

    private func loadReaderAsset(named name: String) -> Result<Response, Error> {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"),
            let data = try? Data(contentsOf: url)
        else {
            return .failure(URLError(.fileDoesNotExist))
        }
        return .success(Response(data: data, mimeType: EPUBPath.mimeType(forPath: name)))
    }

    private func loadBookResource(at path: String) -> Result<Response, Error> {
        do {
            let data = try book.data(at: path)
            let mimeType = EPUBPath.mimeType(forPath: path)

            guard EPUBPath.isHTMLDocument(mimeType: mimeType) else {
                return .success(Response(data: data, mimeType: mimeType))
            }
            let injected = ReaderAssetInjector.inject(into: data)
            return .success(Response(data: injected, mimeType: mimeType))
        } catch {
            return .failure(error)
        }
    }

    private func finish(_ task: WKURLSchemeTask, with result: Result<Response, Error>) {
        cancelledLock.lock()
        let wasCancelled = cancelledTasks.remove(ObjectIdentifier(task)) != nil
        cancelledLock.unlock()
        guard !wasCancelled else { return }

        switch result {
        case let .success(response):
            guard let url = task.request.url else { return }
            let urlResponse = URLResponse(
                url: url,
                mimeType: response.mimeType,
                expectedContentLength: response.data.count,
                textEncodingName: "utf-8"
            )
            task.didReceive(urlResponse)
            task.didReceive(response.data)
            task.didFinish()
        case let .failure(error):
            task.didFailWithError(error)
        }
    }
}

/// Rewrites spine documents so they pull in the reader stylesheet and runtime.
enum ReaderAssetInjector {
    private static let tags = """
    <link rel="stylesheet" type="text/css" href="\(EPUBSchemeHandler.scheme)://reader/reader.css"/>
    <script src="\(EPUBSchemeHandler.scheme)://reader/reader.js"></script>
    """

    static func inject(into data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) else { return data }

        // XHTML is parsed strictly, so the tags must be self-closed or paired,
        // and they belong in <head> so the stylesheet applies before first paint.
        if let range = html.range(of: "</head>", options: [.caseInsensitive]) {
            html.replaceSubrange(range, with: tags + "\n</head>")
        } else if let range = html.range(of: "<body", options: [.caseInsensitive]) {
            html.replaceSubrange(
                range,
                with: "<head>\(tags)</head>\n<body"
            )
        } else {
            html = tags + html
        }

        return Data(html.utf8)
    }
}
