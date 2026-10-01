import AppKit
import TandemCore
import XCTest
@testable import TandemUI

/// Pasting a formatted document into the Glance keeps its formatting.
final class RichTextMarkdownTests: XCTestCase {
    private func blocks(_ markdown: String?) -> [MarkdownBlock] {
        MarkdownDocument.parse(markdown ?? "").blocks
    }

    func testANotionPageKeepsItsStructure() throws {
        // The shape Notion puts on the pasteboard: semantic HTML.
        let html = """
        <meta charset='utf-8'><h1>Interview plan</h1>
        <p>Ask about <strong>the timeline</strong>, <em>owners</em> and <code>retry_budget</code>. See <a href="https://example.com/doc">the doc</a>.</p>
        <h2>Topics</h2>
        <ul><li>Migration<ul><li>Rollback plan</li></ul></li><li>Hiring</li></ul>
        <ol><li>Intro</li><li>Questions</li></ol>
        <ul class="to-do-list"><li><div class="checkbox checkbox-on"></div> <span class="to-do-children-checked">Book the room</span></li><li><div class="checkbox checkbox-off"></div> <span class="to-do-children-unchecked">Send the agenda</span></li></ul>
        <blockquote>Keep answers short.</blockquote>
        <div class="callout"><span>💡</span><div>Smile.</div></div>
        <pre><code class="language-python">def backoff(n):
            return min(30, 2 ** n)
        </code></pre>
        <hr>
        <table><thead><tr><th>Metric</th><th>Before</th><th>After</th></tr></thead><tbody><tr><td>p50</td><td>120 ms</td><td>72 ms</td></tr></tbody></table>
        """
        let markdown = try XCTUnwrap(RichTextMarkdown.markdown(html: html))
        XCTAssertTrue(markdown.hasPrefix("# Interview plan\n\nAsk about **the timeline**, *owners* and `retry_budget`. See [the doc](https://example.com/doc)."), markdown)
        XCTAssertTrue(markdown.contains("- Migration\n  - Rollback plan\n- Hiring"), markdown)
        XCTAssertTrue(markdown.contains("1. Intro\n2. Questions"), markdown)
        XCTAssertTrue(markdown.contains("- [x] Book the room\n- [ ] Send the agenda"), markdown)
        XCTAssertTrue(markdown.contains("```python\ndef backoff(n):\n    return min(30, 2 ** n)\n```"), markdown)
        XCTAssertTrue(markdown.contains("| Metric | Before | After |\n| --- | --- | --- |\n| p50 | 120 ms | 72 ms |"), markdown)

        let parsed = blocks(markdown)
        XCTAssertEqual(parsed.first, .heading(level: 1, text: "Interview plan"))
        XCTAssertTrue(parsed.contains(.heading(level: 2, text: "Topics")))
        XCTAssertTrue(parsed.contains(.thematicBreak))
        XCTAssertTrue(parsed.contains { if case .codeBlock(let language, _, _) = $0 { return language == "python" } else { return false } })
        XCTAssertTrue(parsed.contains { if case .table = $0 { return true } else { return false } })
        XCTAssertEqual(parsed.filter { if case .blockquote = $0 { return true } else { return false } }.count, 2, "the quote and the callout")
        let todos = parsed.compactMap { block -> [Bool?]? in
            if case .list(let list) = block, list.items.contains(where: { $0.checkbox != nil }) { return list.items.map(\.checkbox) }
            return nil
        }
        XCTAssertEqual(todos, [[true, false]])
    }

    func testGoogleDocsBoldWrapperDoesntMakeEverythingBold() throws {
        // Google Docs wraps the whole selection in <b style="font-weight:normal"> and styles spans.
        let html = """
        <meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1234"><h2 dir="ltr"><span style="font-size:16pt;font-weight:400">Status</span></h2>\
        <p dir="ltr"><span style="font-weight:700">Shipped</span><span style="font-weight:400"> on time, </span><span style="font-style:italic;font-weight:400">mostly</span><span style="font-weight:400">.</span></p>\
        <ul><li dir="ltr" style="list-style-type:disc"><p dir="ltr"><span style="font-weight:400">One</span></p></li><li dir="ltr"><p dir="ltr"><span style="text-decoration:line-through;font-weight:400">Two</span></p></li></ul></b><br class="Apple-interchange-newline">
        """
        let markdown = try XCTUnwrap(RichTextMarkdown.markdown(html: html))
        XCTAssertEqual(markdown, "## Status\n\n**Shipped** on time, *mostly*.\n\n- One\n- ~~Two~~")
    }

