import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct TranscriptFindTests {
    private let first = ChatMessage(role: .user, text: "Please rename the Parser")
    private let second = ChatMessage(role: .assistant,
                                     text: "The parser is renamed. The PARSER tests pass.",
                                     thinking: [ThinkingSegment(text: "Where is the parser used?")])
    private let third = ChatMessage(role: .assistant, text: "Nothing else to do.")

    private var messages: [ChatMessage] { [first, second, third] }

    @Test func findsEveryMatchInReadingOrderAcrossMessages() {
        let result = TranscriptSearch.search("parser", in: messages)

        #expect(result.matches == [
            TranscriptFindMatch(messageID: first.id, occurrence: 0),
            TranscriptFindMatch(messageID: second.id, occurrence: 0),
            TranscriptFindMatch(messageID: second.id, occurrence: 1),
            TranscriptFindMatch(messageID: second.id, occurrence: 2)
        ])
        #expect(!result.hasMore)
    }

    @Test func leavesToolCallsOut() {
        var message = ChatMessage(role: .assistant, text: "Done.")
        message.tools = [ToolUse(id: "1", name: "Bash", input: "grep parser")]

        #expect(TranscriptSearch.search("parser", in: [message]).matches.isEmpty)
    }

    @Test func codeAndPlainMessagesKeepLiteralMarkdownCharacters() {
        let code = "```text\n**parser**\n```"
        let messages = [
            ChatMessage(role: .user, text: code),
            ChatMessage(role: .assistant, text: code),
            ChatMessage(role: .system, text: "**parser**"),
            ChatMessage(role: .instructions, text: "**parser**"),
            ChatMessage(role: .assistant, text: "Done.",
                        thinking: [ThinkingSegment(text: "**parser**")])
        ]

        #expect(TranscriptSearch.search("**parser**", in: messages).matches.count == 5)
        #expect(TranscriptSearch.search("```", in: messages).matches.isEmpty)
    }

    @Test func anEmptyQueryHasNoMatches() {
        #expect(TranscriptSearch.search("", in: messages) == TranscriptFindResult())
    }

    @Test func stopsAtTheMatchLimit() {
        let text = String(repeating: "a", count: FileFind.matchLimit / 2 + 1)
        let many = [ChatMessage(role: .user, text: text), ChatMessage(role: .user, text: text)]

        let result = TranscriptSearch.search("a", in: many)

        #expect(result.matches.count == FileFind.matchLimit)
        #expect(result.hasMore)
    }

    @Test func aSelectionSearchesForItsFirstLineWithText() {
        #expect(TranscriptSearch.query(fromSelection: "\n  rename the parser  \nsecond") == "rename the parser")
        #expect(TranscriptSearch.query(fromSelection: " \n\n ") == nil)
        #expect(TranscriptSearch.query(fromSelection: String(repeating: "x", count: 500))?.count == 200)
    }

    @Test func aNewSearchStartsFromTheNewestMatch() {
        let find = TranscriptFind()
        find.open(query: "parser", in: messages)

        #expect(find.currentMatch == TranscriptFindMatch(messageID: second.id, occurrence: 2))
        #expect(find.summary == "4 of 4")
    }

    @Test func movingWrapsAroundBothEnds() {
        let find = TranscriptFind()
        find.open(query: "parser", in: messages)

        find.move(by: 1)
        #expect(find.currentMatch == TranscriptFindMatch(messageID: first.id, occurrence: 0))
        find.move(by: -1)
        #expect(find.currentMatch == TranscriptFindMatch(messageID: second.id, occurrence: 2))
    }

    @Test func everyMoveAsksThePaneToScroll() {
        let find = TranscriptFind()
        find.open(query: "parser", in: messages)
        let opened = find.jumpRequest

        find.move(by: 1)

        #expect(find.jumpRequest == opened + 1)
    }

    @Test func aClosedFindHasNoCurrentMatch() {
        let find = TranscriptFind()
        find.open(query: "parser", in: messages)
        find.close()

        #expect(find.currentMatch == nil)
    }

    @Test func reopeningSearchesTheConversationAsItIsNow() {
        let find = TranscriptFind()
        find.open(query: "parser", in: [first])
        find.close()

        find.open(in: messages)

        #expect(find.result.matches.count == 4)
    }

    @Test func onlyFoldedTextInTheCurrentMessageOpens() {
        let find = TranscriptFind()
        find.open(query: "parser", in: messages)

        #expect(find.reveals("Where is the parser used?", in: second.id))
        #expect(!find.reveals("Nothing about it", in: second.id))
        #expect(!find.reveals("the parser again", in: first.id))
        #expect(!find.reveals("the parser again", in: nil))
    }

    @Test func aGrowingConversationKeepsTheCurrentMatch() {
        let find = TranscriptFind()
        find.open(query: "parser", in: messages)
        find.move(by: 1)

        find.refresh(in: messages + [ChatMessage(role: .assistant, text: "One more parser.")])

        #expect(find.currentMatch == TranscriptFindMatch(messageID: first.id, occurrence: 0))
        #expect(find.result.matches.count == 5)
    }

    @Test func theSummaryCountsFromOne() {
        #expect(FindSummary.text(query: "", matchCount: 0, hasMore: false, selection: 0) == "")
        #expect(FindSummary.text(query: "x", matchCount: 0, hasMore: false, selection: 0) == "No matches")
        #expect(FindSummary.text(query: "x", matchCount: 3, hasMore: false, selection: 1) == "2 of 3")
        #expect(FindSummary.text(query: "x", matchCount: 3, hasMore: true, selection: 0) == "1 of 3+")
    }
}

