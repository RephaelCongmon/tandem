import SwiftUI
import TandemCore

/// Passive overlays cannot use horizontal scroll areas or copy buttons. Code
/// wraps, and tables become labeled rows so every column remains reachable.
struct GlanceMarkdownView: View {
    let blocks: [MarkdownBlock]
    let fontSize: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                GlanceMarkdownBlock(block: block, fontSize: fontSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GlanceMarkdownBlock: View {
    let block: MarkdownBlock
    let fontSize: Double
    @ViewBuilder var body: some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(.system(size: fontSize + Double(max(0, 4 - level)) * 2, weight: .bold))
        case .paragraph(let text):
            inline(text).font(.system(size: fontSize))
        case .codeBlock(let language, let code, _):
            VStack(alignment: .leading, spacing: 6) {
                Text(language?.uppercased() ?? "CODE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Text(verbatim: code).font(.system(size: fontSize - 1, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        case .blockquote(let blocks):
            GlanceMarkdownView(blocks: blocks, fontSize: fontSize).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.4)).frame(width: 2) }
        case .list(let list):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(list.items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        let item = list.items[index]
                        Text(item.checkbox.map { $0 ? "☑" : "☐" } ?? (list.ordered ? "\(list.start + index)." : "•"))
                            .font(.system(size: fontSize))
                        GlanceMarkdownView(blocks: item.blocks, fontSize: fontSize)
                    }
                }
            }
        case .table(let table):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(table.rows.indices, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(table.header.indices, id: \.self) { column in
                            VStack(alignment: .leading, spacing: 2) {
                                inline(table.header[column]).font(.system(size: fontSize - 2, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                                inline(table.rows[row][column]).font(.system(size: fontSize))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                if table.rows.isEmpty { inline(table.header.joined(separator: " · ")).font(.system(size: fontSize)) }
            }
        case .thematicBreak:
            Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
        }
    }
    private func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
}
