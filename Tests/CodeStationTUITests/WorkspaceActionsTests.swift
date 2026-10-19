@testable import CodeStationCore
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // Workspaces from the terminal, as the GUI's Add button, workspace row and workspace
    // screen offer them: create one from several projects with its lead, start a session
    // across its projects with a worktree or the folder for each, rename, pin and delete
    // it with the impact confirmation, change its lead and members' checkouts on its
    // screen, and read its changes across members.
    @MainActor
    @Suite
    struct WorkspaceActionsTests {

        private func openMenu(_ tui: TUIHarness, on row: String) async throws {
            await tui.press(.char("g", []))
            for _ in 0..<20 where tui.sidebarLine(containing: row)?.text.hasPrefix("▸") != true {
                await tui.press(.down([]))
            }
            try #require(tui.sidebarLine(containing: row)?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.char("a", []))
        }

        private func choose(_ tui: TUIHarness, _ entry: String) async throws {
            let target = try #require(tui.frame.firstIndex { $0.text.contains(entry) }, "\(tui.text)")
            let current = try #require(tui.frame.firstIndex { $0.text.hasPrefix("  ▸ ") }, "\(tui.text)")
            for _ in 0..<abs(target - current) { await tui.press(target > current ? .down([]) : .up([])) }
            await tui.press(.enter([]))
        }

        // Add's "Create workspace…" asks for a name and the projects, the first picked
        // leading until another is made lead. Too few projects says why; creating opens
        // the workspace's new-session form, and the sidebar lists it.
        @Test func createAWorkspaceFromAdd() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            try tui.addProject("beta")
            try tui.addProject("gamma")
            try await tui.start()

            await tui.press(.char("G", []), .down([]), .enter([]))
            try await choose(tui, "Create workspace…")
            #expect(tui.frame[0].text == " New workspace", "\(tui.text)")
            #expect(tui.line(containing: "[ ] alpha") != nil, "\(tui.text)")
            #expect(tui.frame.last?.text.contains("space pick") == true, "\(tui.text)")

            await tui.type("Both")
            await tui.press(.down([]), .char(" ", []))
            #expect(tui.line(containing: "[x] alpha")?.text.contains("LEAD") == true, "\(tui.text)")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.contains("A workspace needs at least two projects.") }, "\(tui.text)")

            await tui.press(.down([]), .char("l", []))
            #expect(tui.line(containing: "[x] beta")?.text.contains("LEAD") == true, "\(tui.text)")
            #expect(tui.line(containing: "[x] alpha")?.text.contains("LEAD") == false, "\(tui.text)")
            #expect(tui.line(containing: "[ ] gamma") != nil, "\(tui.text)")
            await tui.press(.enter([]))

            #expect(await waitUntil { tui.frame[0].text == " New session in Both" }, "\(tui.text)")
            let workspace = try #require(tui.store.workspaces.first)
            #expect(workspace.name == "Both")
            #expect(workspace.projectIDs.compactMap { tui.store.project($0)?.name } == ["beta", "alpha"])
            await tui.press(.escape)
            #expect(await waitUntil { tui.sidebarLine(containing: "Both") != nil }, "\(tui.text)")
        }

        // The workspace's new-session form lists its projects, the lead first, each on a
        // worktree or in its folder (a plain folder has no choice), then the agent. The
        // session starts with the checkouts picked and opens with the composer ready.
        @Test func startASessionInAWorkspace() async throws {
            let tui = try TUIHarness(agentScript: "exit 0")
            defer { tui.tearDown() }
            tui.commands.worktrees = StationWorkspacesTestsWorktrees.make(in: tui.scratch.path("worktrees"))
            let alpha = try tui.addProject("alpha", committing: ["README.md": "one\n"])
            let beta = try tui.addProject("beta", committing: ["README.md": "one\n"])
            let plain = try tui.addProject("plain")
            let both = try tui.addWorkspace("both", of: [alpha, beta, plain])
            try await tui.start()

            try await openMenu(tui, on: "both")
            try await choose(tui, "New session")
            #expect(await waitUntil { tui.frame[0].text == " New session in both" }, "\(tui.text)")
            #expect(tui.line(containing: "■ alpha")?.text.contains("LEAD") == true, "\(tui.text)")
            #expect(tui.line(containing: "■ alpha")?.text.contains("‹ Own worktree ›") == true, "\(tui.text)")
            #expect(tui.line(containing: "■ beta")?.text.contains("‹ Own worktree ›") == true, "\(tui.text)")
            #expect(tui.line(containing: "■ plain")?.text.contains("not a git repository") == true, "\(tui.text)")

            // beta works in its folder this time.
            await tui.press(.down([]), .right([]))
            #expect(tui.line(containing: "■ beta")?.text.contains("‹ Project folder ›") == true, "\(tui.text)")
            await tui.press(.enter([]))

            #expect(await waitUntil { tui.store.sessions(in: both.id).count == 1 }, "\(tui.text)")
            let session = try #require(tui.store.sessions(in: both.id).first)
            let checkouts = tui.store.checkoutProjects(for: session)
            #expect(checkouts.map(\.projectID) == [alpha.id, beta.id, plain.id])
            #expect(checkouts.map { $0.worktreePath != nil } == [true, false, false])
            #expect(await waitUntil { !tui.contains("New session in both") }, "\(tui.text)")
        }

        // The workspace's menu lists the GUI's entries; pin and rename change the row,
        // and deleting asks with what the station says goes and stays, the workspace's
        // tile on top. Esc keeps it; confirming takes it and leaves its projects.
        @Test func pinRenameAndDeleteFromTheWorkspacesMenu() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            let both = try tui.addWorkspace("both", of: [alpha, beta])
            try tui.addSession("Cross-repo fix", in: both)
            try await tui.start()

            try await openMenu(tui, on: "both")
            let entries = ["Pin", "Rename…", "New session", "Delete workspace"]
            let rows = entries.map { entry in tui.frame.firstIndex { $0.text.contains(entry) } }
            #expect(rows.allSatisfy { $0 != nil }, "\(tui.text)")
            #expect(rows.compactMap { $0 } == rows.compactMap { $0 }.sorted(), "\(tui.text)")
            try await choose(tui, "Pin")
            #expect(await waitUntil { tui.store.workspaces.first?.isPinned == true })

            try await openMenu(tui, on: "both")
            try await choose(tui, "Rename…")
            #expect(tui.frame[0].text == " Rename both", "\(tui.text)")
            await tui.press(.char("u", .ctrl), .enter([]))
            #expect(tui.frame.last?.text.contains("Give both a name.") == true, "\(tui.text)")
            await tui.type("Both apps")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.sidebarLine(containing: "Both apps") != nil }, "\(tui.text)")

            try await openMenu(tui, on: "Both apps")
            try await choose(tui, "Delete workspace")
            #expect(await waitUntil { tui.frame[1].text == " Delete Both apps?" }, "\(tui.text)")
            #expect(tui.frame[0].text.contains("Both apps"), "\(tui.text)")
            #expect(tui.frame.contains { $0.text.hasPrefix(" − 1 session and 0 worktrees") }, "\(tui.text)")
            #expect(tui.line(containing: "Its projects stay")?.text.hasPrefix(" ✓ ") == true, "\(tui.text)")
            #expect(tui.contains("Session history cannot be restored."), "\(tui.text)")
            await tui.press(.escape)
            #expect(tui.store.workspaces.count == 1)

            try await openMenu(tui, on: "Both apps")
            try await choose(tui, "Delete workspace")
            #expect(await waitUntil { tui.contains("Delete Both apps?") }, "\(tui.text)")
            await tui.press(.char("y", []))
            #expect(await waitUntil { tui.store.workspaces.isEmpty }, "\(tui.text)")
            #expect(tui.store.sessions.isEmpty)
            #expect(await waitUntil { tui.sidebarLine(containing: "Both apps") == nil }, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "alpha") != nil, "\(tui.text)")
        }

        // On the workspace's screen its projects can be pointed at: `l` makes one lead and
        // `w` switches whether new sessions start it on a worktree. `d` reads what each
        // member's folder has changed, the lead first, and a file's diff opens from there.
        @Test func leadCheckoutsAndChangesOnTheWorkspaceScreen() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["README.md": "one\n"])
            let beta = try tui.addProject("beta", committing: ["README.md": "one\n"])
            let both = try tui.addWorkspace("both", of: [alpha, beta])
            try "two\n".write(to: tui.scratch.path("beta/README.md"), atomically: true, encoding: .utf8)
            try await tui.start()

            await tui.press(.char("g", []))
            for _ in 0..<10 where tui.sidebarLine(containing: "both")?.text.hasPrefix("▸") != true {
                await tui.press(.down([]))
            }
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.mainLine(containing: "■ beta")?.text.contains("worktree") == true },
                    "\(tui.text)")

            // Up from the sessions lands on the last project, beta.
            await tui.press(.char("k", []))
            #expect(tui.mainLine(containing: "■ beta")?.text.contains("▸") == true, "\(tui.text)")
            await tui.press(.char("w", []))
            #expect(await waitUntil { tui.store.workspace(both.id)?.worktreeProjectIDs == [alpha.id] }, "\(tui.text)")
            #expect(await waitUntil { tui.mainLine(containing: "■ beta")?.text.contains("folder") == true },
                    "\(tui.text)")
            await tui.press(.char("l", []))
            #expect(await waitUntil { tui.store.workspace(both.id)?.leadProjectID == beta.id }, "\(tui.text)")
            #expect(await waitUntil { tui.mainLine(containing: "■ beta  lead") != nil },
                    "\(tui.text)")

            await tui.press(.char("d", []))
            #expect(await waitUntil { tui.contains("README.md") }, "\(tui.text)")
            let betaRow = try #require(tui.frame.firstIndex { $0.text.contains(" beta ") && $0.text.contains("⎇ main") },
                                       "\(tui.text)")
            let alphaRow = tui.frame.firstIndex { $0.text.contains(" alpha ") && $0.text.contains("⎇ main") }
            #expect(alphaRow.map { $0 > betaRow } ?? false, "\(tui.text)")
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.contains("+two") }, "\(tui.text)")
            await tui.press(.escape, .escape)
            #expect(tui.mainLine(containing: "PROJECTS") != nil, "\(tui.text)")
        }
    }
}

// Workspace worktrees made in a scratch folder rather than in ~/.code-station.
enum StationWorkspacesTestsWorktrees {
    static func make(in folder: URL) -> WorktreeOperations {
        WorktreeOperations(
            addProject: { _, _, _, _ in .failure(GitWorktree.Failure(message: "Unexpected project operation")) },
            addWorkspaceProject: { path, name, projectID, sessionID, base in
                let planned = GitWorktree.plan(projectName: name, projectID: projectID, sessionID: sessionID)
                let relative = planned.path.split(separator: "/").suffix(2).joined(separator: "/")
                let target = folder.appendingPathComponent(relative).path
                try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                return await GitWorktree.add(projectPath: path,
                                             planned: GitWorktree.Created(path: target, branch: planned.branch),
                                             from: base)
            },
            remove: { worktree, project, branch in
                await GitWorktree.remove(worktreePath: worktree, projectPath: project, branch: branch)
            })
    }
}
