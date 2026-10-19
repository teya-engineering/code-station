import CodeStationCore
import Foundation
import Testing
import TerminalTranscript

// The viewport shows a window of the rendered transcript. Each window is checked against
// a slice of the whole transcript rendered at once, which is what the reader would see
// if the terminal were tall enough.
struct TranscriptViewportTests {
    private let width = 24
    private let height = 5

    private func conversation(_ count: Int) -> [RemoteMessage] {
        (0..<count).map { index in
            index.isMultiple(of: 2)
                ? prompt("Question number \(index) asked here", id: "m\(index)")
                : answer("Answer number \(index), which wraps onto a second line", id: "m\(index)")
        }
    }

    private func whole(_ messages: [RemoteMessage], width: Int? = nil) -> [String] {
        TranscriptRenderer.lines(for: messages, width: width ?? self.width).map(\.text)
    }

    private func texts(_ lines: [StyledLine]) -> [String] { lines.map(\.text) }

    @Test func opensFollowingTheBottom() {
        let messages = conversation(30)
        var viewport = TranscriptViewport()

        #expect(texts(viewport.window(of: messages, width: width, height: height))
                == Array(whole(messages).suffix(height)))
        #expect(viewport.isFollowing)
    }

    @Test func aShortTranscriptIsShownWhole() {
        let messages = conversation(1)
        var viewport = TranscriptViewport()

        #expect(texts(viewport.window(of: messages, width: width, height: 10)) == whole(messages))
        #expect(viewport.isFollowing)
        viewport.scroll(by: -3)
        #expect(texts(viewport.window(of: messages, width: width, height: 10)) == whole(messages))
        #expect(viewport.isFollowing)
    }

    @Test func newOutputIsFollowedWhileAtTheBottom() {
        var messages = conversation(30)
        var viewport = TranscriptViewport()
        _ = viewport.window(of: messages, width: width, height: height)

        messages.append(answer("A brand new answer", id: "new"))

        #expect(texts(viewport.window(of: messages, width: width, height: height)).last == "A brand new answer")
    }

    // Scrolling up stops the follow: new output lands below without moving what is
    // being read.
    @Test func scrollingUpStopsFollowingAndHoldsThePlace() {
        var messages = conversation(30)
        var viewport = TranscriptViewport()
        _ = viewport.window(of: messages, width: width, height: height)

        viewport.scroll(by: -3)
        let all = whole(messages)
        let held = Array(all[(all.count - height - 3)..<(all.count - 3)])
        #expect(texts(viewport.window(of: messages, width: width, height: height)) == held)
        #expect(!viewport.isFollowing)

        messages.append(answer("A brand new answer", id: "new"))
        #expect(texts(viewport.window(of: messages, width: width, height: height)) == held)
        #expect(!viewport.isFollowing)
    }

    @Test func returningToTheBottomResumesFollowing() {
        var messages = conversation(30)
        var viewport = TranscriptViewport()
        _ = viewport.window(of: messages, width: width, height: height)
        viewport.scroll(by: -10)
        _ = viewport.window(of: messages, width: width, height: height)

        viewport.scroll(by: 10)
        #expect(texts(viewport.window(of: messages, width: width, height: height))
                == Array(whole(messages).suffix(height)))
        #expect(viewport.isFollowing)

        viewport.scroll(by: -4)
        _ = viewport.window(of: messages, width: width, height: height)
        viewport.scrollToBottom()
        messages.append(answer("A brand new answer", id: "new"))
        #expect(texts(viewport.window(of: messages, width: width, height: height)).last == "A brand new answer")
        #expect(viewport.isFollowing)
    }

    @Test func scrollsByLineAndPageFromTheTop() {
        let messages = conversation(30)
        let all = whole(messages)
        var viewport = TranscriptViewport()
        _ = viewport.window(of: messages, width: width, height: height)

        viewport.scrollToTop()
        #expect(texts(viewport.window(of: messages, width: width, height: height)) == Array(all[0..<5]))

        viewport.scroll(by: 7)
        #expect(texts(viewport.window(of: messages, width: width, height: height)) == Array(all[7..<12]))

        // A page keeps one line of the last one for context.
        viewport.scrollPage(by: 1)
        #expect(texts(viewport.window(of: messages, width: width, height: height)) == Array(all[11..<16]))

        viewport.scrollPage(by: -1)
        #expect(texts(viewport.window(of: messages, width: width, height: height)) == Array(all[7..<12]))

        // Scrolling above the top stops at the top.
        viewport.scroll(by: -100)
        #expect(texts(viewport.window(of: messages, width: width, height: height)) == Array(all[0..<5]))
        #expect(!viewport.isFollowing)
    }

    @Test func aResizeReflowsTheTranscript() {
        let messages = conversation(30)
        var viewport = TranscriptViewport()
        _ = viewport.window(of: messages, width: 40, height: height)

        #expect(texts(viewport.window(of: messages, width: 12, height: 8))
                == Array(whole(messages, width: 12).suffix(8)))
        #expect(viewport.isFollowing)
    }

    // A message that changes is drawn again; the rest come from what was drawn before.
    @Test func aChangedMessageIsDrawnAgain() {
        var messages = conversation(4)
        var viewport = TranscriptViewport()
        _ = viewport.window(of: messages, width: width, height: height)

        messages[3] = answer("Rewritten", id: "m3")

        #expect(texts(viewport.window(of: messages, width: width, height: height)).last == "Rewritten")
    }

    // Only the window is drawn, so a long transcript opens as fast as a short one.
    @Test func aLongTranscriptOpensQuickly() {
        let messages = conversation(20_000)
        var viewport = TranscriptViewport()
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            _ = viewport.window(of: messages, width: 80, height: 50)
            viewport.scrollToTop()
            _ = viewport.window(of: messages, width: 80, height: 50)
        }

        #expect(elapsed < .milliseconds(500))
    }

    // The reader opens and closes tool calls; the message holding one is drawn again, the
    // rest come from what was drawn before.
    @Test func openingAToolCallRedrawsItsMessage() {
        let tool = RemoteTool(id: "t", name: "Bash", argument: "ls", input: #"{"command":"ls"}"#,
                              result: "a.swift\nb.swift")
        let messages = conversation(4) + [answer(blocks: [.init(kind: "tools", tools: [tool])], id: "tools")]
        var viewport = TranscriptViewport()
        _ = viewport.window(of: messages, width: width, height: height)

        let open = viewport.window(of: messages, width: width, height: height, expanded: ["t"])
        #expect(texts(open) == Array(TranscriptRenderer.lines(for: messages, width: width, expanded: ["t"])
                                       .map(\.text).suffix(height)))
        #expect(texts(open).suffix(3) == ["  $ ls", "  a.swift", "  b.swift"])

        let closed = viewport.window(of: messages, width: width, height: height)
        #expect(texts(closed) == Array(whole(messages).suffix(height)))
    }

    // Markdown and highlighting cost more to draw than plain prose, and still only the
    // window is drawn.
    @Test func aLongRichTranscriptOpensQuickly() {
        let reply = """
            ## Result
            Some **bold** text with `code` and [a link](https://example.com).
            - one
            - two
            ```swift
            let value = compute(1, "two") // three
            ```
            """
        let messages = (0..<20_000).map { answer(reply, id: "r\($0)") }
        var viewport = TranscriptViewport()
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            _ = viewport.window(of: messages, width: 80, height: 50)
            viewport.scrollToTop()
            _ = viewport.window(of: messages, width: 80, height: 50)
            for _ in 0..<20 {
                viewport.scrollPage(by: 1)
                _ = viewport.window(of: messages, width: 80, height: 50)
            }
        }

        #expect(elapsed < .milliseconds(500))
    }
}
