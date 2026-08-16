import AppKit
import Foundation
import Testing
@testable import MenuBarApp

// Prose is cut into blocks so tables, headings and lists can be drawn as such
// instead of showing their raw markdown.
struct MarkdownBlockTests {

    private func kinds(_ text: String) -> [MarkdownBlock.Kind] {
        MarkdownBlock.parse(text).map(\.kind)
    }

    private func link(in text: String) -> URL? {
        AttributedString.inlineMarkdown(text).runs.compactMap(\.link).first
    }

    @Test func readsATableWithItsAlignments() {
        let text = """
        | Field | Value | Count |
        |:---|:---:|---:|
        | one | two | 3 |
        | four | five | 6 |
        """
        guard case .table(let table) = kinds(text).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.header == ["Field", "Value", "Count"])
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.rows == [["one", "two", "3"], ["four", "five", "6"]])
    }

    @Test func leavesPipesWithoutASeparatorRowAsProse() {
        let text = "| just | pipes |\n| more | pipes |"
        #expect(kinds(text) == [.paragraph(text)])
    }

    @Test func keepsAnEscapedPipeInsideItsCell() {
        let text = """
        | a | b |
        |---|---|
        | left \\| right | x |
        """
        guard case .table(let table) = kinds(text).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows == [["left | right", "x"]])
    }

    @Test func squaresRaggedRowsToTheHeaderWidth() {
        let text = """
        | a | b |
        |---|---|
        | one |
        | one | two | three |
        """
        guard case .table(let table) = kinds(text).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows == [["one", ""], ["one", "two"]])
    }

    @Test func readsHeadingLevels() {
        #expect(kinds("# Title") == [.heading(level: 1, text: "Title")])
        #expect(kinds("### Deep") == [.heading(level: 3, text: "Deep")])
        #expect(kinds("## Closed ##") == [.heading(level: 2, text: "Closed")])
    }

    @Test func leavesHashesThatAreNotAHeadingAlone() {
        #expect(kinds("#nospace") == [.paragraph("#nospace")])
        #expect(kinds("####### seven") == [.paragraph("####### seven")])
    }

    @Test func readsBulletsWithTheirNesting() {
        let text = """
        - top
          - inner
        - back out
        """
        guard case .list(let items) = kinds(text).first else {
            Issue.record("expected a list")
            return
        }
        #expect(items.map(\.text) == ["top", "inner", "back out"])
        #expect(items.map(\.depth) == [0, 1, 0])
    }

    @Test func keepsOrderedMarkersAsWritten() {
        let text = "1. first\n2) second"
        guard case .list(let items) = kinds(text).first else {
            Issue.record("expected a list")
            return
        }
        #expect(items.map(\.marker) == ["1.", "2)"])
        #expect(items.map(\.text) == ["first", "second"])
    }

    @Test func turnsCheckboxesIntoTheirBoxes() {
        let text = "- [ ] todo\n- [x] done"
        guard case .list(let items) = kinds(text).first else {
            Issue.record("expected a list")
            return
        }
        #expect(items.map(\.marker) == ["☐", "☑"])
        #expect(items.map(\.text) == ["todo", "done"])
    }

    @Test func joinsAQuoteAcrossItsLines() {
        let text = "> first line\n> second line"
        #expect(kinds(text) == [.quote("first line\nsecond line")])
    }

    @Test func tellsARuleFromAList() {
        #expect(kinds("---") == [.rule])
        #expect(kinds("* * *") == [.rule])
        #expect(kinds("--") == [.paragraph("--")])
    }

    @Test func keepsSingleNewlinesInsideAParagraph() {
        let text = "line one\nline two"
        #expect(kinds(text) == [.paragraph("line one\nline two")])
    }

    @Test func splitsParagraphsOnBlankLines() {
        #expect(kinds("one\n\ntwo") == [.paragraph("one"), .paragraph("two")])
    }

    @Test func flushesProseAroundATable() {
        let text = """
        Before the table.
        | a | b |
        |---|---|
        | 1 | 2 |
        After the table.
        """
        let parsed = kinds(text)
        #expect(parsed.count == 3)
        #expect(parsed.first == .paragraph("Before the table."))
        #expect(parsed.last == .paragraph("After the table."))
    }

    @Test func givesEveryBlockItsOwnIdentity() {
        let ids = MarkdownBlock.parse("# a\n\ntext\n\n- item").map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func turnsAnAbsolutePathLinkIntoAFileURL() {
        let url = link(in: "[AGENTS.md](/Users/test/.codex/AGENTS.md)")

        #expect(url?.isFileURL == true)
        #expect(url?.path == "/Users/test/.codex/AGENTS.md")
    }

    @Test func expandsAHomeRelativePathLink() {
        let url = link(in: "[AGENTS.md](~/.codex/AGENTS.md)")

        #expect(url?.isFileURL == true)
        #expect(url?.path == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/AGENTS.md").path)
    }

    @Test func describesAFileLinkAsOpeningInFinder() throws {
        let run = try #require(AttributedString.inlineMarkdown(
            "[AGENTS.md](/Users/test/.codex/AGENTS.md)").runs.first(where: { $0.link != nil }))

        #expect(run.appKit.toolTip == "Open in Finder")
    }

    @Test func leavesAWebLinkUnchanged() {
        let url = link(in: "[OpenAI](https://openai.com/docs)")

        #expect(url?.absoluteString == "https://openai.com/docs")
        #expect(url?.isFileURL == false)
    }

    @Test func keepsAFileURLWithoutASourceLine() {
        let url = URL(fileURLWithPath: "/tmp/result.png")

        let target = TranscriptLink.finderTarget(for: url, fileExists: { _ in true })

        #expect(target == url)
    }

    @Test func removesASourceLineFromAnExistingFile() {
        let url = URL(fileURLWithPath: "/tmp/DesignKit.swift:337")

        let target = TranscriptLink.finderTarget(for: url) {
            $0 == "/tmp/DesignKit.swift"
        }

        #expect(target?.path == "/tmp/DesignKit.swift")
    }

    @Test func keepsASourceLineWhenTheFileCannotBeFound() {
        let url = URL(fileURLWithPath: "/tmp/DesignKit.swift:337")

        let target = TranscriptLink.finderTarget(for: url, fileExists: { _ in false })

        #expect(target == url)
    }

    @Test func leavesAWebLinkForTheSystemHandler() throws {
        let url = try #require(URL(string: "https://openai.com/docs"))

        #expect(TranscriptLink.finderTarget(for: url) == nil)
    }
}
