@testable import CodeStationCore
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // What a project's and a task's actions menu does, and Add's "Add project…": pin and
    // unpin, rename, snooze and wake, open a shell in the folder, clear idle sessions and
    // remove, each deletion asking first with what the station says goes and stays, and a
    // project added by its typed path, with completion.
    @MainActor
    @Suite
    struct ProjectActionsTests {

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

        // The project's menu lists the GUI's entries in its order, Pin first; Wake now
        // shows only while the cleanup is snoozed. Pin, snooze and wake change the row.
        @Test func pinSnoozeAndWakeFromTheProjectsMenu() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            try await openMenu(tui, on: "alpha")
            let entries = ["Pin", "Rename…", "New session", "Snooze cleanup 1 day", "Open a shell here",
                           "Clear idle sessions", "Remove project"]
            let rows = entries.map { entry in tui.frame.firstIndex { $0.text.contains(entry) } }
            #expect(rows.allSatisfy { $0 != nil }, "\(tui.text)")
            #expect(rows.compactMap { $0 } == rows.compactMap { $0 }.sorted(), "\(tui.text)")
            #expect(!tui.contains("Wake now"), "\(tui.text)")
            #expect(tui.line(containing: "Pin")?.text.hasPrefix("  ▸ ") == true, "\(tui.text)")

            try await choose(tui, "Pin")
            #expect(await waitUntil { tui.sidebarLine(containing: "alpha")?.text.contains("⚑") == true },
                    "\(tui.sidebarText)")
            #expect(tui.store.projects.first?.isPinned == true)
            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Unpin")
            #expect(await waitUntil { tui.sidebarLine(containing: "alpha")?.text.contains("⚑") == false },
                    "\(tui.sidebarText)")

            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Snooze cleanup 1 day")
            #expect(await waitUntil { tui.sidebarLine(containing: "alpha")?.text.contains("☾1d") == true },
                    "\(tui.sidebarText)")
            try await openMenu(tui, on: "alpha")
            #expect(tui.contains("Snooze cleanup 1 more day"), "\(tui.text)")
            try await choose(tui, "Wake now")
            #expect(await waitUntil { tui.sidebarLine(containing: "alpha")?.text.contains("☾") == false },
                    "\(tui.sidebarText)")
            #expect(tui.store.projects.first?.snoozedUntil == nil)
        }

        // Rename asks for the new name, starting from the old one. An empty name is
        // refused in the prompt, which stays; Esc keeps the old name.
        @Test func renameAsksForTheNewName() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            try await tui.start()

            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Rename…")
            #expect(tui.frame[0].text == " Rename alpha", "\(tui.text)")
            #expect(tui.line(containing: " alpha") != nil, "\(tui.text)")
            #expect(tui.frame.last?.text.contains("enter rename") == true, "\(tui.text)")

            await tui.press(.char("u", .ctrl), .enter([]))
            #expect(tui.frame[0].text == " Rename alpha", "\(tui.text)")
            #expect(tui.frame.last?.text.contains("Give alpha a name.") == true, "\(tui.text)")

            await tui.type("Alpha app")
            await tui.press(.enter([]))
            #expect(await tui.waitFor("Alpha app"), "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Alpha app") != nil, "\(tui.text)")

            try await openMenu(tui, on: "Alpha app")
            try await choose(tui, "Rename…")
            await tui.type(" two")
            await tui.press(.escape)
            #expect(tui.sidebarLine(containing: "Alpha app") != nil, "\(tui.text)")
            #expect(!tui.contains("Alpha app two"), "\(tui.text)")
        }

        // Clearing asks with what the station says: the idle sessions go, the folder
        // stays. Esc keeps them; confirming takes them.
        @Test func clearingIdleSessionsAsksFirst() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Old idea", in: alpha)
            try tui.addSession("Older idea", in: alpha)
            try await tui.start()

            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Clear idle sessions")
            #expect(tui.frame[0].text == " ■ alpha", "\(tui.text)")
            #expect(tui.frame[1].text == " Clear 2 sessions from alpha?", "\(tui.text)")
            #expect(tui.frame.contains { $0.text.hasPrefix(" − 2 sessions") }, "\(tui.text)")
            #expect(tui.line(containing: "Original project folder stays")?.text.hasPrefix(" ✓ ") == true,
                    "\(tui.text)")
            #expect(tui.contains("Conversation history cannot be restored."), "\(tui.text)")
            #expect(tui.contains("[ Clear sessions ]"), "\(tui.text)")

            await tui.press(.escape)
            #expect(tui.sidebarLine(containing: "Old idea") != nil, "\(tui.text)")

            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Clear idle sessions")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.sidebarLine(containing: "idea") == nil }, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "alpha") != nil, "\(tui.text)")
            #expect(tui.store.sessions.isEmpty)
        }

        // With nothing idle, clearing says so rather than asking.
        @Test func clearingAProjectWithNothingIdleSaysSo() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            try await tui.start()

            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Clear idle sessions")
            #expect(tui.sidebar.last?.text.contains("alpha has no idle sessions.") == true, "\(tui.text)")
        }

        // Removing asks with the project's impact, then takes it out of the tree; a task
        // deletes, its tile dashed.
        @Test func removingAProjectOrTaskAsksFirst() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try tui.addProject("beta")
            try tui.addTask("Sweep")
            try await tui.start()

            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Remove project")
            #expect(tui.frame[0].text == " ■ alpha", "\(tui.text)")
            #expect(tui.frame[1].text == " Remove alpha?", "\(tui.text)")
            #expect(tui.line(containing: "1 session and 0 worktrees")?.text.hasPrefix(" − ") == true, "\(tui.text)")
            #expect(tui.contains("[ Remove project ]"), "\(tui.text)")
            await tui.press(.char("y", []))
            #expect(await waitUntil { tui.sidebarLine(containing: "alpha") == nil }, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "beta") != nil, "\(tui.text)")

            try await openMenu(tui, on: "Sweep")
            #expect(tui.contains("Clear idle runs"), "\(tui.text)")
            try await choose(tui, "Delete task")
            #expect(tui.frame[0].text == " □ Sweep", "\(tui.text)")
            #expect(tui.frame[1].text == " Delete Sweep?", "\(tui.text)")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.sidebarLine(containing: "Sweep") == nil }, "\(tui.text)")
        }

        // The shell named by $SHELL runs in the project's folder, on the terminal, and the
        // sidebar is back once it exits. A shell that cannot start says so.
        @Test func openAShellHereHandsTheTerminalToTheShell() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            tui.environment = ["SHELL": "/bin/fish"]
            let alpha = try tui.addProject("alpha")
            try await tui.start()

            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Open a shell here")
            #expect(tui.handoffs.handoffs == [Handoff(arguments: ["/bin/fish"], directory: alpha.path)])
            #expect(tui.sidebarLine(containing: "alpha") != nil, "\(tui.text)")

            tui.handoffs.status = -1
            try await openMenu(tui, on: "alpha")
            try await choose(tui, "Open a shell here")
            #expect(tui.sidebar.last?.text.contains("/bin/fish could not be started.") == true, "\(tui.text)")
        }

        // Add project asks for a folder's path. Tab completes a folder name, or as much of
        // it as the folders that match share, listing them; Enter adds the folder and
        // points the sidebar at it. A path that is not a folder is refused in the prompt.
        @Test func addProjectTakesATypedPathWithCompletion() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 180, rows: 30))
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            let projects = tui.scratch.path("projects")
            for name in ["gamma-app", "gamma-lib", "delta"] {
                try FileManager.default.createDirectory(at: projects.appendingPathComponent(name),
                                                        withIntermediateDirectories: true)
            }
            try Data().write(to: projects.appendingPathComponent("gamma-notes.txt"))
            try await tui.start()

            await tui.press(.char("G", []), .down([]), .enter([]))
            try await choose(tui, "Add project…")
            #expect(tui.frame[0].text == " Add project", "\(tui.text)")
            #expect(tui.frame.last?.text.contains("tab complete") == true, "\(tui.text)")

            await tui.type(projects.path + "/d")
            await tui.press(.tab([]))
            #expect(tui.line(containing: projects.path + "/delta/") != nil, "\(tui.text)")

            await tui.press(.char("u", .ctrl))
            await tui.type(projects.path + "/gam")
            await tui.press(.tab([]))
            #expect(tui.line(containing: projects.path + "/gamma-")?.text.contains("gamma-app") == false, "\(tui.text)")
            #expect(tui.line(containing: "gamma-app/") != nil && tui.line(containing: "gamma-lib/") != nil,
                    "\(tui.text)")
            #expect(!tui.contains("gamma-notes"), "\(tui.text)")
            await tui.type("a")
            await tui.press(.tab([]))
            #expect(tui.line(containing: projects.path + "/gamma-app/") != nil, "\(tui.text)")
            #expect(tui.line(containing: "gamma-lib/") == nil, "\(tui.text)")

            await tui.press(.enter([]))
            #expect(await waitUntil { tui.sidebarLine(containing: "gamma-app")?.text.hasPrefix("▸") == true },
                    "\(tui.text)")
            #expect(tui.store.projects.map(\.name).sorted() == ["alpha", "gamma-app"])

            await tui.press(.char("G", []), .down([]), .enter([]))
            try await choose(tui, "Add project…")
            await tui.type(projects.path + "/nowhere")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.contains("is not a folder.") }, "\(tui.text)")
            #expect(tui.frame[0].text == " Add project", "\(tui.text)")
            await tui.press(.escape)
            #expect(tui.sidebarLine(containing: "gamma-app") != nil, "\(tui.text)")
        }
    }
}
