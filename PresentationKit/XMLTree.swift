import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Tiny DOM built with XMLParser — enough for OpenLyrics, OpenSong, Zefania and OSIS.
final class XNode {
    let name: String            // local name, lower-cased, namespace prefix removed
    let attrs: [String: String] // keys lower-cased
    var children: [XNode] = []
    var text: String = ""       // text directly inside this node (for mixed content see `items`)
    var items: [Item] = []      // ordered children incl. text runs
    weak var parent: XNode?

    enum Item { case text(String), node(XNode) }

    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

    func child(_ n: String) -> XNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XNode] { children.filter { $0.name == n } }
    func descendants(_ n: String) -> [XNode] {
        var out: [XNode] = []
        for c in children { if c.name == n { out.append(c) }; out.append(contentsOf: c.descendants(n)) }
        return out
    }
    /// All text below this node, in document order.
    var deepText: String {
        items.map { item -> String in
            switch item { case .text(let t): return t; case .node(let n): return n.deepText }
        }.joined()
    }
    subscript(attr: String) -> String? { attrs[attr.lowercased()] }

    static func parse(_ data: Data) throws -> XNode {
        let b = Builder()
        let p = XMLParser(data: data)
        p.delegate = b
        p.shouldProcessNamespaces = false
        guard p.parse(), let root = b.root else {
            throw PresentationKitError.badFormat(p.parserError?.localizedDescription ?? "invalid XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            var a: [String: String] = [:]
            for (k, v) in attributeDict { a[(k.split(separator: ":").last.map(String.init) ?? k).lowercased()] = v }
            let n = XNode(name: local.lowercased(), attrs: a)
            if let top = stack.last { n.parent = top; top.children.append(n); top.items.append(.node(n)) } else { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let top = stack.last else { return }
            top.text += string
            if case .text(let t)? = top.items.last { top.items[top.items.count - 1] = .text(t + string) }
            else { top.items.append(.text(string)) }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let s = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: s) }
        }
    }
}
