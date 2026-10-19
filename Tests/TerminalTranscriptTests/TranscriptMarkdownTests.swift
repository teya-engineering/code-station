import CodeStationCore
import Foundation
import Testing
import TerminalTranscript

// Markdown in a reply, checked as a reader sees it: the exact text of each line and the
// style of each run on it. The theme decides what a style looks like, so these hold at
// every colour depth.
struct TranscriptMarkdownTests {

    @Test func aHeadingDropsItsHashesAndTakesTheHeadingStyle() {
        let lines = render(answer("# Plan\n\nFirst step\n\n### Notes ###"), width: 30)

        #expect(lines.map(\.text) == ["Plan", "", "First step", "", "Notes"])
        #expect(lines.map(styles) == [[.heading(1)], [], [.plain], [], [.heading(3)]])
    }

    @Test func emphasisStrongAndInlineCodeAreStyledWithoutTheirMarkers() {
        let lines = render(answer("Use *care*, **force** and `swift build` ***now***"), width: 60)

        #expect(lines.map(\.text) == ["Use care, force and swift build now"])
        #expect(lines[0].spans == [
            Span("Use "), Span("care", .emphasis), Span(", "), Span("force", .strong),
            Span(" and "), Span("swift build", .code), Span(" "), Span("now", .strongEmphasis),
        ])
    }

    // An underscore inside a word is part of the word, a lone star is just a star, and an
    // escaped marker is the marker itself.
    @Test func markersThatOpenNothingStayAsTheyAre() {
        let lines = render(answer(#"snake_case_name, 2 * 3 * 4, \*not\* and `open"#), width: 60)

        #expect(lines.map(\.text) == ["snake_case_name, 2 * 3 * 4, *not* and `open"])
        #expect(lines.map(styles) == [[.plain]])
    }

    @Test func styledTextWrapsAtWordsAndKeepsItsStyleAcrossTheBreak() {
        let lines = render(answer("Run **the whole suite** now"), width: 12)

        #expect(lines.map(\.text) == ["Run the", "whole suite", "now"])
        #expect(lines[0].spans == [Span("Run "), Span("the", .strong)])
        #expect(lines[1].spans == [Span("whole suite", .strong)])
        #expect(lines[2].spans == [Span("now")])
    }

    // MARK: - Blocks

    @Test func listItemsHangUnderTheirMarkersAndNestByIndent() {
        let text = "Steps:\n- first item here\n- second\n  - nested one\n1. numbered\n- [x] done"

        let lines = render(answer(text), width: 16)

        #expect(lines.map(\.text) == [
            "Steps:", "",
            "• first item", "  here", "• second", "  ◦ nested one", "1. numbered", "☑ done",
        ])
        #expect(lines[2].spans == [Span("•", .listMarker), Span(" first item")])
        #expect(lines[3].spans == [Span("  here")])
        #expect(lines[5].spans == [Span("  "), Span("◦", .listMarker), Span(" nested one")])
    }

    @Test func aQuoteSitsBehindARuleAndARuleCrossesTheWidth() {
        let lines = render(answer("> Quoted *line*\n\n---\n\nAfter"), width: 10)

        #expect(lines.map(\.text) == ["│ Quoted", "│ line", "", "──────────", "", "After"])
        #expect(lines[0].spans == [Span("│ ", .quote), Span("Quoted")])
        #expect(lines[1].spans == [Span("│ ", .quote), Span("line", .emphasis)])
        #expect(lines[3].spans == [Span("──────────", .rule)])
    }

    // A terminal has nowhere to hide an address, so it follows the text when the two
    // differ. A bare address is a link as it stands.
    @Test func aLinkShowsItsTextThenItsAddress() {
        let lines = render(answer("See [the docs](https://x.io/a) or https://y.io/b.\n[https://z.io](https://z.io)"),
                           width: 60)

        #expect(lines.map(\.text) == ["See the docs (https://x.io/a) or https://y.io/b.", "https://z.io"])
        #expect(lines[0].spans == [
            Span("See "), Span("the docs", .link), Span(" (https://x.io/a)", .linkTarget), Span(" or "),
            Span("https://y.io/b", .link), Span("."),
        ])
        #expect(lines[1].spans == [Span("https://z.io", .link)])
    }

    @Test func aTableLinesUpItsColumnsOrWrapsEachRowWhenTooWide() {
        let text = "| Name | Size |\n|:--|--:|\n| a | 10 |\n| bbb | 2 |"

        let wide = render(answer(text), width: 30)
        let narrow = render(answer(text), width: 8)

        #expect(wide.map(\.text) == ["Name │ Size", "─────┼─────", "a    │ 10", "bbb  │ 2"])
        #expect(wide[0].spans == [Span("Name", .strong), Span(" │ ", .rule), Span("Size", .strong)])
        #expect(narrow.map(\.text) == ["Name │", "Size", "a │ 10", "bbb │ 2"])
    }

    // MARK: - Code

    @Test func aFencedBlockIsIndentedAndHighlightedByItsLanguage() {
        let lines = render(answer("Try:\n```swift\nlet x = 1 // one\n```"), width: 30)

        #expect(lines.map(\.text) == ["Try:", "", "  let x = 1 // one"])
        #expect(lines[2].spans == [
            Span("  "), Span("let", .syntax(.keyword)), Span(" x = "), Span("1", .syntax(.number)), Span(" "),
            Span("// one", .syntax(.comment)),
        ])
    }

    // Code keeps every space and is cut at the width, not wrapped at words, and markdown
    // inside it is left alone. A block with no language is not coloured.
    @Test func codeKeepsItsSpacingAndIsCutAtTheWidth() {
        let lines = render(answer("```\n  a  b\nabcdefghijkl\n**not bold**\n```"), width: 8)

        #expect(lines.map(\.text) == ["    a  b", "  abcdef", "  ghijkl", "  **not", "  bold**"])
        #expect(lines.allSatisfy { $0.spans.allSatisfy { $0.style == .plain } })
    }

    // A reply is drawn while it streams, so a block whose closing fence has not arrived
    // yet is still code.
    @Test func anUnclosedFenceIsStillCode() {
        let lines = render(answer("Here:\n~~~python\nx = 'hi'"), width: 30)

        #expect(lines.map(\.text) == ["Here:", "", "  x = 'hi'"])
        #expect(lines[2].spans.last == Span("'hi'", .syntax(.string)))
    }

    @Test func noMarkdownLineIsWiderThanTheWidth() {
        let text = """
            # A heading that is fairly long
            Some **bold words** and `inline code` with [a link](https://example.com/path).
            - a list item that wraps over the line
              - nested 日本語 item
            > a quoted line of text
            | a | b |
            |---|---|
            | one | two |
            ```swift
            let value = "a string that is long" // and a comment
            ```
            """
        for width in 2...40 {
            let lines = render(answer(text), width: width)
            #expect(lines.filter { $0.width > width }.map(\.text) == [], "width \(width)")
        }
    }

    // MARK: - Helpers

    private func render(_ message: RemoteMessage, width: Int) -> [StyledLine] {
        TranscriptRenderer.lines(for: message, width: width)
    }

    private func styles(_ line: StyledLine) -> [LineStyle] {
        line.spans.map(\.style)
    }
}
