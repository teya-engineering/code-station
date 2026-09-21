import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// A transcript draws every paragraph as its own text view, so selecting across two of
// them is something the app has to arrange rather than something AppKit does.
@MainActor
struct TranscriptSelectionTests {
    private static let first = "The first paragraph of the answer."
    private static let second = "A whole middle paragraph that should come through unbroken."
    private static let third = "And the third paragraph closing it out."

    private static let code = "let total = 1\nlet other = 2"

    private var markdown: String {
        [Self.first, Self.second, Self.third].joined(separator: "\n\n")
    }

    private static let table = """
    | Field | Value |
    |---|---|
    | one | two |
    | three | four |
    """

    private var markdownWithCode: String {
        "\(Self.first)\n\n```swift\n\(Self.code)\n```\n\n\(Self.third)"
    }

    @Test func aDragFromOneParagraphIntoAnotherSelectsEveryBlockBetween() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }
        try #require(page.views.count == 2)

        selection.begin(in: page.views[0], at: page.views[0].point(atCharacter: 10))
        selection.extend(toWindowPoint: page.windowPoint(of: page.views[1], character: 12))

        #expect(try parts(of: selection) == [String(Self.first.dropFirst(10)),
                                             Self.second,
                                             String(Self.third.prefix(12))])
    }

    // Selecting up the page is the same selection as selecting down it, so the text
    // comes back in reading order either way.
    @Test func draggingBackwardsReadsTheSameWayRound() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        selection.begin(in: page.views[1], at: page.views[1].point(atCharacter: 12))
        selection.extend(toWindowPoint: page.windowPoint(of: page.views[0], character: 10))

        #expect(try parts(of: selection) == [String(Self.first.dropFirst(10)),
                                             Self.second,
                                             String(Self.third.prefix(12))])
    }

    // Two paragraphs sharing a text view are still two paragraphs: a drag that starts
    // and ends inside the second one takes nothing of the first.
    @Test func aDragInsideOneParagraphStaysThere() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        let view = page.views[0]
        let second = Self.first.count + 1
        selection.begin(in: view, at: view.point(atCharacter: second + 2))
        selection.extend(toWindowPoint: page.windowPoint(of: view, character: second + 20))

        #expect(try parts(of: selection) == [String(Self.second.dropFirst(2).prefix(18))])
    }

    // The pointer spends part of a drag in the gaps between blocks, where there is no
    // text under it at all. The selection has to keep running rather than freeze.
    @Test func draggingPastTheLastParagraphRunsToItsEnd() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        let last = page.views[1]
        let below = last.convert(CGPoint(x: last.bounds.midX, y: last.bounds.maxY + 40), to: nil)
        selection.begin(in: page.views[0], at: page.views[0].point(atCharacter: 10))
        selection.extend(toWindowPoint: below)

        #expect(try parts(of: selection) == [String(Self.first.dropFirst(10)),
                                             Self.second,
                                             Self.third])
    }

    @Test func selectAllTakesEveryBlockWhole() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        selection.selectAll()

        #expect(selection.selectedText == [Self.first, Self.second, Self.third]
            .joined(separator: "\n\n"))
    }

    @Test func clearingLeavesNothingSelected() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        selection.selectAll()
        selection.clear()

        #expect(selection.selectedText == nil)
        #expect(page.views.allSatisfy { $0.selectedRange().length == 0 })
    }

    // A block that goes away mid-drag must not take the selection's word for where its
    // text ended, since a streaming turn rewrites the block it is still filling.
    @Test func aBlockLeavingTheWindowDropsOutOfTheSelection() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdownWithCode, selection: selection)
        defer { page.close() }
        try #require(page.views.count == 3)

        selection.selectAll()
        let departed = page.views[1]
        departed.removeFromSuperview()

        let parts = try parts(of: selection)
        #expect(parts == [Self.first, Self.third])
    }

    // The coordinator is only reached through the mouse, so the wiring in the text view
    // is worth driving with real events rather than trusting by inspection.
    @Test func aRealDragAcrossBlocksSelectsThroughTheTextViews() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        page.drag(from: (page.views[0], 10), to: (page.views[1], 12))

        #expect(try parts(of: selection) == [String(Self.first.dropFirst(10)),
                                             Self.second,
                                             String(Self.third.prefix(12))])
        // Copy arrives at the first responder, so the block the drag started in has to
        // hold it for the whole selection to be what lands on the clipboard.
        #expect(page.window.firstResponder === page.views[0])
    }

    // A press on a link that never moves still opens it, and does not leave a stray
    // selection behind. This is the case the selection could most easily have taken
    // over, since both start with a press on text.
    @Test func clickingALinkStillOpensItRatherThanSelecting() throws {
        let selection = TranscriptSelection()
        var opened: [URL] = []
        let page = try Page(markdown: "Open [result](/tmp/report.txt) now.",
                            selection: selection,
                            openURL: { opened.append($0) })
        defer { page.close() }

        let view = try #require(page.views.first)
        page.click(view, atCharacter: view.characterIndex(of: "result"))

        #expect(opened.map(\.path) == ["/tmp/report.txt"])
        #expect(selection.selectedText == nil)
    }

    // Dragging off a link is how someone selects text that happens to be a link, so the
    // press has to turn into a selection instead of opening anything.
    @Test func draggingOffALinkSelectsInsteadOfOpeningIt() throws {
        let selection = TranscriptSelection()
        var opened: [URL] = []
        let page = try Page(markdown: "Open [result](/tmp/report.txt) now.",
                            selection: selection,
                            openURL: { opened.append($0) })
        defer { page.close() }

        let view = try #require(page.views.first)
        let start = view.characterIndex(of: "result")
        page.drag(from: (view, start), to: (view, start + 6))

        #expect(opened.isEmpty)
        #expect(selection.selectedText == "result")
    }

    // AppKit dims the selection in any text view that is not the first responder, and
    // only one block of a page can hold that. The app paints the highlight itself for
    // exactly this reason, so every block a selection reaches has to show it.
    @Test func everyBlockInTheSelectionPaintsItsHighlight() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        let before = page.views.map { $0.paintedPixels() }
        selection.selectAll()
        let after = page.views.map { $0.paintedPixels() }

        try #require(before.allSatisfy { $0 > 0 })
        for (blank, highlighted) in zip(before, after) {
            #expect(highlighted > blank * 2)
        }
    }

    // MARK: - Code blocks

    @Test func aSelectionRunsThroughACodeBlock() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdownWithCode, selection: selection)
        defer { page.close() }
        try #require(page.views.count == 3)

        selection.selectAll()

        #expect(try parts(of: selection) == [Self.first, Self.code, Self.third])
    }

    @Test func aDragFromProseIntoCodeStopsWhereThePointerDoes() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdownWithCode, selection: selection)
        defer { page.close() }

        selection.begin(in: page.views[0], at: page.views[0].point(atCharacter: 10))
        selection.extend(toWindowPoint: page.windowPoint(of: page.views[1], character: 9))

        #expect(try parts(of: selection) == [String(Self.first.dropFirst(10)),
                                             String(Self.code.prefix(9))])
    }

    // Code is copied with the line breaks it was written with, not with whatever breaks
    // the width of the window would have imposed.
    @Test func codeKeepsItsOwnLineBreaks() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdownWithCode, selection: selection)
        defer { page.close() }

        selection.selectAll()
        let code = try parts(of: selection)[1]

        #expect(code == Self.code)
        #expect(code.components(separatedBy: "\n").count == 2)
    }

    // A long line runs off the side into the block's own scroller rather than folding,
    // so the text view has to be wider than the page it sits on.
    @Test func aLongLineOfCodeIsWiderThanThePage() throws {
        let selection = TranscriptSelection()
        let long = String(repeating: "veryLongIdentifier.", count: 20)
        let page = try Page(markdown: "```swift\n\(long)\n```", selection: selection)
        defer { page.close() }

        let view = try #require(page.views.first)
        #expect(view.frame.width > page.window.frame.width)
    }

    // The colours are set per token on the attributed string the highlighter returns,
    // and the text view builds its own string from those runs.
    @Test func highlightedCodeKeepsItsTokenColours() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdownWithCode, selection: selection)
        defer { page.close() }

        let storage = try #require(page.views[1].textStorage)
        var colours: Set<NSColor> = []
        storage.enumerateAttribute(.foregroundColor,
                                   in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let colour = value as? NSColor { colours.insert(colour) }
        }

        #expect(colours.count > 1)
    }

    // MARK: - Thoughts

    // A model's reasoning is not markdown. Asterisks, backticks and brackets in it are
    // characters it wrote, so they have to survive to the screen as typed.
    @Test func aThoughtIsShownExactlyAsItArrived() throws {
        let thought = "Try **bold**, `code` and [a link](/tmp/x) as written."
        let selection = TranscriptSelection()
        let page = try Page(selection: selection) { Self.thoughtBlock(thought) }
        defer { page.close() }

        #expect(page.views.first?.textStorage?.string == thought)

        // The markdown path is what it must not be taking: that one eats the marks.
        let prose = try Page(selection: TranscriptSelection()) {
            SelectableText(thought, size: 12)
        }
        defer { prose.close() }
        #expect(prose.views.first?.textStorage?.string != thought)
    }

    @Test func aThoughtJoinsTheSelectionAroundIt() throws {
        let thought = "A thought worth copying with the answer."
        let selection = TranscriptSelection()
        let page = try Page(selection: selection) {
            VStack(alignment: .leading, spacing: 12) {
                SelectableText(Self.first, size: 13.5)
                Self.thoughtBlock(thought)
                SelectableText(Self.third, size: 13.5)
            }
        }
        defer { page.close() }
        try #require(page.views.count == 3)

        selection.selectAll()

        #expect(try parts(of: selection) == [Self.first, thought, Self.third])
    }

    // A thought is an aside, so it stays dim and slanted rather than reading as part of
    // the answer once it is drawn by a text view instead of by SwiftUI.
    @Test func aThoughtKeepsItsAsideStyling() throws {
        let selection = TranscriptSelection()
        let page = try Page(selection: selection) { Self.thoughtBlock("Slanted and dim.") }
        defer { page.close() }

        let storage = try #require(page.views.first?.textStorage)
        let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let paragraph = try #require(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)

        #expect(font.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == .secondaryLabelColor)
        #expect(paragraph.lineSpacing == 3)
    }

    // The same call the thinking block makes, so these test what the transcript draws.
    private static func thoughtBlock(_ text: String) -> some View {
        SelectableText(plain: text, size: 12, secondary: true, italic: true, lineSpacing: 3)
    }

    // MARK: - System notes

    // A note is the one block the transcript shows with no disclosure in front of it,
    // so this can run through the real message view rather than through the text it is
    // built from.
    @Test func aSystemNoteJoinsTheSelectionAroundIt() throws {
        let note = "Stopped to protect your Mac."
        let selection = TranscriptSelection()
        let page = try Page(selection: selection) {
            VStack(alignment: .leading, spacing: 16) {
                MessageView(message: ChatMessage(role: .assistant, text: Self.first),
                            projectPath: "/tmp", textScale: 1)
                MessageView(message: ChatMessage(role: .system, text: note),
                            projectPath: "/tmp", textScale: 1)
            }
        }
        defer { page.close() }
        try #require(page.views.count == 2)

        selection.selectAll()

        #expect(try parts(of: selection) == [Self.first, note])
    }

    // A note reports what the app did, in the app's own words. Backticks and asterisks
    // in it are punctuation, and it stays monospaced so it reads as machine output.
    @Test func aSystemNoteIsShownAsTypedAndInMono() throws {
        let note = "Ran `git status` and found **no** changes."
        let selection = TranscriptSelection()
        let page = try Page(selection: selection) {
            MessageView(message: ChatMessage(role: .system, text: note),
                        projectPath: "/tmp", textScale: 1)
        }
        defer { page.close() }

        let storage = try #require(page.views.first?.textStorage)
        let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        #expect(storage.string == note)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == .secondaryLabelColor)
    }

    // MARK: - The prompt bubble

    // A prompt has no disclosure in front of it either, so this runs through the real
    // message views: the answer and the prompt that asked for it come back together.
    @Test func aPromptJoinsTheSelectionWithTheAnswer() throws {
        let prompt = "Why can I not select two paragraphs?"
        let selection = TranscriptSelection()
        let page = try Page(selection: selection) {
            VStack(alignment: .leading, spacing: 16) {
                MessageView(message: ChatMessage(role: .user, text: prompt),
                            projectPath: "/tmp", textScale: 1, availableWidth: 800)
                MessageView(message: ChatMessage(role: .assistant, text: Self.first),
                            projectPath: "/tmp", textScale: 1, availableWidth: 800)
            }
        }
        defer { page.close() }
        try #require(page.views.count == 2)

        selection.selectAll()

        #expect(try parts(of: selection) == [prompt, Self.first])
    }

    // The bubble is drawn around the words. A text view that claimed the whole width it
    // was allowed would stretch a two word prompt into a banner.
    @Test func aShortPromptDoesNotStretchItsBubble() throws {
        let selection = TranscriptSelection()
        let short = try Page(selection: selection) {
            MessageView(message: ChatMessage(role: .user, text: "Thanks"),
                        projectPath: "/tmp", textScale: 1, availableWidth: 800)
        }
        defer { short.close() }
        let long = try Page(selection: TranscriptSelection()) {
            MessageView(message: ChatMessage(role: .user,
                                             text: String(repeating: "a longer prompt ", count: 20)),
                        projectPath: "/tmp", textScale: 1, availableWidth: 800)
        }
        defer { long.close() }

        let shortWidth = try #require(short.views.first).frame.width
        let longWidth = try #require(long.views.first).frame.width

        #expect(shortWidth < 100)
        #expect(longWidth > shortWidth * 3)
    }

    // The transcript draws its own menus. A text view handed the right-click would put
    // up AppKit's instead, which is a piece of another program in the middle of a page.
    @Test func aBlockNeverOffersTheSystemMenu() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        let view = try #require(page.views.first)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: page.windowPoint(of: view, character: 3),
            modifierFlags: [], timestamp: 0, windowNumber: page.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        #expect(view.menu(for: click) == nil)
    }

    // MARK: - Tables

    // A grid pasted as a column of loose words is no use. Tabs between the cells of a
    // row and a newline between rows is what a spreadsheet and most editors read back
    // as the table it came from.
    @Test func aTableCopiesAsRowsAndColumns() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: Self.table, selection: selection)
        defer { page.close() }
        try #require(page.views.count == 6)

        selection.selectAll()

        #expect(selection.selectedText == "Field\tValue\none\ttwo\nthree\tfour")
    }

    @Test func aTableKeepsItsShapeAmongTheProseAroundIt() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: "\(Self.first)\n\n\(Self.table)\n\n\(Self.third)",
                            selection: selection)
        defer { page.close() }

        selection.selectAll()

        #expect(try parts(of: selection) == [Self.first,
                                             "Field\tValue\none\ttwo\nthree\tfour",
                                             Self.third])
    }

    // Two tables next to each other are two grids, not one, so the rows of the second
    // must not carry on from the rows of the first.
    @Test func twoTablesStayTwoGrids() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: "\(Self.table)\n\n\(Self.table)", selection: selection)
        defer { page.close() }
        try #require(page.views.count == 12)

        selection.selectAll()

        let grid = "Field\tValue\none\ttwo\nthree\tfour"
        #expect(try parts(of: selection) == [grid, grid])
    }

    // Half a table is still a table: the cells that were caught keep their places.
    @Test func aPartlySelectedTableKeepsTheRowsItCaught() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: Self.table, selection: selection)
        defer { page.close() }

        // From the second cell of the header through to the first cell of the last row.
        selection.begin(in: page.views[1], at: page.views[1].point(atCharacter: 0))
        selection.extend(toWindowPoint: page.windowPoint(of: page.views[4], character: 5))

        #expect(selection.selectedText == "Value\none\ttwo\nthree")
    }

    // MARK: - Putting the selection away

    @Test func aPressOnThePagePutsTheSelectionAway() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        selection.selectAll()
        try #require(selection.selectedText != nil)
        selection.clearUnlessInsideText(atWindowPoint: page.pointBelowEverything)

        #expect(selection.selectedText == nil)
    }

    // A press on the words is the start of the next selection, not the end of this one,
    // and the block it landed in deals with it.
    @Test func aPressOnTheWordsLeavesTheSelectionAlone() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        selection.selectAll()
        selection.clearUnlessInsideText(
            atWindowPoint: page.windowPoint(of: page.views[1], character: 5))

        #expect(selection.selectedText != nil)
    }

    // The watcher covers the whole page, so if it ever took a click it would take every
    // click, and no block would see its own press.
    @Test func theWatcherNeverTakesAClick() {
        let view = TranscriptSelectionClearing.ClearingView()
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)

        #expect(view.hitTest(CGPoint(x: 100, y: 100)) == nil)
    }

    @Test func aRealPressOnThePageReachesTheWatcher() throws {
        let selection = TranscriptSelection()
        let page = try Page(selection: selection) {
            MarkdownProse(text: markdown, projectPath: "/tmp", textScale: 1) { segment in
                MarkdownCodeBlock(segment: segment)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(TranscriptSelectionClearing(selection: selection))
        }
        defer { page.close() }

        selection.selectAll()
        try #require(selection.selectedText != nil)
        page.press(at: page.pointBelowEverything)

        #expect(selection.selectedText == nil)
    }

    // Anything at all changing in the session pane asks every block on the page to
    // update. A block whose words did not move keeps the layout and the selected range
    // it already had, rather than being handed its text again and losing both.
    @Test func aRedrawThatChangesNothingLeavesASelectionStanding() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }
        try #require(page.views.count == 2)

        selection.begin(in: page.views[0], at: page.views[0].point(atCharacter: 10))
        selection.extend(toWindowPoint: page.windowPoint(of: page.views[1], character: 12))
        let before = try parts(of: selection)

        page.redrawUnchanged(markdown: markdown)

        #expect(try parts(of: selection) == before)
    }

    // The other half of the same bargain: a block that really was rewritten still takes
    // the new words, which is what a streaming turn depends on.
    @Test func aRedrawWithNewWordsStillReachesTheBlock() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }
        try #require(page.views.count == 2)

        let rewritten = [Self.first, "A middle paragraph with different words in it.", Self.third]
            .joined(separator: "\n\n")
        page.redrawUnchanged(markdown: rewritten)

        selection.selectAll()
        #expect(try parts(of: selection).contains("A middle paragraph with different words in it."))
        #expect(try parts(of: selection).contains(Self.second) == false)
    }

    // MARK: - Blocks sharing a text view

    // Scrolling costs the whole view tree on every frame, so a transcript's paragraphs
    // are drawn together rather than one text view each.
    @Test func adjacentParagraphsShareOneTextView() throws {
        let selection = TranscriptSelection()
        let fourth = "A fourth paragraph so the run has something to gather."
        let page = try Page(markdown: markdown + "\n\n" + fourth, selection: selection)
        defer { page.close() }

        // Three gathered, and the last left on its own.
        #expect(page.views.count == 2)
        #expect(page.views[0].string == [Self.first, Self.second, Self.third].joined(separator: "\n"))
        #expect(page.views[1].string == fourth)
    }

    // The gap between blocks is drawn rather than typed, so the blank line a reader sees
    // has to be put back on the way to the clipboard.
    @Test func sharedParagraphsStillCopyWithABlankLineBetweenThem() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }

        selection.selectAll()

        #expect(try #require(selection.selectedText)
            == [Self.first, Self.second, Self.third].joined(separator: "\n\n"))
    }

    // A heading reads as a heading whether or not it has a view to itself.
    @Test func aHeadingKeepsItsOwnTypeInsideASharedView() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: "\(Self.first)\n\n## A heading\n\n\(Self.second)\n\n\(Self.third)",
                            selection: selection)
        defer { page.close() }

        let view = try #require(page.views.first)
        let storage = try #require(view.textStorage)
        let heading = try #require(view.string.range(of: "A heading"))
        let at = view.string.distance(from: view.string.startIndex, to: heading.lowerBound)

        let headingFont = try #require(storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        let bodyFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(headingFont.pointSize > bodyFont.pointSize)

        // The air above a heading belongs to the heading's line, not to the newlines
        // inside the paragraph before it.
        let style = try #require(storage.attribute(.paragraphStyle, at: at,
                                                   effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.paragraphSpacingBefore > 0)
        let opening = try #require(storage.attribute(.paragraphStyle, at: 0,
                                                     effectiveRange: nil) as? NSParagraphStyle)
        #expect(opening.paragraphSpacingBefore == 0)
    }

    // A table brings cells of its own, so it cannot join a run and splits the prose
    // around it into two.
    @Test func aTableBreaksTheRunOfProseAroundIt() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: "\(Self.first)\n\n\(Self.second)\n\n\(Self.table)\n\n\(Self.third)",
                            selection: selection)
        defer { page.close() }

        // Two paragraphs together, six table cells, then the closing paragraph.
        #expect(page.views.count == 8)
        #expect(page.views[0].string == [Self.first, Self.second].joined(separator: "\n"))
        #expect(page.views.last?.string == Self.third)
    }

    // A streaming turn rewrites its last block many times a second. It is left out of the
    // run so that rewriting it does not rebuild, and clear the selection in, everything
    // above it.
    @Test func rewritingTheLastBlockLeavesASelectionAboveItStanding() throws {
        let selection = TranscriptSelection()
        let page = try Page(markdown: markdown, selection: selection)
        defer { page.close() }
        try #require(page.views.count == 2)

        selection.begin(in: page.views[0], at: page.views[0].point(atCharacter: 0))
        selection.extend(toWindowPoint: page.windowPoint(of: page.views[0],
                                                         character: Self.first.count))
        let before = try parts(of: selection)

        page.redrawUnchanged(markdown: markdown + " Still being written.")

        #expect(try parts(of: selection) == before)
    }

    // Blocks drawn together must take exactly the room they took apart, or the page
    // silently reflows the day a run happens to gather one block more.
    @Test func sharingATextViewLeavesThePageTheSameHeight() throws {
        let selection = TranscriptSelection()
        let body = [Self.first, "## A heading", Self.second, Self.third,
                    "A fifth paragraph to make the run worth gathering."]
            .joined(separator: "\n\n")

        let shared = try Page(markdown: body, selection: TranscriptSelection())
        defer { shared.close() }
        let apart = try Page(markdown: body, selection: selection, separateBlocks: true)
        defer { apart.close() }

        try #require(shared.views.count < apart.views.count)
        #expect(abs(shared.contentHeight - apart.contentHeight) < 1)
    }

    private func parts(of selection: TranscriptSelection) throws -> [String] {
        try #require(selection.selectedText).components(separatedBy: "\n\n")
    }
}

