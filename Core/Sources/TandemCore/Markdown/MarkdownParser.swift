// A fast, dependency-free, block-level Markdown parser tuned for streaming AI answers.
//
// The parser follows CommonMark + GFM block structure closely enough for real-world model
// output, with a few deliberate leniencies (documented on `MarkdownDocument.parse(_:)`) that
// make sloppy or half-streamed Markdown render sensibly. Inline syntax (emphasis, code spans,
// links) is left untouched inside block strings; the view layer renders it.

// MARK: - Public model

/// A parsed Markdown document: the sequence of top-level blocks.
public struct MarkdownDocument: Sendable, Hashable {
    /// Top-level blocks in source order.
    public let blocks: [MarkdownBlock]

    /// Creates a document from already-built blocks.
    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    /// Parses Markdown source into block structure in linear time.
    ///
    /// Supported: ATX and setext headings, paragraphs, fenced code (```` ``` ```` / `~~~`) and
    /// indented code, nested blockquotes with lazy continuation, bullet / ordered / task lists
    /// with nesting and multi-paragraph items, GFM pipe tables, thematic breaks, and display math
    /// (`$$ … $$` or `\[ … \]`, reported as a code block with language `"math"`). HTML is kept
    /// as paragraph text. Line endings may be LF, CRLF, or CR.
    ///
    /// Streaming-friendly behavior:
    /// - An unterminated fence (or display-math block) yields `isClosed: false` with the content
    ///   received so far; a partially typed closing fence on the final line is hidden.
    /// - A table only appears once its delimiter row is complete; until then it is a paragraph.
    /// - On the final, still-open line (input not ending in a newline), a one- or two-character
    ///   `-`/`=` run is not taken as a setext underline, and an empty list marker may start a
    ///   list right after a paragraph, so a list that is being typed doesn't flash as a heading.
    ///
    /// Leniencies for model output: inside list items, indentation never creates indented code,
    /// a nested list marker indented less than the parent's content column still nests, and a
    /// fenced block opened inside an item keeps absorbing lines until it closes. Table rows must
    /// contain a `|` (a pipe-less line ends the table instead of becoming a row).
    public static func parse(_ text: String) -> MarkdownDocument {
        MarkdownDocument(blocks: MarkdownBlockParser.parse(text))
    }
}

/// A block-level Markdown element. Text payloads hold raw inline Markdown.
public indirect enum MarkdownBlock: Sendable, Hashable {
    /// An ATX (`#`) or setext heading; `level` is 1…6.
    case heading(level: Int, text: String)
    /// A paragraph of raw inline Markdown. Soft line breaks are preserved as `"\n"`.
    case paragraph(String)
    /// Fenced, indented, or display-math (`language == "math"`) code. `isClosed` is `false`
    /// while the closing fence hasn't arrived yet (streaming).
    case codeBlock(language: String?, code: String, isClosed: Bool)
    /// A blockquote containing nested blocks.
    case blockquote([MarkdownBlock])
    /// A bullet, ordered, or task list.
    case list(MarkdownList)
    /// A GFM pipe table.
    case table(MarkdownTable)
    /// A horizontal rule (`---`, `***`, `___`).
    case thematicBreak
}

/// A bullet or ordered list.
public struct MarkdownList: Sendable, Hashable {
    /// `true` for `1.` / `1)` lists, `false` for `-` / `*` / `+` bullets.
    public var ordered: Bool
    /// The number of the first item (ordered lists); `1` for bullet lists.
    public var start: Int
    /// The items, in order.
    public var items: [MarkdownListItem]
    /// `true` when no blank lines separate items or the blocks inside an item.
    public var isTight: Bool

    /// Creates a list.
    public init(ordered: Bool, start: Int, items: [MarkdownListItem], isTight: Bool) {
        self.ordered = ordered
        self.start = start
        self.items = items
        self.isTight = isTight
    }
}

/// One list item.
public struct MarkdownListItem: Sendable, Hashable {
    /// Task-list state: `nil` = no checkbox, `true` = `[x]`, `false` = `[ ]`.
    public var checkbox: Bool?
    /// The item's content blocks (usually a single paragraph, possibly followed by nested lists).
    public var blocks: [MarkdownBlock]

