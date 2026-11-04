import AppKit
import Foundation
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
        #expect(kinds(text) == [.paragraph("![build](badge.svg){.html link=https://example.com}")])
    }

    // MARK: - Review fixes

    @Test func anImageThatCannotBeDrawnPrintsNoAttributes() {
        #expect(MarkdownBlock.displayText("![build](https://example.com/b.svg){.html width=96} passing")
            == "![build](https://example.com/b.svg) passing")
        #expect(MarkdownBlock.displayText("No images here.") == "No images here.")
        let shown = String(AttributedString.inlineMarkdown(
            MarkdownBlock.displayText("![build](https://example.com/b.svg){.html}")).characters)
        #expect(!shown.contains("{"))
    }

    @Test func aLinkedImageThatCannotBeDrawnLeavesItsLink() {
        let text = #"<a href="https://ci.example.com"><img src="https://ci.example.com/badge.svg" alt="CI"></a>"#
        guard case .paragraph(let body) = kinds(text).first else { Issue.record("expected a paragraph"); return }
        #expect(MarkdownBlock.resolvedParts(body) { _ in nil } == [.text("[CI](https://ci.example.com)")])
        #expect(MarkdownBlock.displayText(body) == "[CI](https://ci.example.com)")
    }

    @Test func aLogoInAHeadingStandsBesideIt() {
        #expect(kinds(#"<h1 align="center"><img src="logo.png" width="120"><br>My App</h1>"#) == [
            .centered(.paragraph("![](logo.png){.html width=120}")),
            .centered(.heading(level: 1, text: "My App")),
        ])
        #expect(kinds(#"<h2>Status <img src="a.png" alt="ok"></h2>"#) == [
            .heading(level: 2, text: "Status"),
            .paragraph("![ok](a.png){.html}"),
        ])
        #expect(kinds(#"<h1><a href="https://example.com"><img src="logo.png"></a></h1>"#) == [
            .paragraph("![](logo.png){.html link=https://example.com}"),
        ])
    }

    @Test func anOversizedImageIsCapped() {
        #expect(MarkdownImageAttributes.points("1e19") == MarkdownImageAttributes.largest)
        #expect(MarkdownBlock.paragraphParts("![x](a.png){width=1e300}")
            == [.image(alt: "x", source: "a.png", attributes: MarkdownImageAttributes(width: MarkdownImageAttributes.largest))])
    }

    @Test func codeKeepsItsTextAsWritten() {
        #expect(kinds("<p>Run <code>npm i my_pkg --save*</code></p>") == [.paragraph("Run `npm i my_pkg --save*`")])
        #expect(kinds("<p><code>a`b</code></p>") == [.paragraph("``a`b``")])
        #expect(kinds("<p><code>`tick</code></p>") == [.paragraph("`` `tick ``")])
        let shown = String(AttributedString.inlineMarkdown("Run `npm i my_pkg --save*`").characters)
        #expect(shown == "Run npm i my_pkg --save*")
    }

    @Test func emphasisLeavesItsSpacesOutside() {
        #expect(kinds("<p><b>Note: </b>read this</p>") == [.paragraph("**Note:** read this")])
        #expect(kinds("<p><strong>\n  Title\n</strong></p>") == [.paragraph("**Title**")])
        #expect(kinds("<p>a <em> </em>b</p>") == [.paragraph("a b")])
        // An element that never closes keeps its text without markup.
        #expect(kinds("<p><b>open") == [.paragraph("open")])
    }

    @Test func anEscapedEntityIsNotDecodedTwice() {
        guard case .paragraph(let body) = kinds("<p>Write &amp;lt;div&amp;gt; or &amp;copy;</p>").first else {
            Issue.record("expected a paragraph"); return
        }
        #expect(String(AttributedString.inlineMarkdown(body).characters) == "Write &lt;div&gt; or &copy;")
    }

    @Test func containersAndCommentsReachAcrossCodeFences() {
        let text = "<div align=\"center\">\n\nIntro\n\n```sh\nmake\n```\n\nMore text\n\n</div>\n\nAfter"
        let segments = MessageSegment.split(text)
        let prose = MarkdownBlock.parse(document: segments)
        let kinds = segments.filter { !$0.isCode }.flatMap { prose[$0.id] ?? [] }.map(\.kind)
        #expect(kinds == [.centered(.paragraph("Intro")), .centered(.paragraph("More text")), .paragraph("After")])

        let commented = "Before\n<!--\n```js\nold()\n```\n-->\nAfter"
        let cleaned = MarkdownHTML.removingComments(commented)
        #expect(MessageSegment.split(cleaned).allSatisfy { !$0.isCode })
        #expect(MarkdownBlock.parse(cleaned, html: true).map(\.kind) == [.paragraph("Before"), .paragraph("After")])
        // A comment written inside a code block is code.
        let code = "```html\n<!-- kept -->\n```"
        #expect(MarkdownHTML.removingComments(code) == code)
    }

    @Test func altTextReadsWithoutItsEscapes() {
        let url = URL(fileURLWithPath: "/tmp/logo.png")
        #expect(MarkdownBlock.resolvedParts(#"![code\_station\!](logo.png){.html}"#) { _ in url }
            == [.image(alt: "code_station!", url: url, attributes: MarkdownImageAttributes(captioned: false))])
        guard case .paragraph(let body) = kinds(#"<img src="logo.png" alt="[logo]">"#).first else {
            Issue.record("expected a paragraph"); return
        }
        #expect(MarkdownBlock.resolvedParts(body) { _ in url }
            == [.image(alt: "[logo]", url: url, attributes: MarkdownImageAttributes(captioned: false))])
    }

    @Test func readsAPictureSizeWithoutDecodingIt() throws {
        let scratch = ScratchDirectory()
        let file = scratch.path("wide.png")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        #expect(ImageThumbnail.pixelSize(file) == CGSize(width: 30, height: 20))
        #expect(ImageThumbnail.pixelSize(scratch.path("missing.png")) == nil)
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
