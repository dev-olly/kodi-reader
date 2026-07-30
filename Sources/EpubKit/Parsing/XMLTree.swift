import Foundation

/// Minimal XML tree built on Foundation's `XMLParser`.
///
/// `XMLDocument` would be more convenient but does not exist on iOS, and the
/// EPUB metadata formats are simple enough that a small tree plus a few
/// queries covers them. Namespace processing is left off so that qualified
/// names survive intact; lookups match on the local name so that documents
/// work whether or not they use prefixes.
public final class XMLElement {
    public let qualifiedName: String
    public let attributes: [String: String]
    public private(set) var children: [XMLElement] = []
    public private(set) var text: String = ""
    public weak var parent: XMLElement?

    /// Element name with any namespace prefix removed.
    public let name: String

    init(qualifiedName: String, attributes: [String: String]) {
        self.qualifiedName = qualifiedName
        self.attributes = attributes
        self.name = XMLElement.localName(of: qualifiedName)
    }

    static func localName(of qualifiedName: String) -> String {
        guard let colon = qualifiedName.lastIndex(of: ":") else { return qualifiedName }
        return String(qualifiedName[qualifiedName.index(after: colon)...])
    }

    fileprivate func append(_ child: XMLElement) {
        child.parent = self
        children.append(child)
    }

    fileprivate func appendText(_ string: String) {
        text += string
    }

    // MARK: - Queries

    /// Attribute lookup that ignores namespace prefixes, so `epub:type` and
    /// `type` both answer to `"type"`.
    public func attribute(_ name: String) -> String? {
        if let exact = attributes[name] { return exact }
        return attributes.first { XMLElement.localName(of: $0.key) == name }?.value
    }

    /// Direct children with the given local name.
    public func children(named name: String) -> [XMLElement] {
        children.filter { $0.name == name }
    }

    public func firstChild(named name: String) -> XMLElement? {
        children.first { $0.name == name }
    }

    /// Depth-first search across the whole subtree.
    public func firstDescendant(named name: String) -> XMLElement? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(named: name) { return found }
        }
        return nil
    }

    public func descendants(named name: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.descendants(named: name))
        }
        return result
    }

    /// Text of this element and everything beneath it, whitespace-collapsed.
    public var collectedText: String {
        var parts = [text]
        for child in children {
            parts.append(child.collectedText)
        }
        return parts
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum XMLTree {
    /// Parses a document and returns its root element.
    public static func parse(data: Data, path: String) throws -> XMLElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), let root = builder.root else {
            let reason = builder.failureReason
                ?? parser.parserError?.localizedDescription
                ?? "unknown parse failure"
            throw EPUBError.malformedXML(path: path, reason: reason)
        }
        return root
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLElement?
    var failureReason: String?
    private var stack: [XMLElement] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let element = XMLElement(
            qualifiedName: qName ?? elementName,
            attributes: attributeDict
        )
        if let current = stack.last {
            current.append(element)
        } else {
            root = element
        }
        stack.append(element)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            stack.last?.appendText(string)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failureReason = parseError.localizedDescription
    }
}
