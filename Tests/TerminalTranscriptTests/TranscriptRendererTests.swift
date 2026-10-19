import CodeStationCore
import Foundation
import Testing
import TerminalTranscript

// The renderer is checked the way a reader sees it: the exact lines that come out for a
// set of messages at a width, and the style each part of a line carries.
struct TranscriptRendererTests {

    // MARK: - Prose and wrapping

    @Test func proseWrapsAtWordsToTheWidth() {
        let lines = render([answer("The quick brown fox jumps over the lazy dog")], width: 16)

        #expect(lines.map(\.text) == ["The quick brown", "fox jumps over", "the lazy dog"])
        #expect(lines.allSatisfy { $0.spans.allSatisfy { $0.style == .plain } })
    }

    @Test func aWordLongerThanTheWidthIsBrokenAcrossLines() {
        let lines = render([answer("see abcdefghij now")], width: 4)

        #expect(lines.map(\.text) == ["see", "abcd", "efgh", "ij", "now"])
    }

    @Test func blankLinesInsideProseAreKeptAndEdgeOnesDropped() {
        let lines = render([answer("\n\nOne\n\nTwo\n")], width: 20)

        #expect(lines.map(\.text) == ["One", "", "Two"])
    }

    @Test func wideCharactersTakeTwoColumns() {
        let lines = render([answer("日本語のテキスト")], width: 6)

        #expect(lines.map(\.text) == ["日本語", "のテキ", "スト"])
    }

    // MARK: - Each kind of block

    @Test func aPromptIsMarkedAndItsLinesHangUnderIt() {
        let lines = render([prompt("Fix the login bug please")], width: 12)

        #expect(lines.map(\.text) == ["› Fix the", "  login bug", "  please"])
        #expect(lines.map { $0.spans.map(\.style) } == [[.userMarker, .user], [.plain, .user], [.plain, .user]])
    }

    @Test func thinkingIsDimmedBehindARule() {
        let message = answer(blocks: [.init(kind: "thinking", text: "Plan the change first")])

        let lines = render([message], width: 14)

        #expect(lines.map(\.text) == ["│ Plan the", "│ change first"])
        #expect(lines.map { $0.spans.map(\.style) } == [[.thinking, .thinking], [.thinking, .thinking]])
    }

