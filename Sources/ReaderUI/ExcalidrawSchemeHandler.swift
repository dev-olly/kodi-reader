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