// A hosted run of prose in a real window, since the selection orders its views by where
// they sit on screen and ignores any that no window is showing.
@MainActor
private struct Page {
    let window: NSWindow
    let views: [NSTextView]
    private let host: NSHostingView<AnyView>
    private let dress: (AnyView) -> AnyView
    private var separateBlocks = false

    init(markdown: String,
         selection: TranscriptSelection,
         openURL: @escaping (URL) -> Void = { _ in },
         separateBlocks: Bool = false) throws {
        try self.init(selection: selection, openURL: openURL) {
            Page.prose(markdown, separateBlocks: separateBlocks)
        }
        self.separateBlocks = separateBlocks
    }

    // Both the first draw and every redraw go through this, so a redraw hands SwiftUI
    // the same shape of view and it keeps the text views rather than building new ones.
    @ViewBuilder
    static func prose(_ markdown: String, separateBlocks: Bool) -> some View {
        if separateBlocks {
            // The same blocks, one view each, to measure the gathered page against.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(MarkdownBlock.parse(markdown)) { block in
                    MarkdownBlockView(block: block, projectPath: "/tmp", textScale: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownProse(text: markdown, projectPath: "/tmp", textScale: 1) { segment in
                MarkdownCodeBlock(segment: segment)
            }
        }
    }

    var contentHeight: CGFloat {
        window.contentView?.fittingSize.height ?? 0
    }

    init<Content: View>(selection: TranscriptSelection,
                        openURL: @escaping (URL) -> Void = { _ in },
                        @ViewBuilder content: () -> Content) throws {
        dress = { view in
            AnyView(view
                .environment(TooltipPresenter())
                .environment(\.transcriptSelection, selection)
                .environment(\.openURL, OpenURLAction { url in
                    openURL(url)
                    return .handled
                }))
        }
        let content = dress(AnyView(content()))

        let host = NSHostingView(rootView: content)
        self.host = host
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 400)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        views = host.descendants
            .compactMap { $0 as? NSTextView }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    // Well clear of the last block, so nothing but the page itself is under it.
    var pointBelowEverything: CGPoint {
        guard let last = views.last else { return .zero }
        let frame = last.convert(last.bounds, to: nil)
        return CGPoint(x: frame.midX, y: frame.minY - 60)
    }

    // Through the application rather than the window, since that is what a local event
    // monitor is watching.
    func press(at windowPoint: CGPoint) {
        NSApp.sendEvent(event(.leftMouseDown, at: windowPoint, time: 0))
        NSApp.sendEvent(event(.leftMouseUp, at: windowPoint, time: 0.1))
    }

    func windowPoint(of view: NSTextView, character: Int) -> CGPoint {
        view.convert(view.point(atCharacter: character), to: nil)
    }

    // What a redraw of the pane does to the blocks: SwiftUI updates every text view,
    // whether or not the words in it moved.
    func redraw<Content: View>(@ViewBuilder content: () -> Content) {
        host.rootView = dress(AnyView(content()))
        host.layoutSubtreeIfNeeded()
    }

    func redrawUnchanged(markdown: String) {
        redraw { Page.prose(markdown, separateBlocks: separateBlocks) }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    func drag(from start: (view: NSTextView, character: Int),
              to end: (view: NSTextView, character: Int)) {
        let origin = windowPoint(of: start.view, character: start.character)
        let target = windowPoint(of: end.view, character: end.character)
        window.sendEvent(event(.leftMouseDown, at: origin, time: 0))
        // A press only becomes a drag once it has moved far enough to mean one, so the
        // first step is deliberately past that distance.
        window.sendEvent(event(.leftMouseDragged, at: midpoint(origin, target), time: 0.1))
        window.sendEvent(event(.leftMouseDragged, at: target, time: 0.2))
        window.sendEvent(event(.leftMouseUp, at: target, time: 0.3))
    }

    func click(_ view: NSTextView, atCharacter character: Int) {
        let point = windowPoint(of: view, character: character)
        window.sendEvent(event(.leftMouseDown, at: point, time: 0))
        window.sendEvent(event(.leftMouseUp, at: point, time: 0.1))
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, time: TimeInterval) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
}

private extension NSTextView {
    // The blocks draw on a clear background, so before a selection only the glyphs
    // cover any pixels and a highlight behind them stands out as a large jump.
    func paintedPixels() -> Int {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return 0 }
        cacheDisplay(in: bounds, to: rep)
        var painted = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if colour.alphaComponent > 0.05 { painted += 1 }
            }
        }
        return painted
    }

    func characterIndex(of substring: String) -> Int {
        ((textStorage?.string ?? "") as NSString).range(of: substring).location
    }

    // A block is laid out across the full width of the page while its text may only
    // fill part of the first line, so a point has to come from the glyphs. Aiming at
    // the near quarter of a character puts the insertion point in front of it.
    func point(atCharacter index: Int) -> CGPoint {
        guard let layoutManager, let textContainer else { return .zero }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                              actualCharacterRange: nil)
        let box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = textContainerOrigin
        return CGPoint(x: box.minX + box.width * 0.25 + origin.x, y: box.midY + origin.y)
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
