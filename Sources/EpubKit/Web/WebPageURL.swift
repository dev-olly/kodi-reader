import Foundation

/// Normalization and identity for pages saved from the live browser.
public enum WebPageURL {
    /// Turns a typed address into an `http`/`https` URL, adding `https://` when needed.
    public static func normalized(from input: String) -> URL? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed) else { return nil }
        return isAllowed(url) ? url : nil
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        return url.host != nil && !(url.host ?? "").isEmpty
    }

    /// Stable EPUB identifier (and therefore `bookID`) for a source URL.
    ///
    /// Re-saving the same page replaces the imported file in place instead of
    /// creating a second library entry, so existing notes stay attached.
    public static func identifier(for url: URL) -> String {
        "web:" + canonicalString(for: url)
    }

    public static func canonicalString(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        var path = components.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
            components.path = path
        }
        return components.string ?? url.absoluteString
    }
}