    /// Creates a list item.
    public init(checkbox: Bool? = nil, blocks: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

/// A GFM pipe table. Every row has exactly `header.count` cells (short rows are padded with
/// empty strings, long rows truncated). Cell strings are raw inline Markdown with `\|` unescaped.
public struct MarkdownTable: Sendable, Hashable {
    /// Horizontal alignment of a column, from the delimiter row (`:--`, `:-:`, `--:`).
    public enum Alignment: Sendable, Hashable {
        /// `---` or `:--`
        case leading
        /// `:-:`
        case center
        /// `--:`
        case trailing
    }

    /// Header cells; their count defines the number of columns.
    public var header: [String]
    /// One alignment per column (`alignments.count == header.count`).
    public var alignments: [Alignment]
    /// Body rows, each with `header.count` cells.
    public var rows: [[String]]

    /// Creates a table.
    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

// MARK: - Parser

enum MarkdownBlockParser {
    /// Container nesting (quotes / list items) beyond this depth is flattened into a paragraph,
    /// bounding recursion on pathological input such as thousands of `>` characters.
    static let maxDepth = 32

    static func parse(_ text: String) -> [MarkdownBlock] {
        var source = Substring(text)
        if source.utf8.first == 0xEF, source.hasPrefix("\u{FEFF}") {
            source = source.dropFirst()
        }
        let lines = splitLines(source)
        guard !lines.isEmpty else { return [] }
        let last = source.utf8.last
        let openTail = last != ASCII.lf && last != ASCII.cr
        let context = Context(inList: false, depth: 0, openTail: openTail)
        return parseBlocks(lines, context).blocks
    }

    /// Splits on LF, CRLF, or CR. A trailing line terminator does not produce an empty line.
    static func splitLines(_ text: Substring) -> [Line] {
        var lines: [Line] = []
        lines.reserveCapacity(text.utf8.count / 32 + 1)
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        var index = utf8.startIndex
        while index != utf8.endIndex {
            let byte = utf8[index]
            if byte == ASCII.lf || byte == ASCII.cr {
                lines.append(Line(text[lineStart..<index]))
                var next = utf8.index(after: index)
                if byte == ASCII.cr, next != utf8.endIndex, utf8[next] == ASCII.lf {
                    next = utf8.index(after: next)
                }
                lineStart = next
                index = next
            } else {
                utf8.formIndex(after: &index)
            }
        }
        if lineStart != utf8.endIndex {
            lines.append(Line(text[lineStart...]))
        }
        return lines
    }

    // MARK: Context

    struct Context {
        /// Inside a list item: indentation never starts indented code and block starts are
        /// recognized at any indentation.
        var inList: Bool
        var depth: Int
        /// The last line of the current line array is the input's final, unterminated line.
        var openTail: Bool

        func child(inList childInList: Bool, reachesEnd: Bool) -> Context {
            Context(inList: inList || childInList, depth: depth + 1, openTail: openTail && reachesEnd)
        }

        /// Whether `line` is shallow enough to start (or interrupt with) a block.
        func canStartBlock(_ line: Line) -> Bool {
            inList || line.indent < 4
        }
    }

    struct Accumulator {
        var blocks: [MarkdownBlock] = []
        var pendingBlank = false
        /// A blank line separated two blocks at this level (makes an enclosing list loose).
        var sawBlankBetweenBlocks = false

        mutating func noteBlank() {
            if !blocks.isEmpty { pendingBlank = true }
        }

        mutating func append(_ block: MarkdownBlock) {
            if pendingBlank {
                sawBlankBetweenBlocks = true
                pendingBlank = false
            }
            blocks.append(block)
        }
    }

    // MARK: Block sequence

    static func parseBlocks(_ lines: [Line], _ context: Context) -> Accumulator {
        var out = Accumulator()
        guard context.depth <= maxDepth else {
            let text = lines.filter { !$0.isBlank }.map { trimmed($0.content) }.joined(separator: "\n")
            if !text.isEmpty { out.append(.paragraph(text)) }
            return out
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.isBlank {
                out.noteBlank()
                index += 1
                continue
            }
            guard context.canStartBlock(line) else {
                index = parseIndentedCode(lines, from: index, into: &out)
                continue
            }
            if let fence = openingFence(line) {
                index = parseFencedCode(lines, from: index, fence: fence, context, into: &out)
            } else if let math = openingMath(line.content) {
                index = parseMath(lines, from: index, opening: math, context, into: &out)
            } else if let heading = atxHeading(line.content) {
                out.append(.heading(level: heading.level, text: heading.text))
                index += 1
            } else if isThematicBreak(line.content) {
                out.append(.thematicBreak)
                index += 1
            } else if line.content.utf8.first == ASCII.greaterThan {
                index = parseBlockquote(lines, from: index, context, into: &out)
            } else if let marker = listMarker(line) {
                index = parseList(lines, from: index, first: marker, context, into: &out)
            } else if let table = tableStart(lines, at: index, context) {
                index = parseTable(lines, from: index, start: table, context, into: &out)
            } else {
                index = parseParagraph(lines, from: index, context, into: &out)
            }
        }
        return out
    }

    // MARK: Paragraphs & setext headings

    static func parseParagraph(_ lines: [Line], from start: Int, _ context: Context, into out: inout Accumulator) -> Int {
        var parts: [Substring] = [lines[start].content]
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.isBlank { break }
            let isOpenTail = context.openTail && index == lines.count - 1
            if let level = setextLevel(line, isOpenTail: isOpenTail) {
                out.append(.heading(level: level, text: joinParagraph(parts)))
                return index + 1
            }
            if interruptsParagraph(line, context, isOpenTail: isOpenTail) { break }
            if tableStart(lines, at: index, context) != nil { break }
            parts.append(line.content)
            index += 1
        }
        out.append(.paragraph(joinParagraph(parts)))
        return index
    }

    /// Joins paragraph lines with `"\n"`, dropping trailing whitespace and hard-break
    /// backslashes (the newline itself is preserved, so the break survives).
    static func joinParagraph(_ parts: [Substring]) -> String {
        var result = ""
        result.reserveCapacity(parts.reduce(0) { $0 + $1.utf8.count + 1 })
        for (offset, part) in parts.enumerated() {
            var line = trimmed(part)
            if offset < parts.count - 1, line.utf8.last == ASCII.backslash {
                let withoutSlash = line.dropLast()
                if withoutSlash.utf8.last != ASCII.backslash {
                    line = trimmed(withoutSlash)
                }
            }
            if offset > 0 { result.append("\n") }
            result.append(contentsOf: line)
        }
        return result
    }

    /// `1` for a `===` underline, `2` for `---`, else `nil`.
    static func setextLevel(_ line: Line, isOpenTail: Bool) -> Int? {
        guard line.indent < 4, let first = line.content.utf8.first,
              first == ASCII.equals || first == ASCII.dash else { return nil }
        var count = 0
        var inTrailingSpace = false
        for byte in line.content.utf8 {
            if byte == first, !inTrailingSpace {
                count += 1
            } else if byte == ASCII.space || byte == ASCII.tab {
                inTrailingSpace = true
            } else {
                return nil
            }
        }
        if isOpenTail, count < 3 { return nil }
        return first == ASCII.equals ? 1 : 2
    }

    /// Whether `line` would end a paragraph (rather than continue it).
    static func interruptsParagraph(_ line: Line, _ context: Context, isOpenTail: Bool) -> Bool {
        guard let first = line.content.utf8.first else { return true }
        guard context.canStartBlock(line) else { return false }
        switch first {
        case ASCII.backtick, ASCII.tilde:
            return openingFence(line) != nil
        case ASCII.hash:
            return atxHeading(line.content) != nil
        case ASCII.greaterThan:
            return true
        case ASCII.dollar, ASCII.backslash:
            return openingMath(line.content) != nil
        case ASCII.dash, ASCII.star, ASCII.underscore, ASCII.plus, ASCII.zero...ASCII.nine:
            if isThematicBreak(line.content) { return true }
            guard let marker = listMarker(line) else { return false }
            if marker.isEmpty, !isOpenTail { return false }
            if marker.ordered, marker.number != 1 { return false }
            return true
        default:
            return false
        }
    }

    /// Whether a lazy continuation line may follow `line`, i.e. `line` (after stripping any
    /// quote / list markers) is paragraph text.
    static func isParagraphText(_ line: Line) -> Bool {
        var current = line
        for _ in 0..<maxDepth {
            if current.isBlank { return false }
            if current.content.utf8.first == ASCII.greaterThan {
                current = strippingQuoteMarker(current)
            } else if let marker = listMarker(current) {
                if marker.isEmpty { return false }
                current = Line(marker.firstContent)
            } else {
                break
            }
        }
        let content = current.content
        return !content.isEmpty
            && openingFence(current) == nil
            && atxHeading(content) == nil
            && !isThematicBreak(content)
            && openingMath(content) == nil
            && setextLevel(current, isOpenTail: false) == nil
    }

    // MARK: ATX headings & thematic breaks

    static func atxHeading(_ content: Substring) -> (level: Int, text: String)? {
        let utf8 = content.utf8
        var index = utf8.startIndex
        var level = 0
        while index != utf8.endIndex, utf8[index] == ASCII.hash, level < 7 {
            level += 1
            utf8.formIndex(after: &index)
        }
        guard (1...6).contains(level) else { return nil }
        if index != utf8.endIndex {
            let byte = utf8[index]
            guard byte == ASCII.space || byte == ASCII.tab else { return nil }
        }
        var text = trimmed(content[index...])
        // Optional closing sequence: trailing #s preceded by whitespace (or nothing else).
        let textUTF8 = text.utf8
        var hashesStart = textUTF8.endIndex
        while hashesStart != textUTF8.startIndex, textUTF8[textUTF8.index(before: hashesStart)] == ASCII.hash {
            textUTF8.formIndex(before: &hashesStart)
        }
        if hashesStart != textUTF8.endIndex {
            if hashesStart == textUTF8.startIndex {
                text = text[text.startIndex..<text.startIndex]
            } else {
                let before = textUTF8[textUTF8.index(before: hashesStart)]
                if before == ASCII.space || before == ASCII.tab {
                    text = trimmed(text[..<hashesStart])
                }
            }
        }
        return (level, String(text))
    }

    static func isThematicBreak(_ content: Substring) -> Bool {
        guard let first = content.utf8.first,
              first == ASCII.dash || first == ASCII.star || first == ASCII.underscore else { return false }
        var count = 0
        for byte in content.utf8 {
            if byte == first {
                count += 1
            } else if byte != ASCII.space, byte != ASCII.tab {
                return false
            }
        }
        return count >= 3
    }

    // MARK: Code

    struct Fence {
        let character: UInt8
        let length: Int
        let indent: Int
        let info: Substring
    }

    static func openingFence(_ line: Line) -> Fence? {
        let utf8 = line.content.utf8
        guard let first = utf8.first, first == ASCII.backtick || first == ASCII.tilde else { return nil }
        var index = utf8.startIndex
        var length = 0
        while index != utf8.endIndex, utf8[index] == first {
            length += 1
            utf8.formIndex(after: &index)
        }
        guard length >= 3 else { return nil }
        let info = line.content[index...]
        if first == ASCII.backtick, info.utf8.contains(ASCII.backtick) { return nil }
        return Fence(character: first, length: length, indent: line.indent, info: trimmed(info))
    }

    static func isClosingFence(_ line: Line, for fence: Fence, _ context: Context) -> Bool {
        guard context.canStartBlock(line) else { return false }
        let utf8 = line.content.utf8
        var index = utf8.startIndex
        var length = 0
        while index != utf8.endIndex, utf8[index] == fence.character {
            length += 1
            utf8.formIndex(after: &index)
        }
        guard length >= fence.length else { return false }
        while index != utf8.endIndex {
            let byte = utf8[index]
            guard byte == ASCII.space || byte == ASCII.tab else { return false }
            utf8.formIndex(after: &index)
        }
        return true
    }

    /// A final line that is the beginning of the closing fence (e.g. "``" of "```").
    static func isPartialClosingFence(_ line: Line, for fence: Fence) -> Bool {
        let content = trimmed(line.content)
        guard line.indent < 4, !content.isEmpty else { return false }
        var length = 0
        for byte in content.utf8 {
            guard byte == fence.character else { return false }
            length += 1
        }
        return length < fence.length
    }

    /// The first word of a fence info string (`python` for "```python title=x.py"), with a
    /// `{lang}` wrapper removed.
    static func language(fromInfo info: Substring) -> String? {
        let utf8 = info.utf8
        let end = utf8.firstIndex { $0 == ASCII.space || $0 == ASCII.tab } ?? utf8.endIndex
        var word = info[..<end]
        if word.utf8.first == ASCII.openBrace { word = word.dropFirst() }
        if word.utf8.last == ASCII.closeBrace { word = word.dropLast() }
        if word.utf8.first == ASCII.dot { word = word.dropFirst() }
        return word.isEmpty ? nil : String(word)
    }

    static func parseFencedCode(_ lines: [Line], from start: Int, fence: Fence, _ context: Context, into out: inout Accumulator) -> Int {
        var code: [Substring] = []
        var index = start + 1
        var closed = false
        while index < lines.count {
            let line = lines[index]
            index += 1
            if isClosingFence(line, for: fence, context) {
                closed = true
                break
            }
            code.append(line.stripping(columns: fence.indent).raw)
        }
        if !closed, context.openTail, start < lines.count - 1,
           isPartialClosingFence(lines[lines.count - 1], for: fence) {
            code.removeLast()
        }
        out.append(.codeBlock(language: language(fromInfo: fence.info), code: code.joined(separator: "\n"), isClosed: closed))
        return index
    }

    static func parseIndentedCode(_ lines: [Line], from start: Int, into out: inout Accumulator) -> Int {
        var code: [Substring] = []
        var keptCount = 0
        var index = start
        while index < lines.count {
            let line = lines[index]
            if !line.isBlank, line.indent < 4 { break }
            code.append(line.isBlank ? Substring() : line.stripping(columns: 4).raw)
            if !line.isBlank { keptCount = code.count }
            index += 1
        }
        out.append(.codeBlock(language: nil, code: code[..<keptCount].joined(separator: "\n"), isClosed: true))
        return start + keptCount
    }

    // MARK: Display math

    struct MathOpening {
        let closer: String
        /// Content of a one-line block such as `$$ x^2 $$`; `nil` for a multi-line opener.
        let singleLine: Substring?
    }

    static func openingMath(_ content: Substring) -> MathOpening? {
        guard let first = content.utf8.first, first == ASCII.dollar || first == ASCII.backslash else { return nil }
        let text = trimmed(content)
        let (opener, closer) = first == ASCII.dollar ? ("$$", "$$") : ("\\[", "\\]")
        if text == opener { return MathOpening(closer: closer, singleLine: nil) }
        guard text.utf8.count > 4, text.hasPrefix(opener), text.hasSuffix(closer) else { return nil }
        let inner = trimmed(text.dropFirst(2).dropLast(2))
        guard !inner.isEmpty else { return nil }
        return MathOpening(closer: closer, singleLine: inner)
    }

    static func parseMath(_ lines: [Line], from start: Int, opening: MathOpening, _ context: Context, into out: inout Accumulator) -> Int {
        if let single = opening.singleLine {
            out.append(.codeBlock(language: "math", code: String(single), isClosed: true))
            return start + 1
        }
        let indent = lines[start].indent
        var content: [Substring] = []
        var index = start + 1
        var closed = false
        while index < lines.count {
            let line = lines[index].stripping(columns: indent)
            index += 1
            let text = trimmed(line.content)
            if text == opening.closer {
                closed = true
                break
            }
            if text.hasSuffix(opening.closer) {
                let body = trimmed(text.dropLast(2))
                if !body.isEmpty { content.append(line.raw.prefix(upTo: body.endIndex)) }
                closed = true
                break
            }
            content.append(line.raw)
        }
        out.append(.codeBlock(language: "math", code: content.joined(separator: "\n"), isClosed: closed))
        return index
    }

    // MARK: Blockquotes

    static func strippingQuoteMarker(_ line: Line) -> Line {
        let content = line.content
        let afterMarker = content[content.utf8.index(after: content.startIndex)...]
        return Line(afterMarker).stripping(columns: 1)
    }

    static func parseBlockquote(_ lines: [Line], from start: Int, _ context: Context, into out: inout Accumulator) -> Int {
        var quoted: [Line] = []
        var fences = FenceTracker()
        var index = start
        while index < lines.count {
            let line = lines[index]
            if context.canStartBlock(line), line.content.utf8.first == ASCII.greaterThan {
                let inner = strippingQuoteMarker(line)
                quoted.append(inner)
                fences.consume(inner)
                index += 1
                continue
            }
            if line.isBlank { break }
            let isOpenTail = context.openTail && index == lines.count - 1
            if let last = quoted.last, !fences.isOpen, isParagraphText(last),
               !interruptsParagraph(line, context, isOpenTail: isOpenTail) {
                quoted.append(line) // lazy continuation
                index += 1
                continue
            }
            break
        }
        let inner = parseBlocks(quoted, context.child(inList: false, reachesEnd: index == lines.count))
        out.append(.blockquote(inner.blocks))
        return index
    }

    /// Tracks whether a fenced block is open while collecting a container's lines, so fence
    /// content is never mistaken for lazy continuation or container boundaries.
    struct FenceTracker {
        private var open: Fence?
        var isOpen: Bool { open != nil }

        mutating func consume(_ line: Line) {
            let lenient = Context(inList: true, depth: 0, openTail: false)
            if let fence = open {
                if isClosingFence(line, for: fence, lenient) { open = nil }
            } else if let fence = openingFence(line) {
                open = fence
            }
        }
    }

    // MARK: Lists

    struct ListMarker {
        let ordered: Bool
        /// The bullet character, or the ordered delimiter (`.` / `)`).
        let symbol: UInt8
        let number: Int
        /// Column where the marker starts.
        let markerIndent: Int
        /// Column where the item's content starts; continuation lines are indented this far.
        let contentIndent: Int
        /// The rest of the marker line.
        let firstContent: Substring

        var isEmpty: Bool { trimmed(firstContent).isEmpty }

        func continues(_ other: ListMarker) -> Bool {
            ordered == other.ordered && symbol == other.symbol
        }
    }

    static func listMarker(_ line: Line) -> ListMarker? {
        let content = line.content
        let utf8 = content.utf8
        guard let first = utf8.first else { return nil }
        var index = utf8.startIndex
        let ordered: Bool
        let symbol: UInt8
        var number = 0
        var width: Int
        if first == ASCII.dash || first == ASCII.star || first == ASCII.plus {
            ordered = false
            symbol = first
            width = 1
            utf8.formIndex(after: &index)
        } else if isDigit(first) {
            var digits = 0
            while index != utf8.endIndex, isDigit(utf8[index]) {
                digits += 1
                guard digits <= 9 else { return nil }
                number = number * 10 + Int(utf8[index] - ASCII.zero)
                utf8.formIndex(after: &index)
            }
            guard index != utf8.endIndex, utf8[index] == ASCII.dot || utf8[index] == ASCII.rightParen else { return nil }
            ordered = true
            symbol = utf8[index]
            width = digits + 1
            utf8.formIndex(after: &index)
        } else {
            return nil
        }

        let markerEnd = line.indent + width
        if index == utf8.endIndex {
            return ListMarker(ordered: ordered, symbol: symbol, number: number, markerIndent: line.indent,
                              contentIndent: markerEnd + 1, firstContent: content[index...])
        }
        guard utf8[index] == ASCII.space || utf8[index] == ASCII.tab else { return nil }
        if !ordered, isThematicBreak(content) { return nil }

        let spacingStart = index
        var column = markerEnd
        while index != utf8.endIndex, utf8[index] == ASCII.space || utf8[index] == ASCII.tab {
            column += utf8[index] == ASCII.tab ? 4 - column % 4 : 1
            utf8.formIndex(after: &index)
        }
        let spacing = column - markerEnd
        if index == utf8.endIndex || spacing >= 5 {
            // Blank item, or content that starts with indented code: content column is marker + 1.
            let rest = index == utf8.endIndex ? content[index...] : content[utf8.index(after: spacingStart)...]
            return ListMarker(ordered: ordered, symbol: symbol, number: number, markerIndent: line.indent,
                              contentIndent: markerEnd + 1, firstContent: rest)
        }
        return ListMarker(ordered: ordered, symbol: symbol, number: number, markerIndent: line.indent,
                          contentIndent: column, firstContent: content[index...])
    }

    /// Splits a leading `[ ]` / `[x]` task marker from an item's first line.
    static func taskCheckbox(_ content: Substring) -> (checked: Bool?, rest: Substring) {
        let utf8 = content.utf8
        var index = utf8.startIndex
        guard index != utf8.endIndex, utf8[index] == ASCII.leftBracket else { return (nil, content) }
        utf8.formIndex(after: &index)
        guard index != utf8.endIndex else { return (nil, content) }
        let mark = utf8[index]
        guard mark == ASCII.space || mark == ASCII.lowerX || mark == ASCII.upperX else { return (nil, content) }
        utf8.formIndex(after: &index)
        guard index != utf8.endIndex, utf8[index] == ASCII.rightBracket else { return (nil, content) }
        utf8.formIndex(after: &index)
        if index != utf8.endIndex {
            let next = utf8[index]
            guard next == ASCII.space || next == ASCII.tab else { return (nil, content) }
        }
        return (mark != ASCII.space, trimmedLeading(content[index...]))
    }

    static func parseList(_ lines: [Line], from start: Int, first: ListMarker, _ context: Context, into out: inout Accumulator) -> Int {
        var items: [MarkdownListItem] = []
        var loose = false
        var marker = first
        var itemStart = start
        var end = start

        while true {
            let (checkbox, firstContent) = taskCheckbox(marker.firstContent)
            let firstLine = Line(firstContent)
            var itemLines: [Line] = [firstLine]
            var fences = FenceTracker()
            fences.consume(firstLine)
            // The last line that a lazy continuation could extend; checked only on demand.
            var lazyTarget: Line? = fences.isOpen ? nil : firstLine
            var index = itemStart + 1

            collecting: while index < lines.count {
                let line = lines[index]
                if fences.isOpen {
                    // Inside a fence opened in this item: take everything until it closes,
                    // even if the model under-indented the code.
                    let inner = line.stripping(columns: min(line.indent, marker.contentIndent))
                    itemLines.append(inner)
                    fences.consume(inner)
                    lazyTarget = nil
                    index += 1
                    continue
                }
                if line.isBlank {
                    var next = index + 1
                    while next < lines.count, lines[next].isBlank { next += 1 }
                    guard next < lines.count else { break collecting }
                    let following = lines[next]
                    let continuesItem = following.indent >= marker.contentIndent
                        || (following.indent > marker.markerIndent && listMarker(following) != nil)
                    guard continuesItem else { break collecting }
                    for _ in index..<next { itemLines.append(Line(Substring())) }
                    lazyTarget = nil
                    index = next
                    continue
                }
                if line.indent >= marker.contentIndent {
                    let inner = line.stripping(columns: marker.contentIndent)
                    itemLines.append(inner)
                    fences.consume(inner)
                    lazyTarget = fences.isOpen ? nil : inner
                    index += 1
                    continue
                }
                if listMarker(line) != nil {
                    guard line.indent > marker.markerIndent else { break collecting }
                    // Nested marker indented less than the content column: nest it anyway.
                    let inner = Line(line.content)
                    itemLines.append(inner)
                    fences.consume(inner)
                    lazyTarget = fences.isOpen ? nil : inner
                    index += 1
                    continue
                }
                let isOpenTail = context.openTail && index == lines.count - 1
                if let target = lazyTarget, isParagraphText(target),
                   !interruptsParagraph(line, context.child(inList: true, reachesEnd: false), isOpenTail: isOpenTail),
                   tableStart(lines, at: index, context) == nil {
                    itemLines.append(Line(line.content)) // lazy continuation
                    index += 1
                    continue
                }
                break collecting
            }

            let parsed = parseBlocks(itemLines, context.child(inList: true, reachesEnd: index == lines.count))
            if parsed.sawBlankBetweenBlocks { loose = true }
            items.append(MarkdownListItem(checkbox: checkbox, blocks: parsed.blocks))
            end = index

            var next = index
            while next < lines.count, lines[next].isBlank { next += 1 }
            guard next < lines.count, context.canStartBlock(lines[next]),
                  let sibling = listMarker(lines[next]), sibling.continues(first) else { break }
            if next > index { loose = true }
            marker = sibling
            itemStart = next
        }

        out.append(.list(MarkdownList(
            ordered: first.ordered,
            start: first.ordered ? first.number : 1,
            items: items,
            isTight: !loose
        )))
        return end
    }

    // MARK: Tables

    struct TableStart {
        let header: [String]
        let alignments: [MarkdownTable.Alignment]
    }

    /// A table starts at `index` when that line has a pipe and the next line is a delimiter row
    /// with the same number of cells.
    static func tableStart(_ lines: [Line], at index: Int, _ context: Context) -> TableStart? {
        guard index + 1 < lines.count else { return nil }
        let delimiter = lines[index + 1]
        guard let first = delimiter.content.utf8.first,
              first == ASCII.pipe || first == ASCII.dash || first == ASCII.colon else { return nil }
        let headerLine = lines[index]
        guard context.canStartBlock(headerLine), context.canStartBlock(delimiter),
              let alignments = delimiterRow(delimiter.content),
              containsUnescapedPipe(headerLine.content) else { return nil }
        let header = splitCells(headerLine.content)
        guard header.count == alignments.count else { return nil }
        return TableStart(header: header.map(unescapingPipes), alignments: alignments)
    }

    static func delimiterRow(_ content: Substring) -> [MarkdownTable.Alignment]? {
        guard containsUnescapedPipe(content) else { return nil }
        let cells = splitCells(content)
        var alignments: [MarkdownTable.Alignment] = []
        alignments.reserveCapacity(cells.count)
        for cell in cells {
            let utf8 = cell.utf8
            guard let firstByte = utf8.first, let lastByte = utf8.last else { return nil }
            var dashes = 0
            for (offset, byte) in utf8.enumerated() {
                if byte == ASCII.dash {
                    dashes += 1
                } else if byte == ASCII.colon, offset == 0 || offset == utf8.count - 1 {
                    continue
                } else {
                    return nil
                }
            }
            guard dashes > 0 else { return nil }
            switch (firstByte == ASCII.colon, lastByte == ASCII.colon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    static func parseTable(_ lines: [Line], from start: Int, start table: TableStart, _ context: Context, into out: inout Accumulator) -> Int {
        let columns = table.header.count
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            if line.isBlank || !containsUnescapedPipe(line.content) { break }
            if interruptsParagraph(line, context, isOpenTail: false) { break }
            var cells = splitCells(line.content).prefix(columns).map(unescapingPipes)
            while cells.count < columns { cells.append("") }
            rows.append(cells)
            index += 1
        }
        out.append(.table(MarkdownTable(header: table.header, alignments: table.alignments, rows: rows)))
        return index
    }

    static func containsUnescapedPipe(_ content: Substring) -> Bool {
        var escaped = false
        for byte in content.utf8 {
            if escaped {
                escaped = false
            } else if byte == ASCII.backslash {
                escaped = true
            } else if byte == ASCII.pipe {
                return true
            }
        }
        return false
    }

    /// Splits a table row on unescaped pipes, ignoring one leading and one trailing pipe.
    static func splitCells(_ content: Substring) -> [Substring] {
        var row = trimmed(content)
        if row.utf8.first == ASCII.pipe {
            row = row[row.utf8.index(after: row.startIndex)...]
        }
        var cells: [Substring] = []
        let utf8 = row.utf8
        var cellStart = utf8.startIndex
        var index = utf8.startIndex
        var escaped = false
        while index != utf8.endIndex {
            let byte = utf8[index]
            if escaped {
                escaped = false
            } else if byte == ASCII.backslash {
                escaped = true
            } else if byte == ASCII.pipe {
                cells.append(trimmed(row[cellStart..<index]))
                cellStart = utf8.index(after: index)
            }
            utf8.formIndex(after: &index)
        }
        let tail = trimmed(row[cellStart...])
        // A trailing pipe closes the last cell rather than opening an empty one.
        if !tail.isEmpty || cells.isEmpty { cells.append(tail) }
        return cells
    }

    static func unescapingPipes(_ cell: Substring) -> String {
        guard cell.utf8.contains(ASCII.backslash) else { return String(cell) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cell.utf8.count)
        var pendingBackslash = false
        for byte in cell.utf8 {
            if pendingBackslash {
                pendingBackslash = false
                if byte != ASCII.pipe { bytes.append(ASCII.backslash) }
                bytes.append(byte)
            } else if byte == ASCII.backslash {
                pendingBackslash = true
            } else {
                bytes.append(byte)
            }
        }
        if pendingBackslash { bytes.append(ASCII.backslash) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension MarkdownBlockParser {
    // MARK: - Lines

    /// One source line (without its terminator), with its leading indentation measured.
    struct Line {
        /// The full line.
        let raw: Substring
        /// Leading whitespace width in columns (tabs advance to the next multiple of 4).
        let indent: Int
        /// `raw` without leading whitespace.
        let content: Substring

        /// The leading whitespace contains no tabs (so one byte == one column).
        private let spacesOnly: Bool

        init(_ raw: Substring) {
            self.raw = raw
            var columns = 0
            var sawTab = false
            let utf8 = raw.utf8
            var index = utf8.startIndex
            while index != utf8.endIndex {
                let byte = utf8[index]
                if byte == ASCII.space {
                    columns += 1
                } else if byte == ASCII.tab {
                    columns += 4 - columns % 4
                    sawTab = true
                } else {
                    break
                }
                utf8.formIndex(after: &index)
            }
            indent = columns
            content = raw[index...]
            spacesOnly = !sawTab
        }

        private init(raw: Substring, indent: Int, content: Substring) {
            self.raw = raw
            self.indent = indent
            self.content = content
            self.spacesOnly = true
        }

        /// `true` for empty or whitespace-only lines.
        var isBlank: Bool { content.isEmpty }

        /// Removes up to `columns` columns of leading whitespace, splitting a tab if needed.
        func stripping(columns: Int) -> Line {
            guard columns > 0, indent > 0 else { return self }
            if columns >= indent { return Line(raw: content, indent: 0, content: content) }
            let utf8 = raw.utf8
            if spacesOnly {
                // O(1): deeply nested containers re-strip the same lines once per level.
                let start = utf8.index(utf8.startIndex, offsetBy: columns)
                return Line(raw: raw[start...], indent: indent - columns, content: content)
            }
            var column = 0
            var index = utf8.startIndex
            while index != utf8.endIndex, column < columns {
                if utf8[index] == ASCII.tab {
                    let next = column + 4 - column % 4
                    if next > columns {
                        let rest = raw[utf8.index(after: index)...]
                        return Line(Substring(String(repeating: " ", count: next - columns) + rest))
                    }
                    column = next
                } else {
                    column += 1
                }
                utf8.formIndex(after: &index)
            }
            return Line(raw[index...])
        }
    }

    // MARK: - Byte helpers

    enum ASCII {
        static let tab: UInt8 = 0x09
        static let lf: UInt8 = 0x0A
        static let cr: UInt8 = 0x0D
        static let space: UInt8 = 0x20
        static let hash: UInt8 = 0x23
        static let dollar: UInt8 = 0x24
        static let rightParen: UInt8 = 0x29
        static let star: UInt8 = 0x2A
        static let plus: UInt8 = 0x2B
        static let dash: UInt8 = 0x2D
        static let dot: UInt8 = 0x2E
        static let zero: UInt8 = 0x30
        static let nine: UInt8 = 0x39
        static let colon: UInt8 = 0x3A
        static let equals: UInt8 = 0x3D
        static let greaterThan: UInt8 = 0x3E
        static let upperX: UInt8 = 0x58
        static let leftBracket: UInt8 = 0x5B
        static let backslash: UInt8 = 0x5C
        static let rightBracket: UInt8 = 0x5D
        static let underscore: UInt8 = 0x5F
        static let backtick: UInt8 = 0x60
        static let lowerX: UInt8 = 0x78
        static let openBrace: UInt8 = 0x7B
        static let pipe: UInt8 = 0x7C
        static let closeBrace: UInt8 = 0x7D
        static let tilde: UInt8 = 0x7E
    }

    @inline(__always)
    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= ASCII.zero && byte <= ASCII.nine
    }

    @inline(__always)
    static func isSpaceOrTab(_ byte: UInt8) -> Bool {
        byte == ASCII.space || byte == ASCII.tab
    }

    /// Removes leading and trailing spaces and tabs.
    static func trimmed(_ text: Substring) -> Substring {
        let utf8 = text.utf8
        var start = utf8.startIndex
        var end = utf8.endIndex
        while start != end, isSpaceOrTab(utf8[start]) { utf8.formIndex(after: &start) }
        while end != start {
            let before = utf8.index(before: end)
            guard isSpaceOrTab(utf8[before]) else { break }
            end = before
        }
        return text[start..<end]
    }

    /// Removes leading spaces and tabs.
    static func trimmedLeading(_ text: Substring) -> Substring {
        let utf8 = text.utf8
        var start = utf8.startIndex
        while start != utf8.endIndex, isSpaceOrTab(utf8[start]) { utf8.formIndex(after: &start) }
        return text[start...]
    }
}