// The same find, drawn: real message views in a window, so the text views have to sign
// up with the find and paint what it found.
@MainActor
struct TranscriptFindPageTests {
    @Test(arguments: [
        "# Rename the **parser**",
        "- Rename the **parser**",
        "> Rename the **parser**",
        "| Action |\n| --- |\n| Rename the **parser** |"
    ])
    func formattedBlockMatchesAgreeWithTheirHighlights(text: String) throws {
        let message = ChatMessage(role: .assistant, text: text)
        let find = TranscriptFind()
        let page = FindPage(messages: [message], find: find)
        defer { page.close() }

        find.open(query: "Rename the parser", in: [message])

        #expect(find.result.matches.count == 1)
        let placed = try #require(find.placeCurrent())
        #expect((placed.view.string as NSString).substring(with: placed.range) == "Rename the parser")
    }

    @Test(arguments: [MessageRole.user, .assistant])
    func aSelectedPhraseAcrossInlineFormattingCanBeFound(role: MessageRole) throws {
        let message = ChatMessage(role: role,
                                  text: "Please **rename** the [parser](https://example.com/parser).")
        let find = TranscriptFind()
        let page = FindPage(messages: [message], find: find)
        defer { page.close() }

        find.open(query: "rename the parser", in: [message])

        #expect(find.summary == "1 of 1")
        let placed = try #require(find.placeCurrent())
        #expect((placed.view.string as NSString).substring(with: placed.range) == "rename the parser")
        #expect(find.highlights(in: placed.view).current == placed.range)

        find.search("parser", in: [message])
        #expect(find.result.matches.count == 1)
        find.search("example.com", in: [message])
        #expect(find.result.matches.isEmpty)
    }

    @Test func everyDrawnMatchIsHighlightedAndTheCurrentOneIsPlaced() async throws {
        let prompt = ChatMessage(role: .user, text: "Please rename the Parser")
        let answer = ChatMessage(role: .assistant, text: "The parser is renamed. The PARSER tests pass.")
        let find = TranscriptFind()
        let page = FindPage(messages: [prompt, answer], find: find)
        defer { page.close() }

        find.open(query: "parser", in: [prompt, answer])

        let placed = try #require(find.placeCurrent())
        #expect((placed.view.string as NSString).substring(with: placed.range) == "PARSER")
        #expect(find.highlights(in: placed.view).current == placed.range)
        #expect(find.highlights(in: placed.view).all.count == 2)

        let promptView = try #require(page.textViews.first { $0.string.contains("Please rename") })
        #expect(find.highlights(in: promptView).all.count == 1)
        #expect(find.highlights(in: promptView).current == nil)
    }

    @Test func foldedThinkingOpensWhenTheCurrentMatchIsInsideIt() async throws {
        let answer = ChatMessage(role: .assistant, text: "Done.",
                                 thinking: [ThinkingSegment(text: "Where is the parser used?")])
        let find = TranscriptFind()
        let page = FindPage(messages: [answer], find: find)
        defer { page.close() }
        #expect(!page.textViews.contains { $0.string.contains("parser") })

        find.open(query: "parser", in: [answer])

        #expect(await waitUntil(timeout: .seconds(5)) {
            page.layout()
            return find.currentIsFullyDrawn
        })
        let placed = try #require(find.placeCurrent())
        #expect(placed.view.string.contains("Where is the parser used?"))
    }

    @Test func closingFindTakesTheHighlightsAway() throws {
        let answer = ChatMessage(role: .assistant, text: "The parser is renamed.")
        let find = TranscriptFind()
        let page = FindPage(messages: [answer], find: find)
        defer { page.close() }
        let view = try #require(page.textViews.first)

        find.open(query: "parser", in: [answer])
        #expect(find.highlights(in: view).all.count == 1)

        find.close()
        #expect(find.highlights(in: view).all.isEmpty)
    }
}

@MainActor
private struct FindPage {
    let window: NSWindow
    private let host: NSHostingView<AnyView>

    init(messages: [ChatMessage], find: TranscriptFind) {
        let content = VStack(alignment: .leading, spacing: 16) {
            ForEach(messages) { message in
                MessageView(message: message, projectPath: "/tmp", textScale: 1, availableWidth: 800)
            }
        }
        .environment(TooltipPresenter())
        .environment(\.transcriptSelection, TranscriptSelection())
        .environment(\.transcriptFind, find)

        host = NSHostingView(rootView: AnyView(content))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        layout()
    }

    var textViews: [NSTextView] {
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        return all(host).compactMap { $0 as? NSTextView }
    }

    func layout() { host.layoutSubtreeIfNeeded() }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}
