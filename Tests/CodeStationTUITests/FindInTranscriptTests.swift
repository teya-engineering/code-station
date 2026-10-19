import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Getting back to something in a long transcript: finding text in it, as the GUI's
    // find bar does, and the agents indicator's jump to the agent it counts.
    @MainActor
    @Suite
    struct FindInTranscriptTests {

        // A long session with the given texts among thirty filler prompts, so that the
        // early ones are well off screen when the session opens at its bottom.
        private func longSession(_ texts: [Int: String] = [:]) async throws -> TUIHarness {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 24))
            let alpha = try tui.addProject("alpha")
            var messages: [ChatMessage] = []
            for index in 0..<30 {
                messages.append(ChatMessage(role: .user, text: texts[index] ?? "Filler prompt \(index)"))
            }
            messages.append(ChatMessage(role: .user, text: "Look into it", date: Date(timeIntervalSinceNow: -60)))
            try tui.addSession("Long talk", in: alpha, messages: messages)
            try await tui.start()
            await tui.press(.enter([]))
            return tui
        }

        @Test func slashFindsTextAndBringsItIntoView() async throws {
            let tui = try await longSession([2: "The secret word is pineapple"])
            defer { tui.tearDown() }
            #expect(!tui.contains("pineapple"), "\(tui.text)")

            await tui.press(.char("/", []))
            await tui.type("Pineapple")

            let match = try #require(tui.mainLine(containing: "secret word is pineapple"), "\(tui.text)")
            #expect(match.text.hasPrefix("»"), "\(match.text)")
            #expect(tui.frame.last?.text.contains("find: Pineapple") == true, "\(tui.text)")
            #expect(tui.frame.last?.text.contains("1 of 1") == true, "\(tui.text)")

            // Enter keeps the match and gives the keys back to the transcript; Esc closes.
            await tui.press(.enter([]))
            #expect(tui.mainLine(containing: "secret word is pineapple") != nil, "\(tui.text)")
            await tui.press(.escape)
            #expect(tui.frame.last?.text.contains("find:") == false, "\(tui.text)")
            #expect(tui.mainLine(containing: "secret word is pineapple")?.text.hasPrefix("»") == false)
        }

        // A search starts at the newest match; N steps to older ones and n to newer, going
        // round at the ends.
        @Test func nAndShiftNStepThroughTheMatches() async throws {
            let tui = try await longSession([1: "An apple early on", 25: "An apple later"])
            defer { tui.tearDown() }

            await tui.press(.char("/", []))
            await tui.type("apple")
            #expect(tui.mainLine(containing: "An apple later")?.text.hasPrefix("»") == true, "\(tui.text)")
            #expect(tui.frame.last?.text.contains("2 of 2") == true, "\(tui.text)")
            await tui.press(.enter([]))

            await tui.press(.char("N", []))

            #expect(tui.mainLine(containing: "An apple early on")?.text.hasPrefix("»") == true, "\(tui.text)")
            #expect(tui.frame.last?.text.contains("1 of 2") == true, "\(tui.text)")

            await tui.press(.char("n", []))

            #expect(tui.mainLine(containing: "An apple later")?.text.hasPrefix("»") == true, "\(tui.text)")
        }

        @Test func nothingFoundSaysSo() async throws {
            let tui = try await longSession()
            defer { tui.tearDown() }

            await tui.press(.char("f", .ctrl))
            await tui.type("zebra")

            #expect(tui.frame.last?.text.contains("No matches") == true, "\(tui.text)")
        }

        // `a` jumps to the agent the indicator counts and points at its call.
        @Test func aJumpsToTheAgentTheIndicatorCounts() async throws {
            let tui = try await longSession()
            defer { tui.tearDown() }
            // A failure counts when it came after the last prompt, as the GUI counts it.
            tui.store.append(ChatMessage(role: .assistant, tools: [ToolUse(
                id: "reviewer", name: "Task",
                input: #"{"subagent_type":"reviewer","description":"review the diff"}"#,
                result: "it broke", isError: true, startedAt: Date())]),
                             to: try #require(tui.store.sessions.first?.id))
            #expect(await waitUntil { tui.topBarText.contains("1 agent failed") }, "\(tui.topBarText)")
            #expect(tui.topBar[2].text.contains("a agents"), "\(tui.topBarText)")
            await tui.press(.char("g", []))
            #expect(tui.mainLine(containing: "✗") == nil, "\(tui.text)")

            await tui.press(.char("a", []))

            let pointed = try #require(tui.mainLine(containing: "✗"), "\(tui.text)")
            #expect(pointed.text.hasPrefix("▸"), "\(pointed.text)")
        }
    }
}
