import Foundation

/// A small XML tree. The flat reader used elsewhere is fine for a command that
/// returns a handful of values, but a file list is a repeated structure and
/// flattening it loses which value belongs to which file.
public final class XMLNode: @unchecked Sendable {
    public let name: String
    public internal(set) var text: String = ""
    public internal(set) var children: [XMLNode] = []

    init(name: String) {
        self.name = name
    }

    /// First child with this name, case-insensitively.
    public func child(_ name: String) -> XMLNode? {
        let wanted = name.lowercased()
        return children.first { $0.name == wanted }
    }

    /// Text of the first child matching any of these names.
    public func value(_ names: String...) -> String? {
        for name in names {
            if let node = child(name), !node.text.isEmpty {
                return node.text
            }
        }
        return nil
    }

    /// Every descendant with this name, at any depth.
    public func descendants(named name: String) -> [XMLNode] {
        let wanted = name.lowercased()
        var found: [XMLNode] = []
        if self.name == wanted { found.append(self) }
        for child in children {
            found.append(contentsOf: child.descendants(named: wanted))
        }
        return found
    }

    /// Groups of sibling elements that repeat. Used to find the file records
    /// when the element name is not one we expected.
    public func repeatedGroups() -> [[XMLNode]] {
        var groups: [[XMLNode]] = []
        var byName: [String: [XMLNode]] = [:]
        for child in children where !child.children.isEmpty {
            byName[child.name, default: []].append(child)
        }
        for (_, nodes) in byName where nodes.count > 1 {
            groups.append(nodes)
        }
        for child in children {
            groups.append(contentsOf: child.repeatedGroups())
        }
        return groups
    }
}

public enum XMLTreeParser {
    public static func parse(_ data: Data) -> XMLNode? {
        let delegate = TreeDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return delegate.root }
        return delegate.root
    }
}

private final class TreeDelegate: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let node = XMLNode(name: elementName.lowercased())
        // Attributes are exposed as children so callers need not care whether
        // the firmware used an attribute or an element.
        for (key, value) in attributeDict {
            let attribute = XMLNode(name: key.lowercased())
            attribute.text = value
            node.children.append(attribute)
        }
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current = stack.last else { return }
        current.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if let current = stack.last {
            current.text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !stack.isEmpty { stack.removeLast() }
    }
}
