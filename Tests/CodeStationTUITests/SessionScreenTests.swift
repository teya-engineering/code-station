@testable import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // An open session: its transcript, the composer under it, and what the agent asks back,
    // driven from keys through the station to a fake agent and back to the frame.
    @MainActor
    @Suite
    struct SessionScreenTests {

        private static let writeRequest = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/p/hello.txt","content":"hi"},"tool_use_id":"toolu_1"}}"#

        @Test func enterOpensTheSelectedSessionOnItsTranscript() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha, messages: [
                ChatMessage(role: .user, text: "Why does login fail?"),
                ChatMessage(role: .assistant, text: "The token has **expired**.")
            ])
            try await tui.start()

            await tui.press(.enter([]))

            let top = try #require(tui.topBar.first)
            #expect(top.text.hasPrefix(" ■ alpha / Fix the login bug"), "\(tui.text)")
            #expect(top.text.contains("● IDLE · "))
            let prompt = try #require(tui.line(containing: "Why does login fail?"), "\(tui.text)")
            #expect(prompt.style(of: "Why does login fail?")?.bold == true)
            let reply = try #require(tui.line(containing: "The token has expired."), "\(tui.text)")
            #expect(reply.style(of: "expired")?.bold == true)
            #expect(reply.style(of: "The token")?.bold == false)
            #expect(tui.contains("› write a prompt: enter"))
        }

        // A conversation brought in from an agent's own history sits on disk until it is
        // read, as one from an earlier run does. Opening it shows the whole of it.
        @Test func anImportedSessionOpensOnItsTranscript() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let candidate = ExternalSessionCandidate(
                sessionID: "claude-imported", file: URL(fileURLWithPath: "/dev/null"),
                cwd: alpha.path, title: "Imported login fix", firstPrompt: "Why does login fail?",
                startedAt: Date(timeIntervalSince1970: 1_000), lastActivity: Date(timeIntervalSince1970: 2_000),
                gitBranch: "main", bytes: 10)
            let imported = try await tui.store.importSession(
                ProjectStore.SessionImport(candidate: candidate, messages: [
                    ChatMessage(role: .user, text: "Why does login fail?"),
                    ChatMessage(role: .assistant, text: "The token expires early."),
                ]), into: alpha.id).get()
            #expect(!tui.store.isTranscriptLoaded(imported.id))
            try await tui.start()

            await tui.press(.enter([]))

            #expect(await tui.waitFor("Why does login fail?"), "\(tui.text)")
            #expect(tui.contains("The token expires early."), "\(tui.text)")
        }

        // Going back gives the sidebar the keys and leaves the session in the main pane.
        @Test func escapeGoesBackToTheSidebar() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(tui.contains("Nothing here yet."), "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Fix the login bug")?.style(of: "Fix the login bug")?.inverse != true)

            await tui.press(.escape)

            let card = try #require(tui.sidebarLine(containing: "▸ │ Fix the login bug"), "\(tui.text)")
            #expect(card.style(of: "Fix the login bug")?.inverse == true)
            #expect(tui.contains("Nothing here yet."), "\(tui.text)")
        }

        // A prompt typed in the composer goes to the agent, and its answer lands in the
        // transcript once the turn ends.
        @Test func aPromptWrittenInTheComposerRunsATurn() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello from the agent"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Hello from the agent"}'
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Greetings", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("i", []))
            await tui.type("Say hello")
            #expect(tui.contains(" Say hello"), "\(tui.text)")
            #expect(tui.terminal.screen.cursorVisible)
            #expect(tui.frame.last?.text.contains("enter send") == true)
            await tui.press(.enter([]))

            #expect(await tui.waitFor("Hello from the agent"), "\(tui.text)")
            let prompt = try #require(tui.line(containing: "Say hello"))
            #expect(prompt.style(of: "Say hello")?.bold == true)
            #expect(await waitUntil { tui.topBar.first?.text.contains("RUNNING") == false }, "\(tui.text)")
        }

        // The TUI tells the station which session it shows, so a turn that ends on screen
        // is read, and the sidebar says IDLE rather than asking for the person.
        @Test func aTurnThatEndsOnScreenIsRead() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello from the agent"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Hello from the agent"}'
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Greetings", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("Say hello")
            await tui.press(.enter([]))
            #expect(await tui.waitFor("Hello from the agent"), "\(tui.text)")
            #expect(await waitUntil { tui.topBar.first?.text.contains("IDLE") == true }, "\(tui.text)")

            await tui.press(.escape, .escape)

            let row = try #require(tui.sidebarRows(of: ["Greetings"]).first ?? nil, "\(tui.text)")
            // The sidebar hears of the turn's end on its own next update.
            #expect(await waitUntil { !tui.sidebar[row + 1].text.contains("RUNNING") }, "\(tui.text)")
            #expect(tui.sidebar[row + 1].text.hasPrefix("  │ IDLE"), "\(tui.text)")
            #expect(tui.sidebar[row].text.hasSuffix(" │ Greetings"), "\(tui.text)")
        }

        // A tool waiting for permission takes over the composer's place; allowing it lets
        // the agent carry on.
        @Test func aPermissionRequestIsAnsweredFromTheKeyboard() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '\(Self.writeRequest)'
            IFS= read -r answer
            case "$answer" in *'"behavior":"allow"'*) ;; *) exit 7 ;; esac
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Wrote it."}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Wrote it."}'
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Write a file", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("Write hello")
            await tui.press(.enter([]), .tab([]))

            #expect(await tui.waitFor("needs permission"), "\(tui.text)")
            let heading = try #require(tui.line(containing: "needs permission"))
            #expect(heading.style(of: "needs permission")?.foreground == .basic(33))
            let choices = try #require(tui.line(containing: "allow once"), "\(tui.text)")
            #expect(choices.style(of: " 1 ")?.inverse == true)
            #expect(choices.text.contains("deny"))

            await tui.press(.char("1", []))

            #expect(await tui.waitFor("Wrote it."), "\(tui.text)")
            #expect(!tui.contains("needs permission"))
        }
    }
}
