import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The screens drawn over the list and the transcript: the new-session form, the changes
    // list and its diffs, the key list and the typed folder the station can ask for.
    @MainActor
    @Suite
    struct OverlayScreenTests {

        // MARK: - New session

        // Without a script of its own, every agent reads as installed, whatever this
        // machine has on its PATH, so the new-session form never warns about one.
        @Test func theHarnessNeverReachesForRealAgents() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            #expect(AgentKind.allCases.allSatisfy { tui.runner.isAvailable($0) })
        }

        @Test func nOpensTheNewSessionFormOnTheSelectedProject() async throws {
            let tui = try TUIHarness(agentScript: "exit 0")
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.char("n", []))

            #expect(tui.frame[0].text == " New session", "\(tui.text)")
            let project = try #require(tui.line(containing: "Project"), "\(tui.text)")
            #expect(project.text.hasPrefix("  ▸ Project   ‹ alpha ›"))
            #expect(project.style(of: "‹ alpha ›")?.inverse == true)
            #expect(tui.contains("Agent     ‹ Claude Code ›"), "\(tui.text)")
            #expect(tui.contains("not a git repository, so no worktree"))
            #expect(tui.frame.last?.text.contains("enter start") == true)
        }

        // Enter starts the session through the station and opens it, ready for its first
        // prompt.
        @Test func startingANewSessionOpensItWithTheComposerReady() async throws {
            let tui = try TUIHarness(agentScript: "exit 0")
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            try await tui.start()
            await tui.press(.char("n", []))

            await tui.press(.enter([]))

            #expect(await waitUntil { tui.topBar.first?.text.hasPrefix(" ■ alpha / ") == true },
                    "\(tui.text)")
            #expect(tui.frame.last?.text.contains("enter send") == true, "\(tui.text)")
            #expect(tui.terminal.screen.cursorVisible)
            #expect(tui.commands.listDirectory().projects.flatMap(\.sessions).count == 1)
        }

        @Test func escapeLeavesTheFormWithoutStartingAnything() async throws {
            let tui = try TUIHarness(agentScript: "exit 0")
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            try await tui.start()
            await tui.press(.char("n", []))

            await tui.press(.escape)

            #expect(tui.frame[0].text.hasPrefix(" Code Station"), "\(tui.text)")
            #expect(tui.commands.listDirectory().projects.flatMap(\.sessions).isEmpty)
        }

        // MARK: - Changes

        @Test func dListsTheSessionsChangesAndEnterOpensADiff() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["README.md": "hello\n"])
            try "hello\nworld\n".write(to: alpha.url.appendingPathComponent("README.md"),
                                       atomically: true, encoding: .utf8)
            try tui.addSession("Edit the readme", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("d", []))

            #expect(await tui.waitFor("README.md"), "\(tui.text)")
            #expect(tui.mainPane[0].text.hasPrefix(" Changes · Edit the readme · 1 file"), "\(tui.text)")
            let file = try #require(tui.line(containing: "README.md"))
            #expect(file.text.contains("+1 -0"))
            #expect(file.style(of: "+1")?.foreground == .basic(32))

            await tui.press(.enter([]))

            let added = try #require(tui.line(containing: "+world"), "\(tui.text)")
            #expect(added.style(of: "+world")?.foreground == .basic(32))
            #expect(tui.mainPane[0].text.hasPrefix(" README.md · modified"), "\(tui.text)")
        }

        // MARK: - Help

        @Test func questionMarkListsTheKeysOfTheScreenItWasOpenedFrom() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            try await tui.start()

            await tui.press(.char("?", []))

            #expect(tui.frame[0].text == " Code Station · Keys", "\(tui.text)")
            let section = try #require(tui.frame.dropFirst().first { !$0.text.isEmpty })
            #expect(section.text == " Sidebar")
            #expect(section.style(of: "Sidebar")?.bold == true)

            await tui.press(.escape)

            #expect(tui.frame[0].text.hasPrefix(" Code Station"))
            #expect(!tui.contains("Keys"))
        }

        // MARK: - A typed folder

        // When the station asks the host for a folder, the TUI asks for a typed path over
        // everything else and hands back what was typed.
        @Test func aFolderTheStationAsksForIsTypedOverTheScreen() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            try await tui.start()
            let folder = tui.scratch.path("picked")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let host = tui.host
            let asked = Task { @MainActor in
                try await host.chooseDirectory(prompt: "Add a project", message: "", startingAt: nil)
            }

            #expect(await tui.waitFor("Add a project"), "\(tui.text)")
            #expect(tui.frame.last?.text.contains("enter choose") == true)
            await tui.type(folder.path)
            await tui.press(.enter([]))

            let chosen = try await asked.value
            #expect(chosen?.standardizedFileURL.path == folder.standardizedFileURL.path)
            #expect(tui.frame[0].text.hasPrefix(" Code Station"), "\(tui.text)")
        }
    }
}
