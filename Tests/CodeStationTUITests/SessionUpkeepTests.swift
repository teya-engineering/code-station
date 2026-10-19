@testable import CodeStationCore
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // Looking after a session from the TUI: from a session card's actions menu (pin, mark
    // read or unread, rename, regenerate the title, open a shell, delete with the impact
    // confirmation), and from the open session's menu (`m`): rewind or fork from a prompt,
    // continue after a failure or dismiss it, take back a queued prompt and ask for a recap,
    // with the suggested next prompt offered under the transcript.
    @MainActor
    @Suite
    struct SessionUpkeepTests {

        // Opens the actions menu of the sidebar row whose text holds `row`.
        private func openMenu(_ tui: TUIHarness, on row: String) async throws {
            await tui.press(.char("g", []))
            for _ in 0..<20 where tui.sidebarLine(containing: row)?.text.hasPrefix("▸") != true {
                await tui.press(.down([]))
            }
            try #require(tui.sidebarLine(containing: row)?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.char("a", []))
        }

        // Points the open menu at `entry` and chooses it.
        private func choose(_ tui: TUIHarness, _ entry: String) async throws {
            let target = try #require(tui.frame.firstIndex { $0.text.contains(entry) }, "\(tui.text)")
            let current = try #require(tui.frame.firstIndex { $0.text.hasPrefix("  ▸ ") }, "\(tui.text)")
            for _ in 0..<abs(target - current) { await tui.press(target > current ? .down([]) : .up([])) }
            await tui.press(.enter([]))
        }

        // Pin and Mark as unread change the card, and the menu then offers the way back;
        // Rename starts on the old title and saves what is typed.
        @Test func pinUnreadAndRenameFromTheCardsMenu() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            try await openMenu(tui, on: "Fix the login bug")
            try await choose(tui, "Pin")
            #expect(await waitUntil { tui.sidebarLine(containing: "Fix the login bug")?.text.contains("⚑") == true },
                    "\(tui.sidebarText)")
            #expect(tui.store.session(session.id)?.isPinned == true)
            try await openMenu(tui, on: "Fix the login bug")
            #expect(tui.contains("Unpin"), "\(tui.text)")
            try await choose(tui, "Unpin")
            #expect(await waitUntil { tui.store.session(session.id)?.isPinned == false })

            try await openMenu(tui, on: "Fix the login bug")
            try await choose(tui, "Mark as unread")
            #expect(await waitUntil { tui.sidebarLine(containing: "Fix the login bug")?.text.contains("●") == true },
                    "\(tui.sidebarText)")
            try await openMenu(tui, on: "Fix the login bug")
            try await choose(tui, "Mark as read")
            #expect(await waitUntil { tui.sidebarLine(containing: "Fix the login bug")?.text.contains("●") == false },
                    "\(tui.sidebarText)")

            try await openMenu(tui, on: "Fix the login bug")
            try await choose(tui, "Rename…")
            #expect(tui.frame[0].text == " Rename Fix the login bug", "\(tui.text)")
            #expect(tui.line(containing: " Fix the login bug") != nil, "\(tui.text)")
            await tui.type(" now")
            await tui.press(.enter([]))
            #expect(await tui.waitFor("Fix the login bug now"), "\(tui.text)")
            #expect(tui.store.session(session.id)?.title == "Fix the login bug now")
        }

        // Delete asks with what the station says goes and stays, then the card goes; the
        // session open in the main pane makes way for Home.
        @Test func deleteAsksWithTheImpactThenTheSessionGoes() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Fix the login bug", in: alpha)
            try tui.addSession("Keep me", in: alpha)
            try await tui.start()
            try await openMenu(tui, on: "Fix the login bug")
            try await choose(tui, "Open")
            #expect(await waitUntil { tui.topBarText.contains("Fix the login bug") }, "\(tui.text)")
            await tui.press(.escape)

            try await openMenu(tui, on: "Fix the login bug")
            try await choose(tui, "Delete session")
            #expect(tui.frame[0].text == " ■ alpha", "\(tui.text)")
            #expect(tui.frame[1].text == " Delete this session?", "\(tui.text)")
            #expect(tui.line(containing: "Conversation history")?.text.hasPrefix(" − ") == true, "\(tui.text)")
            #expect(tui.line(containing: "Project folder stays")?.text.hasPrefix(" ✓ ") == true, "\(tui.text)")
            #expect(tui.contains("Conversation history cannot be restored."), "\(tui.text)")
            #expect(tui.contains("[ Delete session ]"), "\(tui.text)")

            await tui.press(.enter([]))
            #expect(await waitUntil { tui.sidebarLine(containing: "Fix the login bug") == nil }, "\(tui.text)")
            #expect(tui.store.session(session.id) == nil)
            #expect(!tui.topBarText.contains("Fix the login bug"), "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Keep me") != nil, "\(tui.text)")
        }

        // Regenerate runs the title prompt on the agent; the new title shows on the card.
        // Open a shell hands the terminal to `$SHELL` in the session's folder.
        @Test func regenerateTheTitleAndOpenAShell() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Fix login retries"}]}}'
            printf '%s\\n' '{"type":"result","is_error":false,"result":"Fix login retries"}'
            """)
            defer { tui.tearDown() }
            tui.environment = ["SHELL": "/bin/sh"]
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Old title", in: alpha, messages: [
                ChatMessage(role: .user, text: "Please fix the login retry"),
                ChatMessage(role: .assistant, text: "Done"),
            ])
            tui.store.setAgentSessionID("claude-1", agent: .claudeCode, for: session.id)
            try await tui.start()

            try await openMenu(tui, on: "Old title")
            try await choose(tui, "Regenerate session title")
            #expect(await tui.waitFor("Fix login retries"), "\(tui.text)")

            try await openMenu(tui, on: "Fix login retries")
            try await choose(tui, "Open a shell here")
            #expect(await waitUntil { !tui.handoffs.handoffs.isEmpty })
            #expect(tui.handoffs.handoffs.last == Handoff(arguments: ["/bin/sh"], directory: alpha.path))
        }

        // A conversation of two Claude turns, the second prompt carrying its checkpoint.
        private func twoTurns() -> [ChatMessage] {
            var first = ChatMessage(role: .user, text: "Build the thing")
            first.checkpoint = ConversationCheckpoint(agent: .claudeCode)
            var second = ChatMessage(role: .user, text: "Now break it")
            second.checkpoint = ConversationCheckpoint(agent: .claudeCode, claudeSessionID: "claude-1")
            return [first, ChatMessage(role: .assistant, text: "Built it"),
                    second, ChatMessage(role: .assistant, text: "Broke it")]
        }

        // `m` over the open session lists what it offers. Rewind lists the prompts it can
        // go back to, newest first; the turns from there go and the prompt comes back to
        // the composer. Fork opens a new session holding the conversation up to there.
        @Test func rewindAndForkFromTheSessionsMenu() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Thing", in: alpha, messages: twoTurns())
            try await tui.start()
            await tui.press(.enter([]))
            #expect(await tui.waitFor("Broke it"), "\(tui.text)")

            await tui.press(.char("m", []))
            #expect(tui.frame[0].text == " Thing", "\(tui.text)")
            #expect(tui.contains("Rewind to a prompt…") && tui.contains("Fork from a prompt…"), "\(tui.text)")
            try await choose(tui, "Fork from a prompt…")
            let newest = try #require(tui.frame.firstIndex { $0.text.contains("Now break it") }, "\(tui.text)")
            let oldest = try #require(tui.frame.firstIndex { $0.text.contains("Build the thing") }, "\(tui.text)")
            #expect(newest < oldest)
            try await choose(tui, "Now break it")
            #expect(await waitUntil { tui.topBarText.contains("Thing · fork") }, "\(tui.text)")
            #expect(tui.contains("Built it") && !tui.contains("Broke it"), "\(tui.text)")
            #expect(tui.contains(" Now break it"), "\(tui.text)")

            // Back to the session it was forked from.
            await tui.press(.char("[", []))
            #expect(await tui.waitFor("Broke it"), "\(tui.text)")
            await tui.press(.char("m", []))
            try await choose(tui, "Rewind to a prompt…")
            try await choose(tui, "Now break it")
            #expect(await waitUntil { !tui.contains("Broke it") }, "\(tui.text)")
            #expect(tui.contains("Conversation rewound"), "\(tui.text)")
            #expect(tui.contains("Built it"), "\(tui.text)")
            // The prompt is back in the composer, ready to send again.
            #expect(tui.mainLine(containing: " Now break it") != nil, "\(tui.text)")
        }

        // A failed turn says so under the transcript and offers Continue and Dismiss in
        // the session's menu. Continue runs the recovery turn; Dismiss clears the failure.
        @Test func continueOrDismissAfterAFailure() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            case "$input" in
                *"Inspect the current state"*)
                    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Carried on"}]}}'
                    printf '%s\\n' '{"type":"result","is_error":false,"result":"Carried on"}' ;;
                *)
                    printf '%s\\n' '{"type":"result","is_error":true,"result":"The agent fell over"}' ;;
            esac
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fragile", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("Do it")
            await tui.press(.enter([]), .tab([]))
            #expect(await waitUntil { tui.frame.last?.text.contains("m continue") == true }, "\(tui.text)")

            await tui.press(.char("m", []))
            #expect(tui.contains("Continue") && tui.contains("Dismiss failure"), "\(tui.text)")
            try await choose(tui, "Continue")
            #expect(await tui.waitFor("Carried on"), "\(tui.text)")

            await tui.press(.char("i", []))
            await tui.type("Again")
            await tui.press(.enter([]), .tab([]))
            #expect(await waitUntil { tui.frame.last?.text.contains("m continue") == true }, "\(tui.text)")
            await tui.press(.char("m", []))
            try await choose(tui, "Dismiss failure")
            #expect(await waitUntil { tui.frame.last?.text.contains("m continue") == false }, "\(tui.text)")
            #expect(await waitUntil { tui.topBarText.contains("FAILED") == false }, "\(tui.topBarText)")
        }

        // A prompt queued behind a running turn can be taken back from the session's menu.
        @Test func aQueuedPromptCanBeTakenBack() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            wait_for "$folder/release"
            printf '%s\\n' '{"type":"result","is_error":false,"result":"Done"}'
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Busy", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("First")
            await tui.press(.enter([]))
            await tui.type("Second thoughts")
            await tui.press(.enter([]), .tab([]))
            #expect(await tui.waitFor("QUEUED · 1"), "\(tui.text)")

            await tui.press(.char("m", []))
            try await choose(tui, "Remove a queued prompt…")
            try await choose(tui, "Second thoughts")
            #expect(await waitUntil { !tui.contains("QUEUED") }, "\(tui.text)")
            try Data().write(to: tui.scratch.path("release"))
        }

        // What the agent expects to be asked next shows under the transcript; `s` sends
        // it as the next prompt.
        @Test func theSuggestedNextPromptCanBeSent() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Work complete"}]}}'
            printf '%s\\n' '{"type":"result","is_error":false,"result":"Work complete"}'
            printf '%s\\n' '{"type":"prompt_suggestion","suggestion":"Add a regression test"}'
            """, promptSuggestions: true)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Login", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("Fix the login retry")
            await tui.press(.enter([]), .tab([]))

            #expect(await tui.waitFor("Suggested: Add a regression test"), "\(tui.text)")
            await tui.press(.char("s", []))
            #expect(await waitUntil { tui.store.transcript(of: tui.store.sessions[0].id).map(\.text).contains("Add a regression test") },
                    "\(tui.text)")
            #expect(await waitUntil { tui.line(containing: "Add a regression test")?.text.contains("Suggested") == false },
                    "\(tui.text)")
        }

        // Recap asks the agent for one, which shows over the composer and never joins the
        // conversation.
        @Test func aRecapShowsOverTheComposer() async throws {
            let tui = try TUIHarness(agentScript: """
            input=$(cat)
            answer='Work complete'
            case "$input" in
                *'Return only the recap.'*) answer='The retry fix is complete.' ;;
            esac
            printf '%s\\n' '{"type":"thread.started","thread_id":"thread-1"}'
            printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"'"$answer"'"}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Login", in: alpha, agent: .codex)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("Fix the login retry")
            await tui.press(.enter([]), .tab([]))
            #expect(await tui.waitFor("Work complete"), "\(tui.text)")
            #expect(await waitUntil { tui.topBarText.contains("RUNNING") == false }, "\(tui.text)")

            await tui.press(.char("m", []))
            try await choose(tui, "Recap")
            #expect(await tui.waitFor("RECAP · The retry fix is complete."), "\(tui.text)")
            #expect(!tui.store.transcript(of: tui.store.sessions[0].id).map(\.text).contains("The retry fix is complete."))
        }
    }
}