    @Test func toolCallsAreOneLineSummariesMarkedByHowTheyWent() {
        let message = answer(blocks: [.init(kind: "tools", tools: [
            RemoteTool(id: "1", name: "Bash", argument: "swift build", result: "ok"),
            RemoteTool(id: "2", name: "Edit", argument: "Sources/App.swift", added: 3, removed: 1, result: "ok"),
            RemoteTool(id: "3", name: "Read", argument: "Package.swift", isRunning: true),
            RemoteTool(id: "4", name: "Bash", argument: "false", result: "exit 1", isError: true),
            RemoteTool(id: "5", name: "TodoWrite", argument: "", result: "ok"),
        ])])

        let lines = render([message], width: 40)

        #expect(lines.map(\.text) == [
            "● Bash · swift build",
            "● Edit · Sources/App.swift +3 -1",
            "○ Read · Package.swift",
            "✗ Bash · false",
            "● TodoWrite",
        ])
        #expect(lines[1].spans.map(\.style) == [.tool, .tool, .added, .removed])
        #expect(lines[2].spans.map(\.style) == [.toolRunning, .tool])
        #expect(lines[3].spans.map(\.style) == [.toolError, .tool])
        #expect(lines.map(\.source?.toolID) == ["1", "2", "3", "4", "5"])
    }

    @Test func aLongToolSummaryIsCutRatherThanWrapped() {
        let message = answer(blocks: [.init(kind: "tools", tools: [
            RemoteTool(id: "1", name: "Bash", argument: "swift test --filter TranscriptRendererTests", result: "ok"),
        ])])

        let lines = render([message], width: 20)

        #expect(lines.map(\.text) == ["● Bash · swift test…"])
    }

    // Blocks keep the order the turn happened in, with a blank line between them, and a
    // blank line separates one message from the next.
    @Test func blocksAndMessagesAreSeparatedByBlankLines() {
        let reply = answer(blocks: [
            .init(kind: "thinking", text: "Look first"),
            .init(kind: "prose", text: "Looking."),
            .init(kind: "tools", tools: [RemoteTool(id: "1", name: "Read", argument: "a.swift", result: "ok"),
                                         RemoteTool(id: "2", name: "Read", argument: "b.swift", result: "ok")]),
            .init(kind: "prose", text: "\n\nDone."),
        ])

        let lines = render([prompt("Go"), reply], width: 30)

        #expect(lines.map(\.text) == [
            "› Go", "",
            "│ Look first", "",
            "Looking.", "",
            "● Read · a.swift", "● Read · b.swift", "",
            "Done.",
        ])
    }

    @Test func systemNotesAreDimmed() {
        let note = RemoteMessage(id: "n", role: "system", text: "Context cleared", date: .distantPast,
                                 blocks: [.init(kind: "prose", text: "Context cleared")])

        let lines = render([note], width: 30)

        #expect(lines.map(\.text) == ["Context cleared"])
        #expect(lines.map { $0.spans.map(\.style) } == [[.notice]])
    }

    @Test func attachmentsAreListedUnderThePrompt() {
        let message = RemoteMessage(id: "u", role: "user", text: "Look at this", date: .distantPast,
                                    attachments: ["screen.png"], blocks: [])

        let lines = render([message], width: 30)

        #expect(lines.map(\.text) == ["› Look at this", "  [screen.png]"])
    }

    // MARK: - Very narrow widths

    // Once a marker leaves no room for text it is dropped, and the text still wraps to
    // whatever columns there are, down to one.
    @Test func veryNarrowWidthsDropTheMarkerAndStillWrap() {
        #expect(render([prompt("hi there")], width: 2).map(\.text) == ["hi", "th", "er", "e"])
        #expect(render([answer("abc")], width: 1).map(\.text) == ["a", "b", "c"])
        #expect(render([answer("abc")], width: 0).map(\.text) == ["a", "b", "c"])
        let tool = answer(blocks: [.init(kind: "tools", tools: [
            RemoteTool(id: "1", name: "Bash", argument: "ls", result: "ok"),
        ])])
        #expect(render([tool], width: 3).map(\.text) == ["● …"])
        #expect(render([tool], width: 1).map(\.text) == ["…"])
    }

    @Test func noLineIsWiderThanTheWidth() {
        let messages = [
            prompt("A prompt with a fairly long line of text in it"),
            answer(blocks: [
                .init(kind: "thinking", text: "Thinking about 日本語 and more words"),
                .init(kind: "prose", text: "An answer, with supercalifragilisticexpialidocious words."),
                .init(kind: "tools", tools: [RemoteTool(id: "1", name: "Bash", argument: "make all", result: "ok")]),
            ]),
        ]
        // From two columns up: a wide character cannot fit in one.
        for width in 2...30 {
            let lines = render(messages, width: width)
            #expect(lines.filter { TerminalColumns.width(of: $0.text) > width }.map(\.text) == [], "width \(width)")
        }
    }

    // MARK: - Themes

    @Test func aThemeTurnsStylesIntoEscapeCodes() {
        let lines = render([prompt("Go"),
                            answer(blocks: [.init(kind: "thinking", text: "Hmm"),
                                            .init(kind: "tools", tools: [
                                                RemoteTool(id: "1", name: "Edit", argument: "a", added: 2, removed: 1,
                                                           result: "ok")])])],
                           width: 20)

        #expect(lines.map { TranscriptTheme.basic.encode($0) } == [
            "\u{1B}[1;36m› \u{1B}[0m\u{1B}[1mGo\u{1B}[0m",
            "",
            "\u{1B}[2;3m│ \u{1B}[0m\u{1B}[2;3mHmm\u{1B}[0m",
            "",
            "\u{1B}[36m● \u{1B}[0m\u{1B}[36mEdit · a\u{1B}[0m\u{1B}[32m +2\u{1B}[0m\u{1B}[31m -1\u{1B}[0m",
        ])
        // With no colour, the weight and dimming that need none are kept.
        #expect(lines.map { TranscriptTheme.monochrome.encode($0) } == [
            "\u{1B}[1m› \u{1B}[0m\u{1B}[1mGo\u{1B}[0m",
            "",
            "\u{1B}[2;3m│ \u{1B}[0m\u{1B}[2;3mHmm\u{1B}[0m",
            "",
            "● Edit · a +2 -1",
        ])
    }

    // MARK: - Helpers

    private func render(_ messages: [RemoteMessage], width: Int) -> [StyledLine] {
        TranscriptRenderer.lines(for: messages, width: width)
    }
}

func prompt(_ text: String, id: String = UUID().uuidString) -> RemoteMessage {
    RemoteMessage(id: id, role: "user", text: text, date: .distantPast,
                  blocks: [.init(kind: "prose", text: text)])
}

func answer(_ text: String, id: String = UUID().uuidString) -> RemoteMessage {
    RemoteMessage(id: id, role: "assistant", text: text, date: .distantPast,
                  blocks: [.init(kind: "prose", text: text)])
}

func answer(blocks: [RemoteBlock], id: String = UUID().uuidString) -> RemoteMessage {
    RemoteMessage(id: id, role: "assistant", text: blocks.compactMap(\.text).joined(),
                  date: .distantPast, blocks: blocks)
}
