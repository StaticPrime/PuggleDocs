import Foundation

/// A minimal element tree. Element and attribute names are stored without namespace prefixes,
/// which is sufficient for WordprocessingML where local names are unambiguous in context.
final class XNode {
    let name: String
    var attributes: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XNode? { children.first { $0.name == name } }
    func children(_ name: String) -> [XNode] { children.filter { $0.name == name } }
    func attr(_ name: String) -> String? { attributes[name] }

    /// Depth-first search for the first descendant with `name`.
    func firstDescendant(_ name: String) -> XNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    /// Value of a WordprocessingML on/off property (`<w:b/>`, `<w:b w:val="0"/>`).
    var isOn: Bool {
        guard let value = attributes["val"]?.lowercased() else { return true }
        return !(value == "0" || value == "false" || value == "off" || value == "none")
    }
}

enum XMLTree {
    /// Elements whose character data matters; everything else ignores text to save memory.
    static let textElements: Set<String> = ["t", "instrText", "delText", "latin", "Target"]
    /// Real parts nest a few dozen levels. Deeper ones are refused: a tree tens of thousands of levels deep
    /// overflows the stack when it's freed.
    static let maximumDepth = 256

    static func parse(_ data: Data) throws -> XNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.isTooDeep, let root = delegate.root else {
            throw DocumentIOError.unreadable(delegate.isTooDeep ? "Part of the document is nested too deeply to read."
                                                                : "Part of the document is not valid XML.")
        }
        return root
    }

    static func localName(_ qualified: String) -> String {
        guard let colon = qualified.lastIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: colon)...])
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []
        var isTooDeep = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard stack.count < XMLTree.maximumDepth else {
                isTooDeep = true
                parser.abortParsing()
                return
            }
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                let local = XMLTree.localName(key)
                // Keep the first value when two prefixes share a local name, except that a
                // relationship id ("r:id") wins over anything else called "id".
                if attributes[local] == nil || key.hasPrefix("r:") { attributes[local] = value }
            }
            let element = XNode(name: XMLTree.localName(elementName), attributes: attributes)
            if let parent = stack.last { parent.children.append(element) } else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let current = stack.last, XMLTree.textElements.contains(current.name) else { return }
            current.text += string
        }
    }
}
