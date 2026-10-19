import CodeStationCore
import Foundation
import Testing
import TerminalTranscript

// What a reader copies off the transcript: a whole message as it was written, or one
// fenced code block. The line source under a line is what says which.
struct TranscriptCopyTests {
    private let reply = """
        Two steps.

        ```swift
        let a = 1
        \tprint(a)
        ```

        Then:

        ~~~
        swift build
        ~~~
        """

    @Test func everyLineOfACodeBlockSaysWhichBlockItIs() {
        let message = answer(reply, id: "m")
        let lines = TranscriptRenderer.lines(for: message, width: 40)

        #expect(lines.map(\.text) == ["Two steps.", "", "  let a = 1", "      print(a)", "",
                                      "Then:", "", "  swift build"])
        #expect(lines.map { $0.source?.code } == [nil, nil, 0, 0, nil, nil, nil, 1])
        #expect(lines.allSatisfy { $0.source?.messageID == "m" && $0.source?.block == 0 })
    }

    @Test func aCodeBlockIsCopiedAsItWasWritten() {
        let message = answer(reply, id: "m")
        let lines = TranscriptRenderer.lines(for: message, width: 40)

        #expect(TranscriptCopy.code(in: message, at: lines[3].source!) == "let a = 1\n\tprint(a)")
        #expect(TranscriptCopy.code(in: message, at: lines[7].source!) == "swift build")
        #expect(TranscriptCopy.code(in: message, at: lines[0].source!) == nil)
    }

    // A code block in a later prose block of a reply with tools in between.
    @Test func aCodeBlockAfterToolsIsFoundByItsBlock() {
        let message = answer(blocks: [
            RemoteBlock(kind: "prose", text: "Looking."),
            RemoteBlock(kind: "tools", tools: []),
            RemoteBlock(kind: "prose", text: "Run:\n\n```sh\nmake\n```"),
        ], id: "m")
        let lines = TranscriptRenderer.lines(for: message, width: 40)
        let codeLine = try! #require(lines.first { $0.source?.code != nil })

        #expect(codeLine.text == "  make")
        #expect(TranscriptCopy.code(in: message, at: codeLine.source!) == "make")
    }

    // A reply is copied as the markdown it was written in: its prose, not its thinking
    // or its tool calls.
    @Test func aReplyIsCopiedAsItsProse() {
        let message = answer(blocks: [
            RemoteBlock(kind: "thinking", text: "Hmm."),
            RemoteBlock(kind: "prose", text: "First **part**."),
            RemoteBlock(kind: "tools", tools: []),
            RemoteBlock(kind: "prose", text: "Second part."),
        ])

        #expect(TranscriptCopy.text(of: message) == "First **part**.\n\nSecond part.")
    }

    @Test func aPromptOrAReplyWithoutBlocksIsCopiedAsItsText() {
        #expect(TranscriptCopy.text(of: prompt("Fix the\nlogin")) == "Fix the\nlogin")
        #expect(TranscriptCopy.text(of: answer("Done.")) == "Done.")
    }
}
