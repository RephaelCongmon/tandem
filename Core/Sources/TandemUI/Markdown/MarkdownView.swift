import AppKit
import SwiftUI
import TandemCore

// MARK: - Style

/// Visual parameters for `MarkdownView`. Colors and fonts default to the Tandem design system.
public struct MarkdownStyle: Hashable, Sendable {
    /// Font for paragraphs, list items, quotes, and table cells.
    public var bodyFont: Font
    /// Primary text color (blockquotes use `Theme.textSecondary`).
    public var textColor: Color
    /// Tighter fonts and spacing, for small panels such as the reply mirror.
    public var compact: Bool
    /// Font for code blocks and inline code spans in body text.
    public var codeFont: Font
    /// Code blocks get a Copy button (off where nothing can be clicked, like the Glance overlay).
    public var showsCopyButtons: Bool
    /// Wrap code and stack tables that don't fit, instead of scrolling sideways (for views
    /// nobody can scroll, like the click-through Glance overlay).
    public var wrapsWideContent: Bool

    /// Creates a style. `codeFont` defaults to the design system's mono font for the density.
    public init(
        bodyFont: Font = TandemFont.body,
        textColor: Color = Theme.textPrimary,
        compact: Bool = false,
        codeFont: Font? = nil,
        showsCopyButtons: Bool = true,
        wrapsWideContent: Bool = false
    ) {
        self.bodyFont = bodyFont
        self.textColor = textColor
        self.compact = compact
        self.codeFont = codeFont ?? (compact ? TandemFont.monoSmall : TandemFont.mono)
        self.showsCopyButtons = showsCopyButtons
        self.wrapsWideContent = wrapsWideContent
    }

    /// Chat-thread density: 13.5 pt body.
    public static let standard = MarkdownStyle()

    /// Small-panel density: 12.5 pt body, tighter spacing, smaller headings.
    public static let compact = MarkdownStyle(bodyFont: TandemFont.callout, compact: true)

    var metrics: MarkdownMetrics { compact ? .compact : .standard }

    func withTextColor(_ color: Color) -> MarkdownStyle {
        var copy = self
        copy.textColor = color
        return copy
    }
}

/// Spacing and type scale derived from the style's density.
struct MarkdownMetrics {
    let blockSpacing: CGFloat
    let lineSpacing: CGFloat
    let tightItemSpacing: CGFloat
    let markerSpacing: CGFloat
    let bulletGutter: CGFloat
    let quoteIndent: CGFloat
    let ruleVerticalPadding: CGFloat
    let codeHorizontalPadding: CGFloat
    let codeVerticalPadding: CGFloat
    let codeLineSpacing: CGFloat
    let codeHeaderHeight: CGFloat
    let copyButtonSize: CGFloat
    let cellHorizontalPadding: CGFloat
    let cellVerticalPadding: CGFloat
    let cellMaxWidth: CGFloat
    /// Index 0 = H1 … index 3 = H4 and deeper.
    let headingFonts: [Font]
    let headingCodeFonts: [Font]
    let headingTopPadding: [CGFloat]

    func headingIndex(_ level: Int) -> Int { min(max(level, 1), 4) - 1 }

    static let standard = MarkdownMetrics(
        blockSpacing: Spacing.s,
        lineSpacing: 2.5,
        tightItemSpacing: Spacing.xs,
        markerSpacing: 6,
        bulletGutter: 14,
        quoteIndent: 13,
        ruleVerticalPadding: Spacing.xs,
        codeHorizontalPadding: Spacing.m,
        codeVerticalPadding: 10,
        codeLineSpacing: 2,
        codeHeaderHeight: 28,
        copyButtonSize: 22,
        cellHorizontalPadding: 10,
        cellVerticalPadding: 6,
        cellMaxWidth: 300,
        headingFonts: headingScale([(20, .bold), (17, .bold), (15, .semibold), (13.5, .semibold)]),
        headingCodeFonts: headingScale([(20, .bold), (17, .bold), (15, .semibold), (13.5, .semibold)], monospaced: true),
        headingTopPadding: [10, 8, 6, 4]
    )

