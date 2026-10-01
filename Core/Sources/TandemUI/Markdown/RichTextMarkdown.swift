import AppKit
import Foundation

/// Turns formatted text from the pasteboard (Notion, Google Docs, web pages, Word, Pages, Notes)
/// into Markdown that keeps its headings, lists and to-dos, emphasis, links, code, quotes,
/// dividers and tables, so pasting a document doesn't flatten it to plain text.
public enum RichTextMarkdown {
    /// The pasteboard's contents as Markdown: its HTML or RTF when it has some, else plain text.
    public static func markdown(from pasteboard: NSPasteboard) -> String? {
        let plain = pasteboard.string(forType: .string)
        if let html = pasteboard.string(forType: .html), let markdown = markdown(html: html, plainText: plain) {
            return markdown
        }
        for type in [NSPasteboard.PasteboardType.rtf, .rtfd] {
            guard let data = pasteboard.data(forType: type) else { continue }
            let attributed = type == .rtf
                ? NSAttributedString(rtf: data, documentAttributes: nil)
                : NSAttributedString(rtfd: data, documentAttributes: nil)
            if let attributed {
                let converted = markdown(attributed: attributed)
                if !converted.isEmpty { return converted }
            }
        }
        return plain
    }

    // MARK: HTML

    /// Markdown for an HTML fragment, or nil when it has nothing worth keeping over `plainText`.
    public static func markdown(html: String, plainText: String? = nil) -> String? {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]),
              let root = document.rootElement() else { return nil }
        let body = root.elements(forName: "body").first ?? root
        // Code editors (Xcode, VS Code) copy colored, preformatted HTML: it's code.
        if HTMLWriter.isPreformattedCode(body) {
            let code = plainText ?? body.stringValue ?? ""
            return code.isEmpty ? nil : HTMLWriter.fence(code, language: nil)
        }
        let markdown = HTMLWriter.document(body)
        return markdown.isEmpty ? nil : markdown
    }

    // MARK: Attributed text (RTF)

    /// Markdown for attributed text, such as RTF from Word, Pages or Notes.
    public static func markdown(attributed: NSAttributedString) -> String {
        AttributedWriter(attributed).markdown()
    }
}

// MARK: - HTML to Markdown

private enum HTMLWriter {
    private static let skipped: Set<String> = ["head", "title", "meta", "style", "script", "noscript", "template", "link"]
    private static let blockTags: Set<String> = [
        "html", "body", "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre",
        "table", "thead", "tbody", "tfoot", "tr", "hr", "section", "article", "header", "footer", "main", "aside",
        "nav", "details", "summary", "figure", "figcaption", "dl", "dt", "dd", "address", "center"
    ]

    struct Style {
        var bold = false
        var italic = false
        var strike = false
        var code = false
    }

    static func document(_ body: XMLElement) -> String {
        let text = blocks(in: body).joined(separator: "\n\n")
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Blocks

    /// The Markdown blocks inside a container: runs of inline content become paragraphs.
    static func blocks(in element: XMLElement) -> [String] {
        var result: [String] = []
        var run: [XMLNode] = []
        func flush() {
            let paragraph = inline(run, style: Style())
            run.removeAll()
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(escapeBlockStart(trimmed)) }
        }
        for child in element.children ?? [] {
            if let child = child as? XMLElement, let name = child.name?.lowercased() {
                if skipped.contains(name) { continue }
                if blockTags.contains(name) {
                    flush()
                    result.append(contentsOf: block(child, name: name))
                    continue
                }
            }
            run.append(child)
        }
        flush()
        return result
    }

