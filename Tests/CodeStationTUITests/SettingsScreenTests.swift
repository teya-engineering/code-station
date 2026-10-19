import CodeStationCore
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // The settings that matter outside the GUI, drawn over everything and written to the
    // shared station preferences; each agent's readiness with the command that fixes it;
    // a session's log handed to `$PAGER`; and the note that an update is waiting.
    @MainActor
    @Suite
    struct SettingsScreenTests {

        // MARK: - Settings

        @Test func commaOpensTheSettingsWithWhatThePreferencesHold() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 40), agentScript: "exit 0")
            defer { tui.tearDown() }
            Preferences.setSessionFinishedSound(.ping, in: tui.preferences)
            try await tui.start()

            await tui.press(.char(",", []))

            #expect(tui.frame[0].text == " Settings", "\(tui.text)")
            let agent = try #require(tui.line(containing: "Agent"), "\(tui.text)")
            #expect(agent.text.hasPrefix("  ▸ Agent"))
            #expect(agent.style(of: "‹ Claude Code ›")?.inverse == true)
            #expect(tui.contains("‹ Ping ›"), "\(tui.text)")
            let heading = try #require(tui.line(containing: "New sessions"))
            #expect(heading.style(of: "New sessions")?.bold == true)
            #expect(tui.frame.last?.text.contains("esc close") == true)

            await tui.press(.escape)

            #expect(tui.frame[0].text.hasPrefix(" Code Station"), "\(tui.text)")
        }

        // The palette's Settings action leads there too.
        @Test func thePalettesSettingsActionOpensTheSettings() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30), agentScript: "exit 0")
            defer { tui.tearDown() }
            try await tui.start()

            await tui.press(.char("k", .ctrl))
            await tui.type("settings")
            await tui.press(.enter([]))

            #expect(tui.frame[0].text == " Settings", "\(tui.text)")
        }

        // Changing a setting writes the shared preferences the GUI reads, and the sidebar
        // follows a new arrangement.
        @Test func changingASettingWritesThePreferencesTheGUIReads() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 60), agentScript: "exit 0")
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            try await tui.start()
            await tui.press(.char(",", []))

            try await select("Sort", in: tui)
            await tui.press(.right([]))

            #expect(Preferences.projectSort(in: tui.preferences) == .lastUsed)
            let sort = try #require(tui.line(containing: "▸ Sort"), "\(tui.text)")
            #expect(sort.text.contains("‹ Last used ›"))

            try await select("Sound when a session finishes", in: tui)
            await tui.press(.left([]))

            #expect(Preferences.sessionFinishedSound(in: tui.preferences) == .funk)

            await tui.press(.escape)

            #expect(await waitUntil { tui.sidebarText.contains("Last used") }, "\(tui.text)")
        }

        // MARK: - Readiness

        @Test func anAgentThatIsNotReadySaysWhatToRun() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 60), agentScript: "exit 0",
                                     installed: [.claudeCode, .codex])
            defer { tui.tearDown() }
            try tui.signIn(.codex)
            try await tui.start()

            await tui.press(.char(",", []))

            let claude = try #require(tui.line(containing: "Claude Code is not signed in"), "\(tui.text)")
            #expect(claude.text.contains("Run: claude /login"))
            #expect(claude.style(of: "Claude Code is not signed in")?.foreground == .basic(33))
            let copilot = try #require(tui.line(containing: "Copilot is not installed"), "\(tui.text)")
            #expect(copilot.text.contains("Install: npm install -g @github/copilot"))
            #expect(tui.contains("✓ Signed in · API key"), "\(tui.text)")
        }

        // The new-session form says so too, for the agent it would start on.
        @Test func theNewSessionFormSaysWhenItsAgentIsNotSignedIn() async throws {
            let tui = try TUIHarness(agentScript: "exit 0", installed: [.claudeCode])
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            try await tui.start()

            await tui.press(.char("n", []))

            #expect(await tui.waitFor("Claude Code is not signed in. Run: claude /login"), "\(tui.text)")
        }

        // MARK: - Log

        // L hands the session's own log lines to the pager, in a file that goes once the
        // pager exits.
        @Test func lOpensTheSessionsLogInThePager() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            tui.environment = ["PAGER": "most -s"]
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Fix the login bug", in: alpha)
            let marker = UUID().uuidString
            SessionLog.note("turn started \(marker)", session: session.id)
            try await tui.start()
            await tui.press(.enter([]))
            var paged = ""
            tui.handoffs.whileRunning = { handoff in
                paged = (try? String(contentsOfFile: handoff.arguments.last ?? "", encoding: .utf8)) ?? ""
            }

            await tui.press(.char("L", []))

            let handoff = try #require(tui.handoffs.handoffs.first, "\(tui.text)")
            #expect(Array(handoff.arguments.prefix(2)) == ["most", "-s"])
            #expect(paged.contains("turn started \(marker)"))
            #expect(!FileManager.default.fileExists(atPath: handoff.arguments.last ?? ""))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Fix the login bug") == true, "\(tui.text)")
        }

        @Test func theLogOpensInLessWithNoPagerSet() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Fix the login bug", in: alpha)
            SessionLog.note("turn started", session: session.id)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("L", []))

            #expect(tui.handoffs.handoffs.first?.arguments.first == "less", "\(tui.text)")
        }

        @Test func aSessionWithNothingLoggedSaysSoInsteadOfPaging() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("L", []))

            #expect(tui.handoffs.handoffs.isEmpty)
            #expect(tui.contains("Nothing is logged for this session yet."), "\(tui.text)")
        }

        // MARK: - Update

        @Test func anUpdateTheGUIFoundIsNoted() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            tui.preferences.set(Data(#"{"version":"2.4.0","pageURL":"https://example.com/r"}"#.utf8),
                                forKey: "cachedAppUpdateRelease")
            tui.commands.installedVersion = "2.3.1"
            try await tui.start()

            #expect(await waitUntil { tui.sidebarText.contains("Update 2.4.0 available") }, "\(tui.text)")
            // The note has a row of its own: the Add and Tools row stays reachable under it.
            #expect(tui.sidebarText.contains("+ Add"), "\(tui.text)")

            await tui.press(.char(",", []))

            #expect(tui.contains("Code Station 2.4.0 is available (this is 2.3.1)"), "\(tui.text)")
        }

        @Test func noUpdateNoNote() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            tui.commands.installedVersion = "2.3.1"
            try await tui.start()

            #expect(!tui.contains("available"), "\(tui.text)")
        }

        // MARK: - Helpers

        // Moves the pointer down the settings to the row titled so.
        private func select(_ title: String, in tui: TUIHarness) async throws {
            await tui.press(.home([]))
            for _ in 0..<40 {
                if tui.line(containing: "▸ \(title)") != nil { return }
                await tui.press(.down([]))
            }
            Issue.record("No setting called \(title):\n\(tui.text)")
        }
    }
}
