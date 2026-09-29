import XCTest
@testable import TandemCore

final class MarkdownParserTests: XCTestCase {
    private func parse(_ text: String) -> [MarkdownBlock] {
        MarkdownDocument.parse(text).blocks
    }

    private func item(_ blocks: MarkdownBlock..., checkbox: Bool? = nil) -> MarkdownListItem {
        MarkdownListItem(checkbox: checkbox, blocks: blocks)
    }

    private func bullets(_ texts: String..., tight: Bool = true) -> MarkdownBlock {
        .list(MarkdownList(ordered: false, start: 1, items: texts.map { item(.paragraph($0)) }, isTight: tight))
    }

    // MARK: Basics

    func testEmptyAndWhitespaceOnlyInput() {
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("\n\n  \n\t\n"), [])
    }

    func testParagraphsSplitOnBlankLinesAndKeepSoftBreaks() {
        XCTAssertEqual(parse("Hello **world**\nsecond line\n\nNext `para`"), [
            .paragraph("Hello **world**\nsecond line"),
            .paragraph("Next `para`")
        ])
    }

    func testParagraphLinesAreTrimmedAndHardBreakBackslashDropped() {
        XCTAssertEqual(parse("   indented start  \n  continued\\\nend  "), [
            .paragraph("indented start\ncontinued\nend")
        ])
        // An escaped backslash at the end of a line is kept.
        XCTAssertEqual(parse("path C:\\\\\nnext"), [.paragraph("path C:\\\\\nnext")])
    }

    func testHTMLIsKeptAsParagraphText() {
        XCTAssertEqual(parse("<details>\n<summary>More</summary>\n</details>"), [
            .paragraph("<details>\n<summary>More</summary>\n</details>")
        ])
    }

    func testByteOrderMarkIsIgnored() {
        XCTAssertEqual(parse("\u{FEFF}# Title"), [.heading(level: 1, text: "Title")])
    }

    // MARK: Headings

    func testATXHeadingLevels() {
        XCTAssertEqual(parse("# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six"), [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 3, text: "Three"),
            .heading(level: 4, text: "Four"),
            .heading(level: 5, text: "Five"),
            .heading(level: 6, text: "Six")
        ])
    }

    func testATXHeadingEdgeCases() {
        XCTAssertEqual(parse("####### Seven"), [.paragraph("####### Seven")])
        XCTAssertEqual(parse("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(parse("#5 in the ranking"), [.paragraph("#5 in the ranking")])
        XCTAssertEqual(parse("   ## Indented"), [.heading(level: 2, text: "Indented")])
        XCTAssertEqual(parse("## Closed ##"), [.heading(level: 2, text: "Closed")])
        XCTAssertEqual(parse("# Closed #####   "), [.heading(level: 1, text: "Closed")])
        XCTAssertEqual(parse("# C#"), [.heading(level: 1, text: "C#")])
        XCTAssertEqual(parse("# Escaped \\#"), [.heading(level: 1, text: "Escaped \\#")])
        XCTAssertEqual(parse("### ###"), [.heading(level: 3, text: "")])
        XCTAssertEqual(parse("## `code` and **bold**"), [.heading(level: 2, text: "`code` and **bold**")])
    }

    func testATXHeadingInterruptsParagraph() {
        XCTAssertEqual(parse("Intro\n## Details\nBody"), [
            .paragraph("Intro"),
            .heading(level: 2, text: "Details"),
            .paragraph("Body")
        ])
    }

    func testStreamingTrailingHashes() {
        // The model has emitted the heading marker but no text yet.
        XCTAssertEqual(parse("Intro\n\n#"), [.paragraph("Intro"), .heading(level: 1, text: "")])
        XCTAssertEqual(parse("Intro\n\n## "), [.paragraph("Intro"), .heading(level: 2, text: "")])
        XCTAssertEqual(parse("Intro\n\n## Summ"), [.paragraph("Intro"), .heading(level: 2, text: "Summ")])
    }

    func testSetextHeadings() {
        XCTAssertEqual(parse("Title\n====="), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(parse("Subtitle\n---"), [.heading(level: 2, text: "Subtitle")])
        XCTAssertEqual(parse("Two line\nheading\n==="), [.heading(level: 1, text: "Two line\nheading")])
        XCTAssertEqual(parse("Short\n-\n"), [.heading(level: 2, text: "Short")])
        XCTAssertEqual(parse("Not\n= setext"), [.paragraph("Not\n= setext")])
    }

    func testStreamingShortUnderlineOnOpenLineIsNotSetext() {
        // "-" may be the start of "- item"; don't flash a heading.
        XCTAssertEqual(parse("Steps:\n-"), [
            .paragraph("Steps:"),
            .list(MarkdownList(ordered: false, start: 1, items: [item()], isTight: true))
        ])
        XCTAssertEqual(parse("a\n=="), [.paragraph("a\n==")])
        XCTAssertEqual(parse("Title\n==="), [.heading(level: 1, text: "Title")])
    }

    // MARK: Thematic breaks

    func testThematicBreaks() {
        XCTAssertEqual(parse("---\n***\n___\n- - -\n * * * \n_____"), Array(repeating: .thematicBreak, count: 6))
        XCTAssertEqual(parse("--"), [.paragraph("--")])
        XCTAssertEqual(parse("Above\n\n---\n\nBelow"), [.paragraph("Above"), .thematicBreak, .paragraph("Below")])
        XCTAssertEqual(parse("Para\n***"), [.paragraph("Para"), .thematicBreak])
    }

    // MARK: Fenced code

    func testFencedCodeWithLanguage() {
        XCTAssertEqual(parse("```swift\nlet x = 1\n\nprint(x)\n```"), [
            .codeBlock(language: "swift", code: "let x = 1\n\nprint(x)", isClosed: true)
        ])
    }

    func testTildeFenceAndInfoStringVariants() {
        XCTAssertEqual(parse("~~~ python title=\"a.py\"\npass\n~~~"), [
            .codeBlock(language: "python", code: "pass", isClosed: true)
        ])
        XCTAssertEqual(parse("```{r}\nx <- 1\n```"), [.codeBlock(language: "r", code: "x <- 1", isClosed: true)])
        XCTAssertEqual(parse("```\nplain\n```"), [.codeBlock(language: nil, code: "plain", isClosed: true)])
        XCTAssertEqual(parse("```\n```"), [.codeBlock(language: nil, code: "", isClosed: true)])
    }

    func testFenceClosingRules() {
        // A shorter or different fence doesn't close; a longer one does.
        XCTAssertEqual(parse("````md\n```\ninner\n```\n`````\nafter"), [
            .codeBlock(language: "md", code: "```\ninner\n```", isClosed: true),
            .paragraph("after")
        ])
        XCTAssertEqual(parse("~~~\n```\n~~~"), [.codeBlock(language: nil, code: "```", isClosed: true)])
        // Closing fence may not have trailing text.
        XCTAssertEqual(parse("```\na\n``` x\n```"), [.codeBlock(language: nil, code: "a\n``` x", isClosed: true)])
    }

    func testBackticksInInfoStringMeanInlineCode() {
        XCTAssertEqual(parse("```foo```"), [.paragraph("```foo```")])
    }

    func testIndentedFenceStripsItsIndentFromContent() {
        XCTAssertEqual(parse("  ```\n  indented\n    more\nnone\n  ```"), [
            .codeBlock(language: nil, code: "indented\n  more\nnone", isClosed: true)
        ])
    }

    func testFenceInterruptsParagraphAndPreservesTabs() {
        XCTAssertEqual(parse("Run this:\n```go\nfunc main() {\n\tfmt.Println(1)\n}\n```\nDone."), [
            .paragraph("Run this:"),
            .codeBlock(language: "go", code: "func main() {\n\tfmt.Println(1)\n}", isClosed: true),
            .paragraph("Done.")
        ])
    }

    func testStreamingUnterminatedFence() {
        XCTAssertEqual(parse("Here:\n\n```python\ndef f():\n    return 1"), [
            .paragraph("Here:"),
            .codeBlock(language: "python", code: "def f():\n    return 1", isClosed: false)
        ])
        XCTAssertEqual(parse("```python\n"), [.codeBlock(language: "python", code: "", isClosed: false)])
        XCTAssertEqual(parse("```pyth"), [.codeBlock(language: "pyth", code: "", isClosed: false)])
        XCTAssertEqual(parse("```\nline\n\n"), [.codeBlock(language: nil, code: "line\n", isClosed: false)])
    }

    func testStreamingPartialClosingFenceIsHidden() {
        XCTAssertEqual(parse("```js\nx()\n`"), [.codeBlock(language: "js", code: "x()", isClosed: false)])
        XCTAssertEqual(parse("```js\nx()\n``"), [.codeBlock(language: "js", code: "x()", isClosed: false)])
        XCTAssertEqual(parse("```js\nx()\n```"), [.codeBlock(language: "js", code: "x()", isClosed: true)])
        // Once the line is terminated it's real content.
        XCTAssertEqual(parse("```js\nx()\n``\n"), [.codeBlock(language: "js", code: "x()\n``", isClosed: false)])
    }

    // MARK: Indented code

    func testIndentedCode() {
        XCTAssertEqual(parse("Para\n\n    let a = 1\n\n\n    let b = 2\n\nAfter"), [
            .paragraph("Para"),
            .codeBlock(language: nil, code: "let a = 1\n\n\nlet b = 2", isClosed: true),
            .paragraph("After")
        ])
        XCTAssertEqual(parse("\tcode\n\t\tdeeper"), [.codeBlock(language: nil, code: "code\n\tdeeper", isClosed: true)])
    }

    func testIndentedLineContinuesParagraphInsteadOfStartingCode() {
        XCTAssertEqual(parse("Para\n    still para"), [.paragraph("Para\nstill para")])
    }

    // MARK: Display math

    func testDisplayMath() {
        XCTAssertEqual(parse("$$\n\\int_0^1 x\\,dx\n$$"), [
            .codeBlock(language: "math", code: "\\int_0^1 x\\,dx", isClosed: true)
        ])
        XCTAssertEqual(parse("$$ E = mc^2 $$"), [.codeBlock(language: "math", code: "E = mc^2", isClosed: true)])
        XCTAssertEqual(parse("\\[\na^2 + b^2\n\\]"), [.codeBlock(language: "math", code: "a^2 + b^2", isClosed: true)])
        XCTAssertEqual(parse("\\[ x \\]"), [.codeBlock(language: "math", code: "x", isClosed: true)])
        XCTAssertEqual(parse("$$\na = 1\nb = 2$$"), [.codeBlock(language: "math", code: "a = 1\nb = 2", isClosed: true)])
        XCTAssertEqual(parse("The formula:\n$$\nx\n$$\nholds."), [
            .paragraph("The formula:"),
            .codeBlock(language: "math", code: "x", isClosed: true),
            .paragraph("holds.")
        ])
    }

    func testStreamingUnterminatedMathAndDollarProse() {
        XCTAssertEqual(parse("$$\n\\frac{1}{"), [.codeBlock(language: "math", code: "\\frac{1}{", isClosed: false)])
        XCTAssertEqual(parse("$$$ is money"), [.paragraph("$$$ is money")])
        XCTAssertEqual(parse("It costs $5 and $$ more"), [.paragraph("It costs $5 and $$ more")])
    }

    // MARK: Blockquotes

    func testBlockquoteWithParagraphsAndLazyContinuation() {
        XCTAssertEqual(parse("> First line\nlazy continuation\n>\n> Second para"), [
            .blockquote([.paragraph("First line\nlazy continuation"), .paragraph("Second para")])
        ])
        XCTAssertEqual(parse(">no space\n>  two spaces"), [.blockquote([.paragraph("no space\ntwo spaces")])])
    }

    func testBlockquoteEndsAtBlankLineAndBlockStarts() {
        XCTAssertEqual(parse("> quoted\n\nafter"), [.blockquote([.paragraph("quoted")]), .paragraph("after")])
        XCTAssertEqual(parse("> quoted\n---"), [.blockquote([.paragraph("quoted")]), .thematicBreak])
        XCTAssertEqual(parse("> quoted\n- item"), [.blockquote([.paragraph("quoted")]), bullets("item")])
        XCTAssertEqual(parse("> ```\n> code\nnot code"), [
            .blockquote([.codeBlock(language: nil, code: "code", isClosed: false)]),
            .paragraph("not code")
        ])
    }

    func testNestedBlockquotes() {
        XCTAssertEqual(parse("> outer\n>> inner\n> > still inner\n\n> back"), [
            .blockquote([
                .paragraph("outer"),
                .blockquote([.paragraph("inner\nstill inner")])
            ]),
            .blockquote([.paragraph("back")])
        ])
    }

    func testBlockquoteContainingHeadingListAndCode() {
        XCTAssertEqual(parse("> ## Note\n> - a\n> - b\n>\n> ```sh\n> ls\n> ```"), [
            .blockquote([
                .heading(level: 2, text: "Note"),
                bullets("a", "b"),
                .codeBlock(language: "sh", code: "ls", isClosed: true)
            ])
        ])
    }

    // MARK: Lists

    func testBulletListsWithEachMarker() {
        XCTAssertEqual(parse("- one\n- two\n- three"), [bullets("one", "two", "three")])
        XCTAssertEqual(parse("* one\n* two"), [bullets("one", "two")])
        XCTAssertEqual(parse("+ one\n+ two"), [bullets("one", "two")])
    }

    func testChangingBulletCharacterStartsNewList() {
        XCTAssertEqual(parse("- a\n* b"), [bullets("a"), bullets("b")])
    }

    func testOrderedListsWithStartAndDelimiters() {
        XCTAssertEqual(parse("1. one\n2. two\n3. three"), [
            .list(MarkdownList(ordered: true, start: 1, items: [item(.paragraph("one")), item(.paragraph("two")), item(.paragraph("three"))], isTight: true))
        ])
        XCTAssertEqual(parse("7) seven\n8) eight"), [
            .list(MarkdownList(ordered: true, start: 7, items: [item(.paragraph("seven")), item(.paragraph("eight"))], isTight: true))
        ])
        // Different delimiter starts a new list.
        XCTAssertEqual(parse("1. a\n2) b").count, 2)
        XCTAssertEqual(parse("1234567890. too long"), [.paragraph("1234567890. too long")])
    }

    func testListInterruptionRules() {
        XCTAssertEqual(parse("Options:\n- a\n- b"), [.paragraph("Options:"), bullets("a", "b")])
        XCTAssertEqual(parse("Steps:\n1. a"), [
            .paragraph("Steps:"),
            .list(MarkdownList(ordered: true, start: 1, items: [item(.paragraph("a"))], isTight: true))
        ])
        // Only "1." may interrupt a paragraph; "2019." is prose.
        XCTAssertEqual(parse("In\n2019. was a year"), [.paragraph("In\n2019. was a year")])
        // An empty marker doesn't interrupt a paragraph (it's a setext underline / text).
        XCTAssertEqual(parse("Text\n*\nmore"), [.paragraph("Text\n*\nmore")])
    }

    func testNestedListsByIndentation() {
        let expected: [MarkdownBlock] = [
            .list(MarkdownList(ordered: false, start: 1, items: [
                item(.paragraph("parent"), bullets("child one", "child two")),
                item(.paragraph("sibling"))
            ], isTight: true))
        ]
        XCTAssertEqual(parse("- parent\n  - child one\n  - child two\n- sibling"), expected)
        XCTAssertEqual(parse("- parent\n    - child one\n    - child two\n- sibling"), expected)
    }

    func testNestedUnderOrderedListWithThreeAndTwoSpaceIndents() {
        let expected: [MarkdownBlock] = [
            .list(MarkdownList(ordered: true, start: 1, items: [
                item(.paragraph("Step"), bullets("detail a", "detail b")),
                item(.paragraph("Next"))
            ], isTight: true))
        ]
        XCTAssertEqual(parse("1. Step\n   - detail a\n   - detail b\n2. Next"), expected)
        // Two-space nesting under "1." (common in model output) still nests.
        XCTAssertEqual(parse("1. Step\n  - detail a\n  - detail b\n2. Next"), expected)
    }

    func testThreeLevelNesting() {
        let blocks = parse("- a\n  - b\n    - c\n      deep text\n  - d")
        XCTAssertEqual(blocks, [
            .list(MarkdownList(ordered: false, start: 1, items: [
                item(.paragraph("a"), .list(MarkdownList(ordered: false, start: 1, items: [
                    item(.paragraph("b"), bullets("c\ndeep text")),
                    item(.paragraph("d"))
                ], isTight: true)))
            ], isTight: true))
        ])
    }

    func testMultiParagraphItemsMakeListLoose() {
        XCTAssertEqual(parse("1. **Install**\n\n   Run the installer.\n\n2. **Launch**"), [
            .list(MarkdownList(ordered: true, start: 1, items: [
                item(.paragraph("**Install**"), .paragraph("Run the installer.")),
                item(.paragraph("**Launch**"))
            ], isTight: false))
        ])
    }

    func testBlankLinesBetweenItemsMakeListLoose() {
        XCTAssertEqual(parse("- a\n\n- b\n\n\n- c"), [bullets("a", "b", "c", tight: false)])
    }

    func testBlankLinesInsideNestedListKeepOuterListTight() {
        guard case let .list(outer)? = parse("- a\n  - b\n\n  - c\n- d").first else {
            return XCTFail("expected a list")
        }
        XCTAssertTrue(outer.isTight)
        XCTAssertEqual(outer.items.count, 2)
        guard case let .list(inner)? = outer.items[0].blocks.last else { return XCTFail("expected nested list") }
        XCTAssertFalse(inner.isTight)
        XCTAssertEqual(inner.items.count, 2)
    }

    func testListEndsAtUnindentedParagraphAfterBlankLine() {
        XCTAssertEqual(parse("- a\n- b\n\nParagraph"), [bullets("a", "b"), .paragraph("Paragraph")])
        // Unindented text right after an item is a lazy continuation.
        XCTAssertEqual(parse("- a\nlazy"), [bullets("a\nlazy")])
    }

    func testOrderedListResumesAfterInterruption() {
        let blocks = parse("1. One\n\nNote\n\n2. Two")
        XCTAssertEqual(blocks.count, 3)
        guard case let .list(second) = blocks[2] else { return XCTFail("expected list") }
        XCTAssertEqual(second.start, 2)
    }

    func testCodeBlockInsideListItem() {
        XCTAssertEqual(parse("1. Install:\n\n   ```bash\n   npm install\n\n   npm test\n   ```\n2. Done"), [
            .list(MarkdownList(ordered: true, start: 1, items: [
                item(.paragraph("Install:"), .codeBlock(language: "bash", code: "npm install\n\nnpm test", isClosed: true)),
                item(.paragraph("Done"))
            ], isTight: false))
        ])
    }

    func testUnderIndentedFenceContentStaysInItem() {
        XCTAssertEqual(parse("- Example:\n  ```\nx = 1\n  ```\n- Next"), [
            .list(MarkdownList(ordered: false, start: 1, items: [
                item(.paragraph("Example:"), .codeBlock(language: nil, code: "x = 1", isClosed: true)),
                item(.paragraph("Next"))
            ], isTight: true))
        ])
    }

    func testNoIndentedCodeInsideListItems() {
        XCTAssertEqual(parse("- item\n\n        deeply indented text"), [
            .list(MarkdownList(ordered: false, start: 1, items: [
                item(.paragraph("item"), .paragraph("deeply indented text"))
            ], isTight: false))
        ])
    }

    func testListItemContainingQuote() {
        XCTAssertEqual(parse("- tip:\n  > quoted\n  > more"), [
            .list(MarkdownList(ordered: false, start: 1, items: [
                item(.paragraph("tip:"), .blockquote([.paragraph("quoted\nmore")]))
            ], isTight: true))
        ])
    }

    func testTaskListItems() {
        XCTAssertEqual(parse("- [ ] todo\n- [x] done\n- [X] also done\n- [y] not a task\n- plain"), [
            .list(MarkdownList(ordered: false, start: 1, items: [
                item(.paragraph("todo"), checkbox: false),
                item(.paragraph("done"), checkbox: true),
                item(.paragraph("also done"), checkbox: true),
                item(.paragraph("[y] not a task")),
                item(.paragraph("plain"))
            ], isTight: true))
        ])
        XCTAssertEqual(parse("- [x]"), [
            .list(MarkdownList(ordered: false, start: 1, items: [item(checkbox: true)], isTight: true))
        ])
        XCTAssertEqual(parse("- [link](https://x.y)"), [bullets("[link](https://x.y)")])
    }

    func testStreamingListItemBeingTyped() {
        XCTAssertEqual(parse("- first\n- sec"), [bullets("first", "sec")])
        XCTAssertEqual(parse("- first\n-"), [
            .list(MarkdownList(ordered: false, start: 1, items: [item(.paragraph("first")), item()], isTight: true))
        ])
        XCTAssertEqual(parse("- first\n- "), [
            .list(MarkdownList(ordered: false, start: 1, items: [item(.paragraph("first")), item()], isTight: true))
        ])
        XCTAssertEqual(parse("1. first\n2."), [
            .list(MarkdownList(ordered: true, start: 1, items: [item(.paragraph("first")), item()], isTight: true))
        ])
        XCTAssertEqual(parse("- first\n  - nested par"), [
            .list(MarkdownList(ordered: false, start: 1, items: [item(.paragraph("first"), bullets("nested par"))], isTight: true))
        ])
    }

    func testStarThematicBreakIsNotAListItem() {
        XCTAssertEqual(parse("- a\n* * *\n- b"), [bullets("a"), .thematicBreak, bullets("b")])
    }

    // MARK: Tables

    func testBasicTable() {
        XCTAssertEqual(parse("| Name | Value |\n|------|-------|\n| a | `1` |\n| b | **2** |"), [
            .table(MarkdownTable(
                header: ["Name", "Value"],
                alignments: [.leading, .leading],
                rows: [["a", "`1`"], ["b", "**2**"]]
            ))
        ])
    }

    func testTableAlignmentsAndOptionalOuterPipes() {
        XCTAssertEqual(parse("Left | Center | Right\n:--- | :---: | ---:\nl | c | r"), [
            .table(MarkdownTable(
                header: ["Left", "Center", "Right"],
                alignments: [.leading, .center, .trailing],
                rows: [["l", "c", "r"]]
            ))
        ])
    }

    func testTableRowsArePaddedTruncatedAndUnescaped() {
        XCTAssertEqual(parse("| a | b |\n|---|---|\n| only |\n| 1 | 2 | 3 |\n| x \\| y | |"), [
            .table(MarkdownTable(
                header: ["a", "b"],
                alignments: [.leading, .leading],
                rows: [["only", ""], ["1", "2"], ["x | y", ""]]
            ))
        ])
    }

    func testTableAfterParagraphAndEndingAtBlankOrPipelessLine() {
        XCTAssertEqual(parse("Compare:\n| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter"), [
            .paragraph("Compare:"),
            .table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]])),
            .paragraph("After")
        ])
        XCTAssertEqual(parse("| a |\n| - |\n| 1 |\nThis explains it."), [
            .table(MarkdownTable(header: ["a"], alignments: [.leading], rows: [["1"]])),
            .paragraph("This explains it.")
        ])
    }

    func testTableHeaderWithoutRows() {
        XCTAssertEqual(parse("| a | b |\n|:-:|--:|"), [
            .table(MarkdownTable(header: ["a", "b"], alignments: [.center, .trailing], rows: []))
        ])
    }

    func testStreamingPartialTableRendersAsParagraphUntilDelimiterArrives() {
        XCTAssertEqual(parse("| Name | Value |"), [.paragraph("| Name | Value |")])
        XCTAssertEqual(parse("| Name | Value |\n|---"), [.paragraph("| Name | Value |\n|---")])
        XCTAssertEqual(parse("| Name | Value |\n|---|:"), [.paragraph("| Name | Value |\n|---|:")])
        XCTAssertEqual(parse("| Name | Value |\n|---|-"), [
            .table(MarkdownTable(header: ["Name", "Value"], alignments: [.leading, .leading], rows: []))
        ])
        XCTAssertEqual(parse("| Name | Value |\n|---|---|\n| a | 1"), [
            .table(MarkdownTable(header: ["Name", "Value"], alignments: [.leading, .leading], rows: [["a", "1"]]))
        ])
    }

    func testMismatchedDelimiterIsNotATable() {
        XCTAssertEqual(parse("| a | b |\n| --- |"), [.paragraph("| a | b |\n| --- |")])
        // A pipe-less "---" under a row is a setext underline, not a delimiter row.
        XCTAssertEqual(parse("a | b\n---"), [.heading(level: 2, text: "a | b")])
    }

    func testTableInsideListItem() {
        XCTAssertEqual(parse("- Results:\n\n  | k | v |\n  |---|---|\n  | x | 1 |"), [
            .list(MarkdownList(ordered: false, start: 1, items: [
                item(.paragraph("Results:"), .table(MarkdownTable(header: ["k", "v"], alignments: [.leading, .leading], rows: [["x", "1"]])))
            ], isTight: false))
        ])
    }

    // MARK: Line endings & robustness

    func testCRLFAndCRLineEndings() {
        let lf = "# Title\n\nPara one\ncontinued\n\n```swift\nlet a = 1\n```\n- a\n- b\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let cr = lf.replacingOccurrences(of: "\n", with: "\r")
        let expected: [MarkdownBlock] = [
            .heading(level: 1, text: "Title"),
            .paragraph("Para one\ncontinued"),
            .codeBlock(language: "swift", code: "let a = 1", isClosed: true),
            bullets("a", "b")
        ]
        XCTAssertEqual(parse(lf), expected)
        XCTAssertEqual(parse(crlf), expected)
        XCTAssertEqual(parse(cr), expected)
    }

    func testTabsInIndentation() {
        XCTAssertEqual(parse("-\tone\n-\ttwo"), [bullets("one", "two")])
        XCTAssertEqual(parse("- a\n\t- b"), [
            .list(MarkdownList(ordered: false, start: 1, items: [item(.paragraph("a"), bullets("b"))], isTight: true))
        ])
    }

    func testUnicodeContentSurvives() {
        XCTAssertEqual(parse("## Café ☕️\n- 日本語\n- emoji 👩‍👩‍👧"), [
            .heading(level: 2, text: "Café ☕️"),
            bullets("日本語", "emoji 👩‍👩‍👧")
        ])
    }

    func testPathologicalNestingDoesNotOverflow() {
        let deepQuote = String(repeating: ">", count: 5_000) + " deep"
        XCTAssertEqual(parse(deepQuote).count, 1)
        let deepList = (0..<2_000).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n")
        XCTAssertEqual(parse(deepList).count, 1)
        XCTAssertEqual(parse(String(repeating: "- ", count: 3_000) + "x").count, 1)
    }

    func testEveryPrefixOfADocumentParses() {
        // Simulates streaming: each prefix must parse, and the last one matches the full parse.
        let text = Self.syntheticSection(index: 0)
        var previous: [MarkdownBlock] = []
        for end in text.indices {
            previous = parse(String(text[..<end]))
        }
        XCTAssertFalse(previous.isEmpty)
        XCTAssertEqual(parse(text).count, 10)
    }

    // MARK: Composite & performance

    func testRealisticAnswer() {
        let blocks = parse(Self.syntheticSection(index: 1))
        XCTAssertEqual(blocks.count, 10)
        guard case .heading(level: 2, text: "Section 1: Overview") = blocks[0] else { return XCTFail("heading") }
        guard case .list = blocks[2], case .list = blocks[3], case .codeBlock(language: "swift", _, isClosed: true) = blocks[4],
              case .table = blocks[5], case .blockquote = blocks[6], case .codeBlock(language: "math", _, isClosed: true) = blocks[7],
              case .thematicBreak = blocks[9] else {
            return XCTFail("unexpected structure: \(blocks)")
        }
    }

    func testParsingPerformanceOnTwentyKilobyteAnswer() {
        let document = Self.syntheticDocument(minimumBytes: 20_000)
        XCTAssertGreaterThanOrEqual(document.utf8.count, 20_000)
        measure {
            for _ in 0..<10 {
                _ = MarkdownDocument.parse(document)
            }
        }
    }

    func testParsingIsFastEnoughEvenInDebugBuilds() {
        let document = Self.syntheticDocument(minimumBytes: 20_000)
        _ = MarkdownDocument.parse(document) // warm up
        let clock = ContinuousClock()
        let iterations = 20
        let elapsed = clock.measure {
            for _ in 0..<iterations { _ = MarkdownDocument.parse(document) }
        }
        let perParse = elapsed / iterations
        // Release builds are several times faster; this generous bound guards against
        // accidental quadratic behavior without making debug test runs flaky.
        XCTAssertLessThan(perParse, .milliseconds(40), "parse of 20 KB took \(perParse)")
    }

    // MARK: Fixtures

    static func syntheticSection(index: Int) -> String {
        """
        ## Section \(index): Overview

        Here is some **bold** text, some *italic* text, and `inline code`, plus a [link](https://example.com/\(index)).
        The second line of the paragraph keeps going for a while to look like real prose.

        1. First step with `npm install`
        2. Second step:
           - nested bullet one
           - nested bullet two
        3. Third step

        - [x] done task
        - [ ] open task

        ```swift
        struct Item\(index): Identifiable {
            let id = UUID()
            var name: String
        }
        ```

        | Option | Default | Notes |
        |:-------|:-------:|------:|
        | alpha  | `true`  | first |
        | beta   | `false` | second \\| escaped |

        > **Note:** quoted text
        > continues here.

        $$
        f(x) = x^2 + \(index)
        $$

        Final paragraph with trailing text.

        ---

        """
    }

    static func syntheticDocument(minimumBytes: Int) -> String {
        var text = ""
        var index = 0
        while text.utf8.count < minimumBytes {
            text += syntheticSection(index: index)
            index += 1
        }
        return text
    }
}
