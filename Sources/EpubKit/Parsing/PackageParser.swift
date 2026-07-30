import Foundation

/// Parses `META-INF/container.xml` and the OPF package document.
enum PackageParser {
    /// Reads the package document path out of the container descriptor.
    static func packagePath(in container: EPUBContainer) throws -> String {
        let path = "META-INF/container.xml"
        guard container.contains(path) else {
            throw EPUBError.missingContainerXML
        }

        let root = try XMLTree.parse(data: container.data(at: path), path: path)
        let rootFiles = root.descendants(named: "rootfile")

        // Prefer the OEBPS package document; some archives list several rootfiles.
        let preferred = rootFiles.first {
            $0.attribute("media-type") == "application/oebps-package+xml"
        } ?? rootFiles.first

        guard let fullPath = preferred?.attribute("full-path"), !fullPath.isEmpty else {
            throw EPUBError.missingRootFile
        }
        return EPUBPath.normalize(fullPath)
    }

    struct Package {
        var metadata: Metadata
        var manifest: [String: ManifestItem]
        var spine: [SpineItem]
        var pageProgression: PageProgressionDirection
        /// Manifest id referenced by `<spine toc="...">`, for EPUB 2 books.
        var ncxItemID: String?
    }

    static func parsePackage(at packagePath: String, in container: EPUBContainer) throws -> Package {
        guard container.contains(packagePath) else {
            throw EPUBError.missingOPF(packagePath)
        }
        let root = try XMLTree.parse(data: container.data(at: packagePath), path: packagePath)

        let manifest = parseManifest(root: root, packagePath: packagePath)
        let metadata = parseMetadata(root: root, manifest: manifest)
        let (spine, progression, ncxID) = parseSpine(root: root, manifest: manifest)

        guard !spine.isEmpty else { throw EPUBError.emptySpine }

        return Package(
            metadata: metadata,
            manifest: manifest,
            spine: spine,
            pageProgression: progression,
            ncxItemID: ncxID
        )
    }

    // MARK: - Sections

    private static func parseManifest(
        root: XMLElement,
        packagePath: String
    ) -> [String: ManifestItem] {
        guard let manifestElement = root.firstDescendant(named: "manifest") else { return [:] }

        var items: [String: ManifestItem] = [:]
        for element in manifestElement.children(named: "item") {
            guard
                let id = element.attribute("id"),
                let href = element.attribute("href")
            else { continue }

            let properties = (element.attribute("properties") ?? "")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            items[id] = ManifestItem(
                id: id,
                path: EPUBPath.resolve(href: href, relativeTo: packagePath),
                mediaType: element.attribute("media-type") ?? "application/octet-stream",
                properties: Set(properties)
            )
        }
        return items
    }

    private static func parseMetadata(
        root: XMLElement,
        manifest: [String: ManifestItem]
    ) -> Metadata {
        let element = root.firstDescendant(named: "metadata")

        func value(_ name: String) -> String? {
            let text = element?.firstChild(named: name)?.trimmedText
            return (text?.isEmpty ?? true) ? nil : text
        }

        let creators = element?.children(named: "creator")
            .map(\.trimmedText)
            .filter { !$0.isEmpty } ?? []

        // EPUB 2 points at the cover through a meta hint; EPUB 3 uses a
        // manifest property, which `Publication.coverPath` falls back to.
        let coverID = element?.children(named: "meta")
            .first { $0.attribute("name") == "cover" }?
            .attribute("content")

        return Metadata(
            title: value("title") ?? "Untitled",
            creators: creators,
            language: value("language"),
            identifier: value("identifier"),
            publisher: value("publisher"),
            bookDescription: value("description"),
            coverItemID: coverID.flatMap { manifest[$0] != nil ? $0 : nil }
        )
    }

    private static func parseSpine(
        root: XMLElement,
        manifest: [String: ManifestItem]
    ) -> ([SpineItem], PageProgressionDirection, String?) {
        guard let spineElement = root.firstDescendant(named: "spine") else {
            return ([], .ltr, nil)
        }

        let progression = spineElement.attribute("page-progression-direction")
            .flatMap(PageProgressionDirection.init(rawValue:)) ?? .ltr

        let items: [SpineItem] = spineElement.children(named: "itemref").compactMap { element in
            guard
                let idref = element.attribute("idref"),
                let manifestItem = manifest[idref]
            else { return nil }

            return SpineItem(
                idref: idref,
                path: manifestItem.path,
                mediaType: manifestItem.mediaType,
                isLinear: element.attribute("linear") != "no"
            )
        }

        return (items, progression, spineElement.attribute("toc"))
    }
}
