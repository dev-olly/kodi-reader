import Foundation

/// Builds the table of contents from either an EPUB 3 navigation document or
/// an EPUB 2 NCX. Both formats appear in the wild, and plenty of EPUB 3 files
/// still ship an NCX for backwards compatibility, so the nav document wins
/// when both are present.
enum NavigationParser {
    static func parseTOC(
        package: PackageParser.Package,
        packagePath: String,
        container: EPUBContainer
    ) -> [TOCEntry] {
        if let navItem = package.manifest.values.first(where: \.isNavigationDocument),
           let entries = try? parseNavigationDocument(at: navItem.path, container: container),
           !entries.isEmpty {
            return entries
        }

        if let ncxPath = ncxPath(package: package),
           let entries = try? parseNCX(at: ncxPath, container: container),
           !entries.isEmpty {
            return entries
        }

        return []
    }

    private static func ncxPath(package: PackageParser.Package) -> String? {
        if let id = package.ncxItemID, let item = package.manifest[id] {
            return item.path
        }
        return package.manifest.values
            .first { $0.mediaType == "application/x-dtbncx+xml" }?
            .path
    }

    // MARK: - EPUB 3 navigation document

    static func parseNavigationDocument(
        at path: String,
        container: EPUBContainer
    ) throws -> [TOCEntry] {
        let root = try XMLTree.parse(data: container.data(at: path), path: path)

        // Prefer the nav flagged as the table of contents; fall back to the
        // first nav that has a list, since the epub:type is sometimes absent.
        let navs = root.descendants(named: "nav")
        let toc = navs.first { $0.attribute("type") == "toc" }
            ?? navs.first { $0.firstChild(named: "ol") != nil }

        guard let list = toc?.firstChild(named: "ol") else { return [] }
        return parseOrderedList(list, documentPath: path)
    }

    private static func parseOrderedList(
        _ list: XMLElement,
        documentPath: String
    ) -> [TOCEntry] {
        list.children(named: "li").compactMap { item in
            let anchor = item.firstChild(named: "a") ?? item.firstChild(named: "span")
            let nested = item.firstChild(named: "ol")

            let title = anchor?.collectedText ?? ""
            let children = nested.map { parseOrderedList($0, documentPath: documentPath) } ?? []

            // A span without an href is a grouping heading; keep it only when
            // it actually groups something.
            guard let href = anchor?.attribute("href") else {
                guard !children.isEmpty, !title.isEmpty else { return nil }
                return TOCEntry(title: title, path: "", children: children)
            }

            let (rawPath, fragment) = EPUBPath.splitFragment(href)
            return TOCEntry(
                title: title.isEmpty ? "Untitled Section" : title,
                path: EPUBPath.resolve(href: rawPath, relativeTo: documentPath),
                fragment: fragment,
                children: children
            )
        }
    }

    // MARK: - EPUB 2 NCX

    static func parseNCX(at path: String, container: EPUBContainer) throws -> [TOCEntry] {
        let root = try XMLTree.parse(data: container.data(at: path), path: path)
        guard let navMap = root.firstDescendant(named: "navMap") else { return [] }
        return parseNavPoints(in: navMap, documentPath: path)
    }

    private static func parseNavPoints(
        in parent: XMLElement,
        documentPath: String
    ) -> [TOCEntry] {
        let points = parent.children(named: "navPoint")

        // NCX declares an explicit ordering that need not match document order.
        let ordered = points.sorted { lhs, rhs in
            let l = Int(lhs.attribute("playOrder") ?? "") ?? Int.max
            let r = Int(rhs.attribute("playOrder") ?? "") ?? Int.max
            return l < r
        }

        return ordered.compactMap { point in
            guard let src = point.firstChild(named: "content")?.attribute("src") else {
                return nil
            }
            let title = point.firstChild(named: "navLabel")?
                .firstChild(named: "text")?
                .collectedText ?? ""

            let (rawPath, fragment) = EPUBPath.splitFragment(src)
            return TOCEntry(
                title: title.isEmpty ? "Untitled Section" : title,
                path: EPUBPath.resolve(href: rawPath, relativeTo: documentPath),
                fragment: fragment,
                children: parseNavPoints(in: point, documentPath: documentPath)
            )
        }
    }
}
