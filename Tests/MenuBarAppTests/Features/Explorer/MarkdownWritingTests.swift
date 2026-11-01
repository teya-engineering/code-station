import AppKit
import Testing
@testable import MenuBarApp

@MainActor struct MarkdownWritingTests {
    @Test func openingAndLeavingEditPreservesSourceExactly() throws {
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
        #expect(result.contains("Keep **this** and [the link](https://example.com)."))
        #expect(result.contains("- [x] Done"))
        #expect(MarkdownWritingDocument(result) != nil)
    }

    @Test(arguments: [
        "---\ntitle: Plan\n---\n", "| A | B |\n| - | - |\n", "![alt](image.png)",
        "```swift\nlet x = 1\n```", "An `open code span", "<div>Keep</div>",
        "- Parent\n   - Too deep", "  Indented text", "- Item\n\n  second paragraph", "line  \nbreak", "Title\n=====",
        "[link][ref]\n\n[ref]: https://example.com", "1. One\n2. Two", "A &copy; symbol",
        "# Heading ##", "** not bold**", "- # Nested heading", "Text\n2. Not a list", "#### Deep heading"
    ]) func unsupportedSyntaxStaysInSource(_ source: String) {
        #expect(MarkdownWritingDocument(source) == nil)
    }

    @Test func wrappedLinesOpenInEditAsOneParagraph() throws {
        let source = "# Depart\n\nShows the next departures\nfor your saved routes.\n\n- Live data **from National\n  Rail** via a proxy\n- Routes on device\nand nowhere else\n\n> A quote that\n> wraps\n"
        let writing = try #require(MarkdownWritingDocument(source))
        #expect(writing.document.text == "Depart\nShows the next departures for your saved routes.\n• Live data from National Rail via a proxy\n• Routes on device and nowhere else\nA quote that wraps")
        #expect(writing.document.runs.contains { $0.bold && $0.text == "from National Rail" })
        #expect(writing.markdown(afterEditing: NoteDocument(writing.document.attributed)) == source)
    }

    @Test func anEditRewritesOnlyTheBlockItTouched() throws {
        let source = "# Depart UK\n\nAndroid app that shows the next departures\nfor your saved routes, see [the spec](https://example.com).\n\n- Kotlin, Compose\n- Live data through\n  the proxy Lambda\n- Routes on device\n\n```\n./gradlew build\n```\n\nThe end,\nwrapped.\n"
        let writing = try #require(MarkdownWritingDocument(source))
        var edited = writing.document
        let index = try #require(edited.runs.firstIndex { $0.text.contains("Routes on device") })
        edited.runs[index].text = edited.runs[index].text.replacingOccurrences(of: "Routes on device", with: "Routes kept on device")
        let result = writing.markdown(afterEditing: edited)
        #expect(result == source.replacingOccurrences(of: "- Routes on device", with: "- Routes kept on device"))

        let after = MarkdownWritingDocument(source: result, document: edited)
        var added = edited
        added.runs.insert(contentsOf: [.init(text: "\n"), .init(text: "• ", block: .bullet), .init(text: "No account", block: .bullet)],
                          at: index + 1)
        #expect(after.markdown(afterEditing: added)
                == result.replacingOccurrences(of: "- Routes kept on device\n", with: "- Routes kept on device\n- No account\n"))
    }

    @Test func aPlainLineAfterAListItemCarriesOnThatItem() throws {
        let writing = try #require(MarkdownWritingDocument("- One\ncarried on\n\nAfter"))
        #expect(writing.document.text == "• One carried on\nAfter")
    }

    @Test func codeSpansAndNestedListsOpenInEditAndSurviveAnEdit() throws {
        let source = "# Rules\n\n- Use `.motion(_:value:)` and ``a ` tick``\n  - Nested `Motion.hover`\n    - [x] Deeper\n  - Back one\n- Top again\n"
        let writing = try #require(MarkdownWritingDocument(source))
        #expect(writing.markdown(afterEditing: NoteDocument(writing.document.attributed)) == source)
        #expect(writing.document.runs.contains { $0.code && $0.text == ".motion(_:value:)" })
        #expect(writing.document.runs.contains { $0.code && $0.text == "a ` tick" })
        #expect(writing.document.runs.contains { $0.text.hasSuffix("Deeper") && $0.indent == 2 })
        var edited = writing.document
        edited.runs[0].text = "Rules today"
        let result = writing.markdown(afterEditing: edited)
        #expect(result.contains("  - Nested `Motion.hover`"))
        #expect(result.contains("    - [x] Deeper"))
        #expect(result.contains("``a ` tick``"))
        let reparsed = try #require(MarkdownWritingDocument(result))
        #expect(reparsed.document.text == edited.text)
        #expect(reparsed.document.runs.contains { $0.text.hasSuffix("Deeper") && $0.indent == 2 })
    }

    @Test func runsWithoutCodeOrIndentFieldsStillLoad() throws {
        let data = Data(#"{"text":"Old","bold":true,"italic":false,"block":"bullet"}"#.utf8)
        let run = try JSONDecoder().decode(NoteDocument.Run.self, from: data)
        #expect(run == .init(text: "Old", bold: true, block: .bullet))
    }

    @Test func outlineIgnoresCodeFencesAndTracksSourceLines() {
        let headings = MarkdownHeading.read("# First\n\n```md\n# Example\n```\n\n## Next")
        #expect(headings.map(\.title) == ["First", "Next"])
        #expect(headings.map(\.line) == [1, 7])
    }

    @Test func typingMarkdownPunctuationInEditKeepsItLiteral() throws {
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
