import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The top of the sidebar: the running count in the heading, and the Needs you stack
    // of sessions waiting on the person, each with why, in the order the GUI stacks them.
    @MainActor
    @Suite
    struct NeedsYouTests {

        private static let writeRequest = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/p/hello.txt","content":"hi"},"tool_use_id":"toolu_1"}}"#

        // A tool asking for permission leads the stack, a turn that finished while the
        // person was away follows, and a quiet session is not there. The stack sits
        // under the heading, above the tree.
        @Test func theStackListsWhatWaitsOnYouWithItsReasonInTheGUIsOrder() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30), agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '\(Self.writeRequest)'
            IFS= read -r answer
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Quiet", in: alpha, ago: 10)
            let done = try tui.addSession("Finished", in: alpha, ago: 60)
            let asking = try tui.addSession("Asking", in: alpha, ago: 3_600)
            tui.store.noteTurnEnded(for: done.id)
            try await tui.start()

            tui.runner.send("Write hello", sessionID: asking.id, store: tui.store)

            #expect(await waitUntil { tui.sidebarText.contains("permission · write") }, "\(tui.sidebarText)")
            let heading = try #require(tui.sidebarLine(containing: "NEEDS YOU"), "\(tui.sidebarText)")
            #expect(heading.text.contains("NEEDS YOU 2"), "\(heading.text)")
            #expect(heading.text.contains("Ctrl-A"), "\(heading.text)")
            let rows = tui.sidebarRows(of: ["NEEDS YOU 2", "! Asking", "permission · write", "! Finished",
                                            "finished while away", "■ alpha"])
            #expect(rows.allSatisfy { $0 != nil }, "\(tui.sidebarText)")
            let found = rows.compactMap { $0 }
            #expect(found == found.sorted(), "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "permission · write")?.style(of: "permission · write")?.foreground
                    == .basic(33))
            #expect(!tui.sidebar.prefix(found[5]).contains { $0.text.contains("Quiet") }, "\(tui.sidebarText)")
            tui.runner.stopAll()
        }

        // The heading counts the sessions running, in green, and says nothing when none is.
        @Test func theHeadingCountsTheRunningSessions() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            wait_for "$folder/release"
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let busy = try tui.addSession("Busy", in: alpha)
            try await tui.start()
            #expect(tui.sidebar.first?.text.contains("●") == false, "\(tui.sidebarText)")

            tui.runner.send("hello", sessionID: busy.id, store: tui.store)

            #expect(await waitUntil { tui.sidebar.first?.text.hasSuffix("● 1") == true }, "\(tui.sidebarText)")
            #expect(tui.sidebar.first?.style(of: "● 1")?.foreground == .basic(32))
            try Data().write(to: tui.scratch.path("release"))
            #expect(await waitUntil { tui.sidebar.first?.text.contains("●") == false }, "\(tui.sidebarText)")
        }

        // Enter on an entry opens its session; the jump key goes to the next session that
        // needs the person from wherever the keys are, and with none, to the first running.
        @Test func enterAndTheJumpKeyOpenWhatNeedsYou() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30), agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '\(Self.writeRequest)'
            IFS= read -r answer
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Quiet", in: alpha, ago: 10)
            let asking = try tui.addSession("Asking", in: beta, ago: 60)
            let done = try tui.addSession("Finished", in: beta, ago: 120)
            tui.store.noteTurnEnded(for: done.id)
            try await tui.start()
            tui.runner.send("Write hello", sessionID: asking.id, store: tui.store)
            #expect(await waitUntil { tui.sidebarText.contains("NEEDS YOU 2") }, "\(tui.sidebarText)")

            // The jump key opens the first, then the next.
            await tui.press(.char("a", .ctrl))
            #expect(await waitUntil { tui.mainText.contains("beta / Asking") }, "\(tui.mainText)")
            await tui.press(.char("a", .ctrl))
            #expect(await waitUntil { tui.mainText.contains("beta / Finished") }, "\(tui.mainText)")
            // Its card is revealed in the tree, its project unfolded, and once read it
            // leaves the stack.
            #expect(tui.sidebarLine(containing: "■ beta")?.text.hasSuffix("▾") == true, "\(tui.sidebarText)")
            #expect(await waitUntil { tui.sidebarText.contains("NEEDS YOU 1") }, "\(tui.sidebarText)")

            // Enter on an entry opens it: up from the top of the tree walks into the stack.
            await tui.press(.char("o", .ctrl), .char("g", []), .up([]))
            #expect(tui.sidebarLine(containing: "! Asking")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.mainText.contains("beta / Asking") }, "\(tui.mainText)")
            tui.runner.stopAll()
        }
    }
}
