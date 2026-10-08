import Foundation

public enum HTMLTextExtractor {
    /// Parse locally, without loading images, executing scripts, or resolving external entities.
    public static func extract(_ data: Data) throws -> String {
        // The data initializer's HTML tidy path can discard non-ASCII characters.
        // Decode first so Chinese text reaches the parser as Unicode.
        let source = try TextDecoder.decode(data)
        let document = try XMLDocument(xmlString: source, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        let skipped: Set<String> = ["head", "script", "style", "noscript", "iframe", "object", "svg"]
        let blocks: Set<String> = ["p", "div", "section", "article", "header", "footer", "main", "aside",
                                   "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "tr", "blockquote", "pre"]
        var result = ""
        func visit(_ node: XMLNode) {
            if node.kind == .text { result += node.stringValue ?? ""; return }
            let name = (node.name ?? "").lowercased()
            if skipped.contains(name) { return }
            if name == "br" || name == "hr" { result += "\n"; return }
            if blocks.contains(name), !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
            for child in node.children ?? [] { visit(child) }
            if blocks.contains(name), !result.hasSuffix("\n") { result += "\n" }
            if name == "td" || name == "th" { result += "\t" }
        }
        if let root = document.rootElement() { visit(root) }
        return try TextDecoder.cleaned(result)
    }
}
