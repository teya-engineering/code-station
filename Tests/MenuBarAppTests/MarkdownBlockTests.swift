import AppKit
import SwiftUI
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

    @Test func recognizesAFileLinkAsLocal() {
        let attributed = AttributedString.inlineMarkdown(
            "[AGENTS.md](/Users/test/.codex/AGENTS.md)")

        #expect(attributed.hasLocalFileLink)
    }

    @Test @MainActor func findsTheHoveredFileLinksVisualBounds() throws {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 0, width: 400, height: 30)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = CGSize(width: 400, height: 30)

        let text = NSMutableAttributedString(
            string: "Updated contribute.md to:",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let linkRange = (text.string as NSString).range(of: "contribute.md")
        let url = URL(fileURLWithPath: "/tmp/contribute.md")
        text.addAttribute(.link, value: url, range: linkRange)
        textView.textStorage?.setAttributedString(text)

        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: linkRange,
            actualCharacterRange: nil)
        let expected = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let point = CGPoint(x: expected.midX, y: expected.midY)

        let hovered = try #require(TranscriptLink.hoveredLink(in: textView, at: point))

        #expect(hovered.url == url)
        #expect(abs(hovered.frame.minX - expected.minX) < 0.5)
        #expect(abs(hovered.frame.maxX - expected.maxX) < 0.5)
        #expect(hovered.frame.maxX < textView.bounds.midX)
        #expect(TranscriptLink.hoveredLink(
            in: textView,
            at: CGPoint(x: textView.bounds.maxX - 5, y: expected.midY)) == nil)
    }

    @Test func leavesAWebLinkUnchanged() {
        let attributed = AttributedString.inlineMarkdown("[OpenAI](https://openai.com/docs)")
        let url = attributed.runs.compactMap(\.link).first

        #expect(url?.absoluteString == "https://openai.com/docs")
        #expect(url?.isFileURL == false)
        #expect(!attributed.hasLocalFileLink)
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

    @Test @MainActor func givesWrappedLinkedListTextItsFullHeight() throws {
        let wrappedItem = MarkdownListItem(
            depth: 0,
            marker: "1.",
            text: "A list item with enough text to wrap before its " +
                "[linked documentation](https://example.com/documentation).")
        let followingItem = MarkdownListItem(
            depth: 0,
            marker: "2.",
            text: "Read the [next page](https://example.com/next).")
        let view = MarkdownBlockView(
            block: MarkdownBlock(id: 0, kind: .list([wrappedItem, followingItem])),
            projectPath: "/tmp",
            textScale: 1)
            .environment(TooltipPresenter())
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 200)
        host.layoutSubtreeIfNeeded()
        host.frame.size.width = 280
        host.layoutSubtreeIfNeeded()

        let textViews = host.descendants.compactMap { $0 as? NSTextView }
        try #require(textViews.count == 2)
        for textView in textViews {
            let layoutManager = try #require(textView.layoutManager)
            let container = try #require(textView.textContainer)
            layoutManager.ensureLayout(for: container)
            #expect(textView.frame.height >= ceil(layoutManager.usedRect(for: container).height))
        }

        let frames = textViews.map { host.convert($0.bounds, from: $0) }.sorted { $0.minY < $1.minY }
        #expect(frames[0].maxY <= frames[1].minY)
    }

    @Test @MainActor func laysOutLinkedTableCellsWithoutOverlapping() throws {
        let table = MarkdownTable(
            header: ["Price", "Area", "Address", "Beds", "Station", "Walk", "Commute", "Garden"],
            alignments: Array(repeating: .leading, count: 8),
            rows: [
                ["£750,000", "Hayes", "[Hawthorndene Road, BR2](https://example.com/one)", "4",
                 "Hayes", "<0.25 mi", "59 min", "134 m²"],
                ["£760,000", "Hayes", "[Cameron Road, Bromley](https://example.com/two)", "3",
                 "Bromley South", "15 min", "53 min", "195 m²"],
                ["£800,000", "Coulsdon S", "[Byron Avenue, CR5](https://example.com/three)", "5",
                 "Coulsdon Town", "<0.25 mi", "51 min", "250 m²"],
            ])
        let firstRow = MarkdownTable(header: table.header,
                                     alignments: table.alignments,
                                     rows: Array(table.rows.prefix(1)))
        let tooltipPresenter = TooltipPresenter()
        let view = MarkdownBlockView(
            block: MarkdownBlock(id: 0, kind: .table(firstRow)),
            projectPath: "/tmp",
            textScale: 1)
            .equatable()
            .environment(tooltipPresenter)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 620, height: 800)
        host.layoutSubtreeIfNeeded()
        host.rootView = MarkdownBlockView(
            block: MarkdownBlock(id: 0, kind: .table(table)),
            projectPath: "/tmp",
            textScale: 1)
            .equatable()
            .environment(tooltipPresenter)
        host.layoutSubtreeIfNeeded()

        let textViews = host.descendants.compactMap { $0 as? NSTextView }
        try #require(textViews.count == 3)
        #expect(textViews.allSatisfy { $0.frame.width >= 80 })
        for textView in textViews {
            let layoutManager = try #require(textView.layoutManager)
            let container = try #require(textView.textContainer)
            layoutManager.ensureLayout(for: container)
            #expect(textView.frame.height >= ceil(layoutManager.usedRect(for: container).height))
        }

        let frames = textViews.map { host.convert($0.bounds, from: $0) }.sorted { $0.minY < $1.minY }
        for pair in zip(frames, frames.dropFirst()) {
            #expect(pair.0.maxY <= pair.1.minY)
        }
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
