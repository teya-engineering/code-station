import AppKit
import Testing
@testable import MenuBarApp

@MainActor struct MarkdownWritingTests {
    @Test func openingAndLeavingWritePreservesSourceExactly() throws {
        let source = "# My title\n\nA **bold** thought and *emphasis*.\n\n## Next\n\n- [ ] Check this\n- [x] Done\n\n[Link](https://example.com)\n\n```\nlet x = 1\nprint(x)\n```\n"
        let writing = try #require(MarkdownWritingDocument(source))
        #expect(writing.document.text.contains("☐ Check this"))
        #expect(writing.markdown(afterEditing: NoteDocument(writing.document.attributed)) == source)
    }

    @Test func supportedEditsKeepFormattingAndUnicode() throws {
        let source = "# Plan 🌍\n\nKeep **this** and [the link](https://example.com).\n\n- [x] Done\n"
        let writing = try #require(MarkdownWritingDocument(source))
        var edited = writing.document
        edited.runs[0].text = "Plan 🌍 today"
        let result = writing.markdown(afterEditing: edited)
        #expect(result.hasPrefix("# Plan 🌍 today"))
        #expect(result.contains("**this**"))
        #expect(result.contains("[the link](<https://example.com>)"))
        #expect(result.contains("- [x] Done"))
        #expect(MarkdownWritingDocument(result) != nil)
    }

    @Test(arguments: [
        "---\ntitle: Plan\n---\n", "| A | B |\n| - | - |\n", "![alt](image.png)",
        "```swift\nlet x = 1\n```", "A `code` span", "<div>Keep</div>",
        "- Parent\n  - Child", "line  \nbreak", "soft\nwrap", "Title\n=====",
        "[link][ref]\n\n[ref]: https://example.com", "1. One\n2. Two", "A &copy; symbol",
        "# Heading ##", "** not bold**", "- # Nested heading"
    ]) func unsupportedSyntaxStaysInSource(_ source: String) {
        #expect(MarkdownWritingDocument(source) == nil)
    }

    @Test func outlineIgnoresCodeFencesAndTracksSourceLines() {
        let headings = MarkdownHeading.read("# First\n\n```md\n# Example\n```\n\n## Next")
        #expect(headings.map(\.title) == ["First", "Next"])
        #expect(headings.map(\.line) == [1, 7])
    }

    @Test func typingMarkdownPunctuationInWriteKeepsItLiteral() throws {
        let text = "- literal list\n1. literal number\n~~~\n&copy; and ~strike~"
        let document = NoteDocument(runs: [.init(text: text)])
        let parsed = try #require(MarkdownWritingDocument(document.markdown))
        #expect(parsed.document.text == text)
        #expect(parsed.document.runs.allSatisfy { $0.block == .text })
    }

    @Test func boldAndItalicKeepValidDelimitersAroundSelectedWhitespace() throws {
        let document = NoteDocument(runs: [.init(text: "before"), .init(text: " both ", bold: true, italic: true), .init(text: "after")])
        #expect(document.markdown == "before ***both*** after")
        let parsed = try #require(MarkdownWritingDocument(document.markdown))
        #expect(parsed.document.text == "before both after")
        #expect(parsed.document.runs.contains { $0.text == "both" && $0.bold && $0.italic })
    }

    @Test func renamedAndClosedDocumentsKeepTheRightModes() {
        var documents = ExplorerDocuments()
        documents.modes["/project/notes.md"] = .preview
        documents.moved(from: "/project/notes.md", to: "/project/docs/notes.md")
        #expect(documents.modes["/project/docs/notes.md"] == .preview)
        #expect(documents.modes["/project/notes.md"] == nil)
        documents.close("/project/docs/notes.md")
        #expect(documents.modes.isEmpty)
    }
}