    static let compact = MarkdownMetrics(
        blockSpacing: 6,
        lineSpacing: 2,
        tightItemSpacing: 3,
        markerSpacing: 5,
        bulletGutter: 12,
        quoteIndent: 11,
        ruleVerticalPadding: 3,
        codeHorizontalPadding: 10,
        codeVerticalPadding: Spacing.s,
        codeLineSpacing: 1.5,
        codeHeaderHeight: 24,
        copyButtonSize: 20,
        cellHorizontalPadding: Spacing.s,
        cellVerticalPadding: Spacing.xs,
        cellMaxWidth: 220,
        headingFonts: headingScale([(16, .bold), (14.5, .bold), (13.5, .semibold), (12.5, .semibold)]),
        headingCodeFonts: headingScale([(16, .bold), (14.5, .bold), (13.5, .semibold), (12.5, .semibold)], monospaced: true),
        headingTopPadding: [6, 5, 4, 3]
    )

    private static func headingScale(_ scale: [(CGFloat, Font.Weight)], monospaced: Bool = false) -> [Font] {
        scale.map { size, weight in
            Font.system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
        }
    }
}

// MARK: - MarkdownView

/// Renders Markdown (typically a streaming AI answer) with the Tandem design system.
///
/// Block structure comes from `MarkdownDocument`; inline Markdown (emphasis, code spans, links)
/// is rendered with `AttributedString` and memoized, so re-evaluating the view on every streamed
/// token only re-renders the blocks whose text changed. Links open through the environment's
/// `openURL` action. The view is a plain `VStack` — safe to nest inside lazy stacks.
public struct MarkdownView: View {
    private let document: MarkdownDocument
    private let style: MarkdownStyle

    /// Parses `text` (memoized) and renders it.
    public init(_ text: String, style: MarkdownStyle = .standard) {
        self.document = MarkdownDocumentCache.document(for: text)
        self.style = style
    }

    /// Renders an already-parsed document.
    public init(document: MarkdownDocument, style: MarkdownStyle = .standard) {
        self.document = document
        self.style = style
    }

    /// The rendered blocks, with text selection enabled.
    public var body: some View {
        MarkdownBlocksView(
            blocks: document.blocks,
            style: style,
            listDepth: 0,
            spacing: style.metrics.blockSpacing
        )
        .textSelection(.enabled)
    }
}

// MARK: - Blocks

struct MarkdownBlocksView: View, Equatable {
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    let listDepth: Int
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Offsets as identity: while streaming, the last block updates in place.
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], style: style, listDepth: listDepth, isFirst: index == 0)
                    .equatable()
            }
        }
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let style: MarkdownStyle
    let listDepth: Int
    let isFirst: Bool

    var body: some View {
        let metrics = style.metrics
        switch block {
        case let .heading(level, text):
            if !text.isEmpty {
                let index = metrics.headingIndex(level)
                InlineText(
                    source: text,
                    font: metrics.headingFonts[index],
                    codeFont: metrics.headingCodeFonts[index],
                    color: style.textColor,
                    lineSpacing: metrics.lineSpacing
                )
                .padding(.top, isFirst ? 0 : metrics.headingTopPadding[index])
                .accessibilityAddTraits(.isHeader)
            }
        case let .paragraph(text):
            InlineText(
                source: text,
                font: style.bodyFont,
                codeFont: style.codeFont,
                color: style.textColor,
                lineSpacing: metrics.lineSpacing
            )
        case let .codeBlock(language, code, isClosed):
            CodeBlockView(language: language, code: code, isClosed: isClosed, style: style)
        case let .blockquote(blocks):
            MarkdownBlocksView(
                blocks: blocks,
                style: style.withTextColor(Theme.textSecondary),
                listDepth: listDepth,
                spacing: metrics.blockSpacing
            )
            .padding(.leading, metrics.quoteIndent)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.accent.opacity(0.5))
                    .frame(width: 3)
            }
        case let .list(list):
            MarkdownListView(list: list, style: style, depth: listDepth)
        case let .table(table):
            MarkdownTableView(table: table, style: style)
        case .thematicBreak:
            Hairline()
                .padding(.vertical, metrics.ruleVerticalPadding)
        }
    }
}

