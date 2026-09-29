import AppKit
import SwiftUI
import XCTest
import TandemCore
@testable import TandemUI

final class MarkdownViewTests: XCTestCase {
    private static let sample = """
    # Heading one
    ## Heading two with `code`
    #### Small heading

    A paragraph with **bold**, *italic*, ~~struck~~, `inline code`, a [link](https://example.com),
    and a bare URL https://tandem.app/docs on a second line.

    1. First
    2. Second
       - nested bullet
         - deeper bullet
    3. Third

    - [x] Done
    - [ ] Todo

    > A quote with a list:
    > - inside
    >
    > > and a nested quote

    ```swift
    let greeting = "Hello, world! This line is long enough that it will need to scroll horizontally in a narrow bubble."
    print(greeting)
    ```

    | Column | Centered | Right |
    |:-------|:--------:|------:|
    | a | b | c |
    | a much longer cell that should wrap instead of stretching the whole table very wide | <br>line | 42 |

    $$
    e^{i\\pi} + 1 = 0
    $$

    ---

    Final paragraph.
    """

    @MainActor
    private func layOut<V: View>(_ view: V, width: CGFloat) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func render<V: View>(_ host: NSHostingView<V>) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("could not create bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
    }

    @MainActor
    func testStandardStyleLaysOutAndDrawsEveryBlockKind() {
        let host = layOut(MarkdownView(Self.sample), width: 520)
        XCTAssertGreaterThan(host.fittingSize.height, 400)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 521)
        render(host)
    }

    @MainActor
    func testCompactStyleIsShorterThanStandard() {
        let standard = layOut(MarkdownView(Self.sample, style: .standard), width: 360).fittingSize.height
        let compact = layOut(MarkdownView(Self.sample, style: .compact), width: 360).fittingSize.height
        XCTAssertGreaterThan(compact, 0)
        XCTAssertLessThan(compact, standard)
    }

    @MainActor
    func testStreamingPrefixesLayOut() {
        // Re-hosting successive prefixes mimics token-by-token streaming, including an open fence.
        let text = Self.sample
        let host = NSHostingView(rootView: MarkdownView("").frame(width: 420))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        var offset = 0
        var index = text.startIndex
        while index < text.endIndex {
            host.rootView = MarkdownView(String(text[..<index])).frame(width: 420)
            host.layoutSubtreeIfNeeded()
            offset += 37
            index = text.index(text.startIndex, offsetBy: min(offset, text.count))
        }
        host.rootView = MarkdownView(text).frame(width: 420)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 400)
    }

    @MainActor
    func testEmptyDocumentAndDocumentInit() {
        XCTAssertLessThan(layOut(MarkdownView(""), width: 300).fittingSize.height, 1)
        let document = MarkdownDocument.parse("Hello")
        XCTAssertGreaterThan(layOut(MarkdownView(document: document), width: 300).fittingSize.height, 10)
    }

    // MARK: Inline rendering

    func testInlineCodeAndLinksAreStyled() {
        let codeFont = TandemFont.mono
        let rendered = InlineMarkdown.render("Use `swift build` or see [docs](https://swift.org) and https://example.com/x.", codeFont: codeFont)
        XCTAssertEqual(String(rendered.characters), "Use swift build or see docs and https://example.com/x.")

        let runs = Array(rendered.runs)
        let code = runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code.map { String(rendered[$0.range].characters) }, "swift build")
        XCTAssertEqual(code?.font, codeFont)
        XCTAssertEqual(code?.foregroundColor, Theme.accent)

        let links = runs.filter { $0.link != nil }
        XCTAssertEqual(links.map(\.link), [URL(string: "https://swift.org"), URL(string: "https://example.com/x")])
        XCTAssertTrue(links.allSatisfy { $0.foregroundColor == Theme.accent })
    }

    func testBareURLInsideCodeSpanIsNotLinkified() {
        let rendered = InlineMarkdown.render("`curl https://example.com`", codeFont: TandemFont.mono)
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
    }

    func testPlainTextAndUnclosedMarkupPassThrough() {
        XCTAssertEqual(String(InlineMarkdown.render("Just words, nothing else", codeFont: TandemFont.mono).characters), "Just words, nothing else")
        // Half-streamed emphasis stays literal instead of failing.
        XCTAssertEqual(String(InlineMarkdown.render("A **partial", codeFont: TandemFont.mono).characters), "A **partial")
        // Soft line breaks are preserved.
        XCTAssertEqual(String(InlineMarkdown.render("one\n*two*", codeFont: TandemFont.mono).characters), "one\ntwo")
    }

    func testInlineConversionIsMemoized() {
        let source = "Memo **test** \(UUID().uuidString)"
        let first = InlineMarkdown.attributedString(for: source, codeFont: TandemFont.mono)
        let second = InlineMarkdown.attributedString(for: source, codeFont: TandemFont.mono)
        XCTAssertEqual(first, second)
    }

    func testTableLineBreakTags() {
        XCTAssertEqual(MarkdownTableView.replacingLineBreakTags("a<br>b<BR/>c<br />d"), "a\nb\nc\nd")
        XCTAssertEqual(MarkdownTableView.replacingLineBreakTags("no tags"), "no tags")
    }
}