    func testAWebPageDropsScriptsAndKeepsText() throws {
        let html = """
        <html><head><title>Title</title><style>p { color: red }</style><script>alert(1)</script></head>
        <body><nav><a href="/home">Home</a></nav><article><h3>Release   notes</h3><p>Fixes &amp; improvements,
        with   extra    spaces<br>and a line break.</p><p>2 * 3 = 6</p></article></body></html>
        """
        let markdown = try XCTUnwrap(RichTextMarkdown.markdown(html: html))
        XCTAssertFalse(markdown.contains("alert"))
        XCTAssertFalse(markdown.contains("color: red"))
        XCTAssertTrue(markdown.contains("### Release notes"), markdown)
        XCTAssertTrue(markdown.contains("Fixes & improvements, with extra spaces\nand a line break."), markdown)
        XCTAssertTrue(markdown.contains("2 \\* 3 = 6"), "a literal asterisk stays literal: \(markdown)")
        XCTAssertTrue(markdown.contains("Home"), "relative links keep their text")
        XCTAssertFalse(markdown.contains("(/home)"))
    }

    func testCodeFromAnEditorStaysCode() throws {
        // VS Code copies colored HTML in one monospaced, preformatted block.
        let html = """
        <meta charset="utf-8"><div style="color: #cccccc;background-color: #1f1f1f;font-family: Menlo, Monaco, 'Courier New', monospace;font-weight: normal;font-size: 12px;line-height: 18px;white-space: pre;"><div><span style="color: #569cd6;">let</span><span style="color: #cccccc;"> x = </span><span style="color: #b5cea8;">1</span></div><div><span style="color: #cccccc;">print(x)</span></div></div>
        """
        let markdown = RichTextMarkdown.markdown(html: html, plainText: "let x = 1\nprint(x)")
        XCTAssertEqual(markdown, "```\nlet x = 1\nprint(x)\n```")
    }

    func testTextThatLooksLikeMarkdownStaysLiteral() throws {
        let markdown = try XCTUnwrap(RichTextMarkdown.markdown(html: "<p># not a heading</p><p>1. not a list</p><p>- not a bullet</p>"))
        XCTAssertEqual(blocks(markdown).count, 3)
        XCTAssertTrue(blocks(markdown).allSatisfy { if case .paragraph = $0 { return true } else { return false } }, markdown)
    }

    func testCheckboxInputsAndEmptyHTML() throws {
        let markdown = try XCTUnwrap(RichTextMarkdown.markdown(html: "<ul><li><input type=\"checkbox\" checked> Done</li><li><input type=\"checkbox\"> Todo</li></ul>"))
        XCTAssertEqual(markdown, "- [x] Done\n- [ ] Todo")
        XCTAssertNil(RichTextMarkdown.markdown(html: "<meta charset='utf-8'><div>  </div>"))
    }

    func testRTFFromAWordProcessor() throws {
        let body = NSFont.systemFont(ofSize: 13)
        let bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        let title = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 26), toHaveTrait: .boldFontMask)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Weekly update\n", attributes: [.font: title]))
        text.append(NSAttributedString(string: "We ", attributes: [.font: body]))
        text.append(NSAttributedString(string: "shipped", attributes: [.font: bold]))
        text.append(NSAttributedString(string: " the ", attributes: [.font: body]))
        text.append(NSAttributedString(string: "beta", attributes: [.font: italic]))
        text.append(NSAttributedString(string: " — read ", attributes: [.font: body]))
        text.append(NSAttributedString(string: "the notes", attributes: [.font: body, .link: URL(string: "https://example.com/notes")!]))
        text.append(NSAttributedString(string: ".\n", attributes: [.font: body]))
        let list = NSTextList(markerFormat: .disc, options: 0)
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        for item in ["First", "Second"] {
            text.append(NSAttributedString(string: "\t•\t\(item)\n", attributes: [.font: body, .paragraphStyle: style]))
        }
        let rtf = try XCTUnwrap(text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let parsed = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        let markdown = RichTextMarkdown.markdown(attributed: parsed)
        XCTAssertTrue(markdown.hasPrefix("# Weekly update\n\n"), markdown)
        XCTAssertTrue(markdown.contains("We **shipped** the *beta* — read [the notes](https://example.com/notes)."), markdown)
        XCTAssertTrue(markdown.hasSuffix("- First\n- Second"), markdown)
    }

    func testThePasteboardPrefersFormattedText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tandem.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Plan\nAsk about the timeline", forType: .string)
        pasteboard.setString("<h1>Plan</h1><p>Ask about <b>the timeline</b></p>", forType: .html)
        XCTAssertEqual(RichTextMarkdown.markdown(from: pasteboard), "# Plan\n\nAsk about **the timeline**")
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        XCTAssertEqual(RichTextMarkdown.markdown(from: pasteboard), "just text")
    }
}