/// A run of inline Markdown rendered as a single selectable `Text`.
struct InlineText: View {
    let source: String
    let font: Font
    let codeFont: Font
    let color: Color
    let lineSpacing: CGFloat

    var body: some View {
        Text(InlineMarkdown.attributedString(for: source, codeFont: codeFont))
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Code blocks

struct CodeBlockView: View {
    let language: String?
    let code: String
    let isClosed: Bool
    let style: MarkdownStyle

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        let metrics = style.metrics
        VStack(alignment: .leading, spacing: 0) {
            header(metrics)
            Hairline()
            let text = Text(verbatim: code.isEmpty ? " " : code)
                .font(style.codeFont)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(metrics.codeLineSpacing)
            if style.wrapsWideContent {
                text
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, metrics.codeHorizontalPadding)
                    .padding(.vertical, metrics.codeVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HorizontalOverflow {
                    text
                        .fixedSize()
                        .padding(.horizontal, metrics.codeHorizontalPadding)
                        .padding(.vertical, metrics.codeVerticalPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .tandemPanel(cornerRadius: Radius.m, fill: Theme.surfaceSunken)
        .onDisappear { resetTask?.cancel() }
    }

    private func header(_ metrics: MarkdownMetrics) -> some View {
        HStack(spacing: Spacing.s) {
            Text(verbatim: language ?? "code")
                .font(TandemFont.micro)
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            if !isClosed {
                StreamingIndicator()
                    .transition(.opacity)
            }
            Spacer(minLength: Spacing.s)
            if style.showsCopyButtons {
                IconButton(
                    copied ? "checkmark" : "doc.on.doc",
                    help: copied ? "Copied" : "Copy code",
                    size: metrics.copyButtonSize,
                    isActive: copied,
                    tint: Theme.success,
                    action: copy
                )
            }
        }
        .padding(.leading, metrics.codeHorizontalPadding)
        .padding(.trailing, Spacing.xs)
        .frame(height: metrics.codeHeaderHeight)
        .textSelection(.disabled)
        .animation(.easeOut(duration: 0.2), value: isClosed)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

/// Three softly pulsing dots shown while a code block's closing fence hasn't arrived.
struct StreamingIndicator: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 4, height: 4)
                    .opacity(pulsing ? 0.9 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
        .help("Streaming")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streaming")
    }
}

// MARK: - Lists

struct MarkdownListView: View {
    let list: MarkdownList
    let style: MarkdownStyle
    let depth: Int

    var body: some View {
        let metrics = style.metrics
        let spacing = list.isTight ? metrics.tightItemSpacing : metrics.blockSpacing
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: metrics.markerSpacing) {
                    marker(for: item, at: index, metrics: metrics)
                    MarkdownBlocksView(blocks: item.blocks, style: style, listDepth: depth + 1, spacing: spacing)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, at index: Int, metrics: MarkdownMetrics) -> some View {
        if let checked = item.checkbox {
            Text(Image(systemName: checked ? "checkmark.square.fill" : "square"))
                .font(style.bodyFont)
                .foregroundStyle(checked ? Theme.accent : Theme.textTertiary)
                .frame(minWidth: metrics.bulletGutter)
                .accessibilityLabel(checked ? "Completed" : "Not completed")
        } else if list.ordered {
            // The hidden widest label gives every number in the list the same gutter.
            ZStack(alignment: .trailing) {
                Text(verbatim: widestOrdinal).hidden()
                Text(verbatim: "\(list.start + index).")
            }
            .font(style.bodyFont.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
        } else {
            Text(verbatim: bullet)
                .font(style.bodyFont)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: metrics.bulletGutter)
        }
    }

    private var widestOrdinal: String {
        let last = list.start + max(list.items.count - 1, 0)
        return String(repeating: "0", count: String(max(last, list.start)).count) + "."
    }

    private var bullet: String {
        switch depth % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}

// MARK: - Tables

struct MarkdownTableView: View {
    let table: MarkdownTable
    let style: MarkdownStyle

    var body: some View {
        if style.wrapsWideContent {
            // A table that doesn't fit becomes one card per row, so every column stays readable.
            ViewThatFits(in: .horizontal) {
                grid
                stacked
            }
        } else {
            HorizontalOverflow { grid }
        }
    }

    private var grid: some View {
        let metrics = style.metrics
        let columns = table.header.count
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(table.header[column], column: column, isHeader: true, metrics: metrics)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    Hairline()
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(table.rows[row][column], column: column, isHeader: false, metrics: metrics)
                        }
                    }
                }
            }
            .fixedSize()
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }

    private var stacked: some View {
        let metrics = style.metrics
        return VStack(alignment: .leading, spacing: metrics.tightItemSpacing) {
            ForEach(table.rows.indices, id: \.self) { row in
                // One line per column: its name, then the value (which wraps).
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: metrics.cellHorizontalPadding, verticalSpacing: metrics.tightItemSpacing) {
                    ForEach(table.header.indices, id: \.self) { column in
                        GridRow {
                            InlineText(
                                source: Self.replacingLineBreakTags(table.header[column]),
                                font: TandemFont.micro,
                                codeFont: style.codeFont,
                                color: Theme.textSecondary,
                                lineSpacing: metrics.lineSpacing
                            )
                            .fixedSize()
                            InlineText(
                                source: Self.replacingLineBreakTags(column < table.rows[row].count ? table.rows[row][column] : ""),
                                font: style.bodyFont,
                                codeFont: style.codeFont,
                                color: style.textColor,
                                lineSpacing: metrics.lineSpacing
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, metrics.cellHorizontalPadding)
                .padding(.vertical, metrics.cellVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
            }
        }
    }

    private func cell(_ text: String, column: Int, isHeader: Bool, metrics: MarkdownMetrics) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return CappedWidth(maxWidth: metrics.cellMaxWidth) {
            InlineText(
                source: Self.replacingLineBreakTags(text),
                font: isHeader ? style.bodyFont.weight(.semibold) : style.bodyFont,
                codeFont: style.codeFont,
                color: style.textColor,
                lineSpacing: metrics.lineSpacing
            )
            .multilineTextAlignment(alignment.textAlignment)
        }
        .padding(.horizontal, metrics.cellHorizontalPadding)
        .padding(.vertical, metrics.cellVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frameAlignment)
        .background(isHeader ? Theme.surfaceRaised : Color.clear)
    }

    /// Models often put `<br>` in cells for line breaks; honor it.
    static func replacingLineBreakTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return text.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

private extension MarkdownTable.Alignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Layout helpers

/// Shows `content` at its ideal width when it fits, otherwise inside a horizontal scroll view.
/// Avoids a scroll view (and its scroll-wheel handling) for the common narrow case.
struct HorizontalOverflow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content
            ScrollView(.horizontal) {
                content
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}

/// Lays out its single child at `min(idealWidth, maxWidth, proposedWidth)`, so long table cells
/// wrap instead of stretching the table (even under an unconstrained width proposal).
struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(childProposal(proposal, child: child))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(childProposal(ProposedViewSize(width: bounds.width, height: nil), child: child))
        child.place(at: bounds.origin, proposal: ProposedViewSize(width: size.width, height: size.height))
    }

    private func childProposal(_ proposal: ProposedViewSize, child: LayoutSubview) -> ProposedViewSize {
        let ideal = child.sizeThatFits(.unspecified).width
        let width = min(ideal, maxWidth, proposal.width ?? .infinity)
        return ProposedViewSize(width: max(width, 0), height: nil)
    }
}

// MARK: - Inline rendering

/// Converts inline Markdown to a styled `AttributedString`, memoized per (source, code font).
enum InlineMarkdown {
    private static let cache: NSCache<InlineCacheKey, AttributedStringBox> = {
        let cache = NSCache<InlineCacheKey, AttributedStringBox>()
        cache.countLimit = 1_000
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let parseOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    static func attributedString(for source: String, codeFont: Font) -> AttributedString {
        let key = InlineCacheKey(text: source, font: codeFont)
        if let cached = cache.object(forKey: key) { return cached.value }
        let rendered = render(source, codeFont: codeFont)
        cache.setObject(AttributedStringBox(rendered), forKey: key, cost: source.utf8.count)
        return rendered
    }

    static func render(_ source: String, codeFont: Font) -> AttributedString {
        var attributed: AttributedString
        if needsMarkdownParsing(source) {
            attributed = (try? AttributedString(markdown: source, options: parseOptions)) ?? AttributedString(source)
        } else {
            attributed = AttributedString(source)
        }

        var codeRanges: [Range<AttributedString.Index>] = []
        var linkRanges: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                codeRanges.append(run.range)
            } else if run.link != nil {
                linkRanges.append(run.range)
            }
        }
        for range in codeRanges {
            attributed[range].font = codeFont
            attributed[range].foregroundColor = Theme.accent
        }
        linkRanges += detectBareLinks(in: &attributed, source: source)
        for range in linkRanges {
            attributed[range].foregroundColor = Theme.accent
        }
        return attributed
    }

    /// Plain prose without Markdown punctuation skips the (comparatively slow) Markdown parser.
    private static func needsMarkdownParsing(_ source: String) -> Bool {
        for byte in source.utf8 {
            switch byte {
            case UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "`"), UInt8(ascii: "["),
                 UInt8(ascii: "<"), UInt8(ascii: "\\"), UInt8(ascii: "&"), UInt8(ascii: "~"):
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Turns bare `http(s)://` and `www.` URLs outside code spans and existing links into links.
    private static func detectBareLinks(in attributed: inout AttributedString, source: String) -> [Range<AttributedString.Index>] {
        guard let linkDetector, source.contains("://") || source.contains("www.") else { return [] }
        let plain = String(attributed.characters)
        let matches = linkDetector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        var ranges: [Range<AttributedString.Index>] = []
        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: attributed) else { continue }
            let overlapsMarkup = attributed[range].runs.contains { run in
                run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
            }
            guard !overlapsMarkup else { continue }
            attributed[range].link = url
            ranges.append(range)
        }
        return ranges
    }
}

final class InlineCacheKey: NSObject {
    let text: String
    let font: Font
    private let hashCode: Int

    init(text: String, font: Font) {
        self.text = text
        self.font = font
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(font)
        self.hashCode = hasher.finalize()
    }

    override var hash: Int { hashCode }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? InlineCacheKey else { return false }
        return hashCode == other.hashCode && text == other.text && font == other.font
    }
}

final class AttributedStringBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// Memoizes `MarkdownDocument.parse` so re-created views (e.g. a chat row re-evaluated for an
/// unrelated state change) don't re-parse unchanged text.
enum MarkdownDocumentCache {
    private static let cache: NSCache<NSString, DocumentBox> = {
        let cache = NSCache<NSString, DocumentBox>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    static func document(for text: String) -> MarkdownDocument {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let document = MarkdownDocument.parse(text)
        cache.setObject(DocumentBox(document), forKey: key, cost: text.utf8.count)
        return document
    }
}

final class DocumentBox {
    let value: MarkdownDocument
    init(_ value: MarkdownDocument) { self.value = value }
}
