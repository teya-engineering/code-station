import CodeStationCore
import Foundation
import Testing
import TerminalTranscript

// A tool call is one line until the reader opens it. The front end holds which calls are
// open and passes them in; the renderer draws what an open call did under its line.
struct TranscriptToolTests {

    private let bash = RemoteTool(id: "b", name: "Bash", argument: "swift build",
                                  input: #"{"command":"swift build\nswift test"}"#,
                                  result: "Build complete\nTests passed")

    @Test func aClosedCallIsItsOneLineAndAnOpenOneShowsWhatItRanAndWhatCameBack() {
        let message = answer(blocks: [.init(kind: "tools", tools: [bash])], id: "m")

        let closed = TranscriptRenderer.lines(for: message, width: 30)
        let open = TranscriptRenderer.lines(for: message, width: 30, expanded: ["b"])

        #expect(closed.map(\.text) == ["● Bash · swift build"])
        #expect(open.map(\.text) == [
            "● Bash · swift build",
            "  $ swift build",
            "    swift test",
            "  Build complete",
            "  Tests passed",
        ])
        #expect(Array(open[1].spans.prefix(2)) == [Span("  "), Span("$ ", .output)])
        #expect(open[3].spans == [Span("  "), Span("Build complete", .output)])
        // Every line of an open call points back at it, so a key on any of them finds it.
        #expect(open.allSatisfy { $0.source == LineSource(messageID: "m", block: 0, toolID: "b") })
    }

    @Test func onlyTheCallsNamedAreOpened() {
        let other = RemoteTool(id: "r", name: "Read", argument: "a.swift", result: "line")
        let message = answer(blocks: [.init(kind: "tools", tools: [bash, other])])

        let lines = TranscriptRenderer.lines(for: message, width: 30, expanded: ["r"])

        #expect(lines.map(\.text) == ["● Bash · swift build", "● Read · a.swift", "  line"])
    }

    // An edit's input is the change itself, so an open edit is its diff and nothing else.
    @Test func anOpenEditShowsItsDiff() {
        let edit = RemoteTool(id: "e", name: "Edit", argument: "a.swift", added: 2, removed: 1,
                              input: #"{"file_path":"/p/a.swift","old_string":"let a = 0\nlet a = 1","new_string":"let a = 0\nlet a = 2\nlet b = 3"}"#,
                              result: "ok")
        let message = answer(blocks: [.init(kind: "tools", tools: [edit])])

        let lines = TranscriptRenderer.lines(for: message, width: 30, expanded: ["e"])

        #expect(lines.map(\.text) == [
            "● Edit · a.swift +2 -1",
            "    let a = 0",
            "  - let a = 1",
            "  + let a = 2",
            "  + let b = 3",
        ])
        #expect(lines[1].spans == [Span("  "), Span("  let a = 0", .output)])
        #expect(lines[2].spans == [Span("  "), Span("- let a = 1", .removed)])
        #expect(lines[3].spans == [Span("  "), Span("+ let a = 2", .added)])
    }

    @Test func aFailedCallShowsItsErrorAndARunningOneSaysSo() {
        let failed = RemoteTool(id: "f", name: "Bash", argument: "false", input: #"{"command":"false"}"#,
                                result: "exit 1", isError: true)
        let running = RemoteTool(id: "r", name: "Read", argument: "a.swift", isRunning: true)
        let message = answer(blocks: [.init(kind: "tools", tools: [failed, running])])

        let lines = TranscriptRenderer.lines(for: message, width: 30, expanded: ["f", "r"])

        #expect(lines.map(\.text) == ["✗ Bash · false", "  $ false", "  exit 1", "○ Read · a.swift", "  running…"])
        #expect(lines[2].spans == [Span("  "), Span("exit 1", .outputError)])
        #expect(lines[4].spans == [Span("  "), Span("running…", .output)])
    }

    // Output keeps its spacing and is cut at the width. A long result shows its first
    // lines and says how many more there are.
    @Test func longOutputIsCutAtTheWidthAndAfterFortyLines() {
        let result = (1...43).map { "line \($0)" }.joined(separator: "\n")
        let read = RemoteTool(id: "r", name: "Read", argument: "a.txt", result: "a  b c\n" + result)
        let message = answer(blocks: [.init(kind: "tools", tools: [read])])

        let lines = TranscriptRenderer.lines(for: message, width: 8, expanded: ["r"])

        #expect(Array(lines.prefix(4).map(\.text)) == ["● Read …", "  a  b c", "  line 1", "  line 2"])
        #expect(lines[11].text == "  line 1")
        #expect(lines[12].text == "  0")
        #expect(lines.last?.text == "  … 4 m…")
        let wide = TranscriptRenderer.lines(for: message, width: 30, expanded: ["r"])
        #expect(wide.count == 1 + 40 + 1)
        #expect(wide.last?.text == "  … 4 more lines")
    }

    @Test func openCallsAcrossMessagesAreDrawnInTheWholeTranscript() {
        let first = answer(blocks: [.init(kind: "tools", tools: [bash])])
        let lines = TranscriptRenderer.lines(for: [prompt("Go"), first], width: 30, expanded: ["b"])

        #expect(lines.map(\.text) == ["› Go", "", "● Bash · swift build", "  $ swift build", "    swift test",
                                      "  Build complete", "  Tests passed"])
    }
}