    static func block(_ element: XMLElement, name: String) -> [String] {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            let text = oneLine(inline(element.children ?? [], style: Style(bold: true)))
            return text.isEmpty ? [] : [String(repeating: "#", count: level) + " " + text]
        case "p", "dd", "figcaption", "address":
            let text = inline(element.children ?? [], style: Style()).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [escapeBlockStart(text)]
        case "dt", "summary":
            let text = oneLine(inline(element.children ?? [], style: Style(bold: true)))
            return text.isEmpty ? [] : ["**\(text)**"]
        case "ul", "ol":
            let list = self.list(element, ordered: name == "ol")
            return list.isEmpty ? [] : [list]
        case "li":
            return [item(element, marker: "- ")]
        case "blockquote", "aside":
            let inner = blocks(in: element).joined(separator: "\n\n")
            return inner.isEmpty ? [] : [quote(inner)]
        case "pre":
            return [fence(rawText(element), language: language(of: element))]
        case "hr":
            return ["---"]
        case "table":
            return table(element).map { [$0] } ?? []
        case "tr", "thead", "tbody", "tfoot":
            return blocks(in: element)
        default:
            // Notion's callouts are divs with a "callout" class.
            if (element.attribute(forName: "class")?.stringValue ?? "").contains("callout") {
                let inner = blocks(in: element).joined(separator: "\n\n")
                return inner.isEmpty ? [] : [quote(inner)]
            }
            return blocks(in: element)
        }
    }

    static func list(_ element: XMLElement, ordered: Bool) -> String {
        var number = Int(element.attribute(forName: "start")?.stringValue ?? "") ?? 1
        var items: [String] = []
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            let name = child.name?.lowercased() ?? ""
            if name == "li" {
                var marker = ordered ? "\(number). " : "- "
                if let checked = checkbox(in: child) { marker += checked ? "[x] " : "[ ] " }
                items.append(item(child, marker: marker))
                number += 1
            } else if name == "ul" || name == "ol" {
                // A list nested directly in a list belongs to the item before it.
                let nested = list(child, ordered: name == "ol")
                if !nested.isEmpty {
                    if items.isEmpty { items.append(nested) } else { items[items.count - 1] += "\n" + indent(nested, by: 2) }
                }
            }
        }
        return items.joined(separator: "\n")
    }

    /// One list item: its first block after the marker, the rest (nested lists too) indented under it.
    static func item(_ element: XMLElement, marker: String) -> String {
        let parts = blocks(in: element)
        guard let first = parts.first else { return marker.trimmingCharacters(in: .whitespaces) }
        let width = marker.count
        var text = marker + indent(first, by: width).dropFirst(width)
        for part in parts.dropFirst() {
            let isList = part.hasPrefix("- ") || part.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            text += (isList ? "\n" : "\n\n") + indent(part, by: width)
        }
        return text
    }

    /// A to-do checkbox in a list item: an `<input type="checkbox">` or Notion's checkbox classes.
    static func checkbox(in item: XMLElement) -> Bool? {
        var found: Bool?
        func visit(_ element: XMLElement, depth: Int) {
            guard found == nil, depth < 3 else { return }
            let name = element.name?.lowercased()
            if name == "input", element.attribute(forName: "type")?.stringValue?.lowercased() == "checkbox" {
                found = element.attribute(forName: "checked") != nil
                return
            }
            let classes = element.attribute(forName: "class")?.stringValue ?? ""
            if classes.contains("checkbox-on") || classes.contains("to-do-children-checked") { found = true; return }
            if classes.contains("checkbox-off") || classes.contains("to-do-children-unchecked") { found = false; return }
            for child in element.children ?? [] {
                if let child = child as? XMLElement, child.name?.lowercased() != "ul", child.name?.lowercased() != "ol" {
                    visit(child, depth: depth + 1)
                }
            }
        }
        for child in item.children ?? [] {
            if let child = child as? XMLElement { visit(child, depth: 0) }
        }
        return found
    }

    static func table(_ element: XMLElement) -> String? {
        var rows: [[String]] = []
        func collect(_ node: XMLElement) {
            for child in node.children ?? [] {
                guard let child = child as? XMLElement else { continue }
                switch child.name?.lowercased() {
                case "tr":
                    let cells = (child.children ?? []).compactMap { $0 as? XMLElement }
                        .filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
                        .map { oneLine(inline($0.children ?? [], style: Style())).replacingOccurrences(of: "|", with: "\\|") }
                    if !cells.isEmpty { rows.append(cells) }
                case "thead", "tbody", "tfoot":
                    collect(child)
                default:
                    break
                }
            }
        }
        collect(element)
        guard let header = rows.first else { return nil }
        let columns = rows.map(\.count).max() ?? header.count
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: columns - cells.count)
            return "| " + padded.map { $0.isEmpty ? " " : $0 }.joined(separator: " | ") + " |"
        }
        var lines = [line(header), "|" + Array(repeating: " --- |", count: columns).joined()]
        lines += rows.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }

    // MARK: Inline

    static func inline(_ nodes: [XMLNode], style: Style) -> String {
        nodes.map { inline($0, style: style) }.joined()
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
    }

    static func inline(_ node: XMLNode, style: Style) -> String {
        guard let element = node as? XMLElement else {
            guard node.kind == .text else { return "" }
            let collapsed = (node.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return style.code ? collapsed : escape(collapsed)
        }
        let name = element.name?.lowercased() ?? ""
        if skipped.contains(name) { return "" }
        let css = element.attribute(forName: "style")?.stringValue?.lowercased() ?? ""
        let children = element.children ?? []
        switch name {
        case "br":
            return "\n"
        case "img":
            return element.attribute(forName: "alt")?.stringValue.map(escape) ?? ""
        case "input":
            // A checkbox becomes the list item's "[x]" (see `checkbox(in:)`).
            return ""
        case "code", "kbd", "samp", "tt":
            return style.code ? rawText(element) : codeSpan(rawText(element))
        case "a":
            let text = inline(children, style: style)
            guard let href = element.attribute(forName: "href")?.stringValue,
                  href.hasPrefix("http") || href.hasPrefix("mailto:"),
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
            return "[\(text.trimmingCharacters(in: .whitespaces))](\(href.replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")))"
        default:
            break
        }
        var inner = style
        let boldTag = name == "b" || name == "strong"
        let fontWeight = cssValue("font-weight", in: css)
        if let fontWeight {
            if ["bold", "bolder", "600", "700", "800", "900"].contains(fontWeight) { inner.bold = true }
        } else if boldTag {
            inner.bold = true
        }
        let fontStyle = cssValue("font-style", in: css)
        if fontStyle == "italic" || ((name == "i" || name == "em") && fontStyle != "normal") { inner.italic = true }
        let decoration = cssValue("text-decoration", in: css) ?? cssValue("text-decoration-line", in: css) ?? ""
        if decoration.contains("line-through") || ["s", "del", "strike"].contains(name) { inner.strike = true }
        if let family = cssValue("font-family", in: css), ["mono", "courier", "menlo", "consolas", "sf mono"].contains(where: family.contains) {
            inner.code = true
        }
        if inner.code, !style.code {
            return codeSpan(rawText(element))
        }
        var text = inline(children, style: inner)
        if inner.strike && !style.strike { text = wrap(text, "~~") }
        if inner.italic && !style.italic { text = wrap(text, "*") }
        if inner.bold && !style.bold { text = wrap(text, "**") }
        return text
    }

    // MARK: Helpers

    /// Emphasis markers hug the text; surrounding spaces stay outside (Markdown needs that).
    static func wrap(_ text: String, _ marker: String) -> String {
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty, !core.contains("\n") else { return text }
        let lead = text.prefix { $0 == " " }
        let trail = String(text.reversed().prefix { $0 == " " })
        return "\(lead)\(marker)\(core)\(marker)\(trail)"
    }

    static func codeSpan(_ code: String) -> String {
        let code = code.replacingOccurrences(of: "\n", with: " ")
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { return code }
        return code.contains("`") ? "`` \(code) ``" : "`\(code)`"
    }

    static func fence(_ code: String, language: String?) -> String {
        let body = code.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
        let marker = body.contains("```") ? "~~~~" : "```"
        return "\(marker)\(language ?? "")\n\(body)\n\(marker)"
    }

    static func language(of pre: XMLElement) -> String? {
        let classes = [pre.attribute(forName: "class")?.stringValue] + (pre.elements(forName: "code").map { $0.attribute(forName: "class")?.stringValue })
        for value in classes.compactMap({ $0 }) {
            for name in value.split(separator: " ") {
                for prefix in ["language-", "lang-"] where name.hasPrefix(prefix) {
                    return String(name.dropFirst(prefix.count))
                }
            }
        }
        return nil
    }

    /// Text as written (for code), with `<br>` as new lines.
    static func rawText(_ element: XMLElement) -> String {
        (element.children ?? []).map { child -> String in
            if let child = child as? XMLElement {
                return child.name?.lowercased() == "br" ? "\n" : rawText(child)
            }
            return child.kind == .text ? (child.stringValue ?? "") : ""
        }.joined()
    }

    static func cssValue(_ property: String, in css: String) -> String? {
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == property { return parts[1] }
        }
        return nil
    }

    static func isPreformattedCode(_ body: XMLElement) -> Bool {
        let containers = ([body] + (body.children ?? []).compactMap { $0 as? XMLElement }).prefix(3)
        guard !containsStructure(body) else { return false }
        return containers.contains { element in
            let css = element.attribute(forName: "style")?.stringValue?.lowercased() ?? ""
            let monospace = cssValue("font-family", in: css).map { family in ["mono", "courier", "menlo", "consolas", "sf mono"].contains(where: family.contains) } ?? false
            return monospace && (cssValue("white-space", in: css)?.hasPrefix("pre") ?? false)
        }
    }

    /// Headings, paragraphs, lists or tables anywhere inside.
    static func containsStructure(_ element: XMLElement) -> Bool {
        let structural: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "pre", "blockquote"]
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            if structural.contains(child.name?.lowercased() ?? "") || containsStructure(child) { return true }
        }
        return false
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "*" || character == "`" { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A paragraph that would read as another kind of block keeps its first character literal.
    static func escapeBlockStart(_ text: String) -> String {
        if let first = text.first, "#>+-".contains(first) || text.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil {
            if first.isNumber, let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }) {
                return String(text[..<dot]) + "\\" + String(text[dot...])
            }
            return "\\" + text
        }
        return text
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func indent(_ text: String, by spaces: Int) -> String {
        let pad = String(repeating: " ", count: spaces)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
    }

    static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }
}

