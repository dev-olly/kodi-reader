import EpubKit
import Foundation
import WebKit

/// Serves the bundled Excalidraw host over a private URL scheme.
///
/// Same-origin `excalidraw://host/…` is required for the editor’s fonts and
/// workers; `loadFileURL` would put assets on a `file://` origin and break them.
public final class ExcalidrawSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "excalidraw"
    public static let host = "host"

    public static var indexURL: URL {
        url(forPath: "index.html")
    }

    public static func url(forPath path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + path
        return components.url ?? URL(string: "\(scheme)://\(host)/index.html")!
    }

    private var cancelledTasks = Set<ObjectIdentifier>()
    private let cancelledLock = NSLock()
    private let queue = DispatchQueue(label: "excalidraw-scheme-handler", qos: .userInitiated)

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

