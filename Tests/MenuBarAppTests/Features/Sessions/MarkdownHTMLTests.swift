import Testing
@testable import MenuBarApp

// A document's HTML blocks are drawn as the page they describe, not printed as tags.
// A transcript keeps them as written.
struct MarkdownHTMLTests {
    private func kinds(_ text: String) -> [MarkdownBlock.Kind] {
        MarkdownBlock.parse(text, html: true).map(\.kind)
    }

    @Test func readsAReadmeHeader() {
        let text = """
        <p align="center">
          <img src="docs/icon.png" width="96" height="96" alt="Example App icon">
        </p>
        <h1 align="center">Example App</h1>
        <p align="center">A small example app for the menu bar.</p>

        <p align="center">
          <img src="docs/screenshot.png" width="352" alt="Menu bar panel">
        </p>

        Plain Markdown after the header.

        <!-- docs/icon.png is a rendered copy of the source icon; update it when the icon
        changes. -->

        ## Requirements
        """
        #expect(kinds(text) == [
            .centered(.paragraph("![Example App icon](docs/icon.png){.html width=96 height=96}")),
            .centered(.heading(level: 1, text: "Example App")),
            .centered(.paragraph("A small example app for the menu bar.")),
            .centered(.paragraph("![Menu bar panel](docs/screenshot.png){.html width=352}")),
            .paragraph("Plain Markdown after the header."),
            .heading(level: 2, text: "Requirements"),
        ])
    }

    @Test func leavesHTMLAloneOutsideDocuments() {
        let text = "<p align=\"center\">Hello</p>"
        #expect(MarkdownBlock.parse(text).map(\.kind) == [.paragraph(text)])
    }

    @Test func centresMarkdownBetweenADivAndItsClose() {
        let text = """
        <div align="center">

        # Title

        ![logo](logo.png)

        - a list stays as it is

        </div>

        After.
        """
        #expect(kinds(text) == [
            .centered(.heading(level: 1, text: "Title")),
            .centered(.paragraph("![logo](logo.png)")),
            .list([MarkdownListItem(depth: 0, marker: "•", text: "a list stays as it is")]),
            .paragraph("After."),
        ])
    }

    @Test func anUnclosedParagraphDoesNotCentreWhatFollows() {
        #expect(kinds("<p align=\"center\">Centred\n\nNot centred") == [
            .centered(.paragraph("Centred")),
            .paragraph("Not centred"),
        ])
    }

    @Test func turnsInlineMarkupIntoMarkdown() {
        let text = #"<p>Press <kbd>Cmd</kbd>, read <a href="docs/guide.md">the <b>guide</b></a>,<br>then *stop* &amp; rest.</p>"#
        #expect(kinds(text) == [
            .paragraph("Press `Cmd`, read [the **guide**](docs/guide.md),\nthen \\*stop\\* & rest."),
        ])
    }

    @Test func aLinkedBadgeShowsItsPicture() {
        let text = #"<a href="https://example.com"><img src="badge.svg" alt="build"></a>"#
        #expect(kinds(text) == [.paragraph("![build](badge.svg){.html}")])
    }

    @Test func readsAList() {
        let text = "<ol>\n<li>One</li>\n<li>Two\n<ul><li>Nested</li></ul></li>\n</ol>"
        #expect(kinds(text) == [.list([
            MarkdownListItem(depth: 0, marker: "1.", text: "One"),
            MarkdownListItem(depth: 0, marker: "2.", text: "Two"),
            MarkdownListItem(depth: 1, marker: "◦", text: "Nested"),
        ])])
    }

    @Test func dropsCommentsScriptsAndStyles() {
        let text = "<!-- hidden -->\n\n<script>alert(1)</script>\n\n<style>p { color: red }</style>\n\nShown"
        #expect(kinds(text) == [.paragraph("Shown")])
    }

    @Test func aLineOfInlineHTMLWithTextIsAParagraph() {
        // CommonMark only opens an HTML block for an inline tag on a line of tags alone.
        let text = "<kbd>Cmd</kbd> opens it"
        #expect(kinds(text) == [.paragraph(text)])
        #expect(kinds("Some text\n<img src=\"a.png\">") == [.paragraph("Some text\n<img src=\"a.png\">")])
    }

    @Test func leavesThingsThatAreNotTagsAlone() {
        for text in ["<not a tag", "< p>", "<https://example.com>", "<3 this"] {
            #expect(kinds(text) == [.paragraph(text)])
        }
    }

    @Test func passesAnImageSizeOn() {
        #expect(kinds(#"<img src="a.png" width="96px" height="50%" alt="x">"#) == [.paragraph("![x](a.png){.html width=96}")])
        #expect(kinds(#"<img src="a.png" height="40.5">"#) == [.paragraph("![](a.png){.html height=40.5}")])
        #expect(kinds(#"<img src="a.png" width="wide">"#) == [.paragraph("![](a.png){.html}")])
        // A brace written as text is not read as a size.
        #expect(kinds(#"<p><img src="a.png">{width=9}</p>"#) == [.paragraph(#"![](a.png){.html}\{width=9}"#)])
    }

    @Test func readsAnImageSizeAfterAnImage() {
        #expect(MarkdownBlock.paragraphParts("![x](a.png){width=96 height=48} after") == [
            .image(alt: "x", source: "a.png", attributes: MarkdownImageAttributes(width: 96, height: 48)),
            .text(" after"),
        ])
        #expect(MarkdownBlock.paragraphParts(#"![x](a.png){.wide #top width="120px"}"#) == [
            .image(alt: "x", source: "a.png", attributes: MarkdownImageAttributes(width: 120)),
        ])
        for text in ["![x](a.png){not attributes}", "![x](a.png){width=}", "![x](a.png){class=wide}",
                     "![x](a.png){width=9", "![x](a.png) {width=9}"] {
            #expect(MarkdownBlock.paragraphParts(text).first == .image(alt: "x", source: "a.png"))
        }
        // A link takes no size.
        #expect(MarkdownBlock.paragraphParts("[x](a.png){width=9}") == [
            .link(label: "x", source: "a.png"), .text("{width=9}"),
        ])
    }

    @Test func anImageFromHTMLHasNoCaption() {
        #expect(MarkdownBlock.paragraphParts("![x](a.png){.html}") == [
            .image(alt: "x", source: "a.png", attributes: MarkdownImageAttributes(captioned: false)),
        ])
        #expect(MarkdownBlock.paragraphParts("![x](a.png){.html width=96}") == [
            .image(alt: "x", source: "a.png", attributes: MarkdownImageAttributes(width: 96, captioned: false)),
        ])
        // Another class alone says nothing about the image, so it is not read.
        #expect(MarkdownBlock.paragraphParts("![x](a.png){.wide}") == [
            .image(alt: "x", source: "a.png"), .text("{.wide}"),
        ])
        #expect(MarkdownBlock.resolvedParts("![x](https://example.com/a.png){.html}") { _ in nil }
            == [.text("![x](https://example.com/a.png)")])
    }

    @Test func anUnresolvedImageDropsItsSize() {
        #expect(MarkdownBlock.resolvedParts("![x](https://example.com/a.png){width=9}") { _ in nil }
            == [.text("![x](https://example.com/a.png)")])
    }

    @Test func decodesEntities() {
        #expect(MarkdownHTML.decodeEntities("&lt;a&gt; &#169; &#x2014; &bogus; & x") == "<a> © — &bogus; & x")
    }
}