// MARK: - Attributed text to Markdown

private struct AttributedWriter {
    let text: NSAttributedString
    let bodySize: CGFloat

    init(_ text: NSAttributedString) {
        self.text = text
        // The most common font size is the body text; bigger bold lines are headings.
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize.rounded(), default: 0] += range.length }
        }
        bodySize = sizes.max { $0.value < $1.value }?.key ?? 13
    }

    func markdown() -> String {
        var blocks: [String] = []
        var code: [String] = []
        var listLines: [String] = []
        func flushCode() {
            if !code.isEmpty { blocks.append("```\n" + code.joined(separator: "\n") + "\n```") }
            code.removeAll()
        }
        func flushList() {
            if !listLines.isEmpty { blocks.append(listLines.joined(separator: "\n")) }
            listLines.removeAll()
        }
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { flushCode(); flushList(); return }
            let attributes = text.attributes(at: range.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
            let raw = string.substring(with: range)
            if let font, font.isFixedPitch || font.fontName.lowercased().contains("mono") {
                flushList()
                code.append(raw)
                return
            }
            flushCode()
            if let lists = paragraph?.textLists, let list = lists.last {
                // AppKit puts the marker in the text ("\t•\t"); drop it and write our own.
                let content = inline(NSRange(location: range.location, length: range.length))
                    .replacingOccurrences(of: #"^\s*[^\s]*\t"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                let ordered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha") || list.markerFormat.rawValue.contains("roman")
                let depth = max(0, lists.count - 1)
                listLines.append(String(repeating: "  ", count: depth) + (ordered ? "1. " : "- ") + content)
                return
            }
            flushList()
            let line = inline(range).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            if let font, font.pointSize >= bodySize * 1.15, font.fontDescriptor.symbolicTraits.contains(.bold) || font.pointSize >= bodySize * 1.4 {
                let ratio = font.pointSize / bodySize
                let level = ratio >= 1.8 ? 1 : ratio >= 1.4 ? 2 : 3
                blocks.append(String(repeating: "#", count: level) + " " + line.replacingOccurrences(of: "**", with: ""))
            } else {
                blocks.append(HTMLWriter.escapeBlockStart(line))
            }
        }
        flushCode()
        flushList()
        return blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One paragraph's runs with emphasis, strikethrough and links.
    private func inline(_ range: NSRange) -> String {
        var result = ""
        text.enumerateAttributes(in: range) { attributes, run, _ in
            var piece = (text.string as NSString).substring(with: run)
            piece = piece.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "`", with: "\\`")
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { piece = Self.wrap(piece, "~~") }
            if traits.contains(.italic) { piece = Self.wrap(piece, "*") }
            if traits.contains(.bold) { piece = Self.wrap(piece, "**") }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if url.hasPrefix("http") || url.hasPrefix("mailto:") { piece = "[\(piece.trimmingCharacters(in: .whitespaces))](\(url))" }
            }
            result += piece
        }
        return result
    }

    private static func wrap(_ text: String, _ marker: String) -> String {
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let lead = text.prefix { $0 == " " }
        let trail = String(text.reversed().prefix { $0 == " " })
        return "\(lead)\(marker)\(core)\(marker)\(trail)"
    }
}
