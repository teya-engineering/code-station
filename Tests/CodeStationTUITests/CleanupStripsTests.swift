@testable import CodeStationCore
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // What the cleanup strips at the sidebar's foot and the warning strip under the top
    // bar do, as the GUI's do: prune orphaned worktrees after a confirmation naming each,
    // review old sessions (tick, snooze, wake, delete, saved work asked about twice), and
    // rebuild a lost worktree after saying where its commits come from.
    @MainActor
    @Suite
    struct CleanupStripsTests {

        @Test func theOrphanStripPrunesAfterAConfirmationNamingEach() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fresh", in: alpha, ago: 60)
            try await tui.start()
            tui.startUpkeep(orphans: [GitWorktree.Orphaned(path: "/worktrees/stray", branch: "code-station/stray",
                                                           allocatedBytes: 4_096)])
            #expect(await tui.waitFor("1 orphaned worktree"), "\(tui.sidebarText)")

            await tui.press(.char("G", []), .down([]))
            #expect(tui.sidebarLine(containing: "1 orphaned worktree")?.text.hasPrefix("▸") == true,
                    "\(tui.sidebarText)")
            await tui.press(.enter([]))
            #expect(tui.frame[0].text == " Prune 1 orphaned worktree?", "\(tui.text)")
            let row = try #require(tui.line(containing: "alpha · code-station/stray"), "\(tui.text)")
            #expect(row.text.hasPrefix(" − "), "\(row.text)")
            #expect(tui.contains("/worktrees/stray · 4 KB"), "\(tui.text)")
            #expect(tui.contains("Any uncommitted changes in them will be lost."), "\(tui.text)")
            #expect(tui.line(containing: "[ Prune all ]")?.style(of: "[ Prune all ]")?.inverse == true)

            await tui.press(.escape)
            #expect(tui.pruned.isEmpty)
            #expect(tui.sidebarLine(containing: "1 orphaned worktree") != nil, "\(tui.text)")

            await tui.press(.enter([]))
            await tui.press(.enter([]))
            #expect(tui.pruned == ["/worktrees/stray"])
            #expect(await waitUntil { tui.sidebarLine(containing: "orphaned worktree") == nil }, "\(tui.sidebarText)")
        }

        @Test func theOldSessionsStripOpensTheReview() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 110, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Fresh", in: alpha, ago: 60)
            try tui.addSession("Quiet", in: alpha, ago: 12 * 86_400)
            let sleepy = try tui.addSession("Sleepy", in: beta, ago: 10 * 86_400)
            try await tui.start()
            #expect(await tui.waitFor("2 sessions older than 3 days"), "\(tui.sidebarText)")

            await tui.press(.char("G", []), .down([]), .enter([]))
            #expect(await tui.waitFor("[✓] Quiet"), "\(tui.text)")
            #expect(tui.frame[0].text == " Sessions older than 3 days", "\(tui.text)")
            #expect(tui.line(containing: "[✓] Quiet")?.text.contains("history only") == true, "\(tui.text)")
            #expect(tui.contains("last turn 12 days ago · no worktree"), "\(tui.text)")
            #expect(tui.contains("[✓] Sleepy"), "\(tui.text)")
            #expect(!tui.contains("Fresh"), "\(tui.text)")
            let rows = ["alpha", "Quiet", "beta", "Sleepy", "[ Delete 2 sessions ]"]
                .map { fragment in tui.frame.firstIndex { $0.text.contains(fragment) } }
            #expect(rows.allSatisfy { $0 != nil } && rows.compactMap { $0 } == rows.compactMap { $0 }.sorted(),
                    "\(tui.text)")

            // Space unticks and ticks again.
            await tui.press(.char("j", []), .char(" ", []))
            #expect(tui.contains("[ ] Quiet") && tui.contains("[ Delete 1 session ]"), "\(tui.text)")
            await tui.press(.char(" ", []))
            #expect(tui.contains("[✓] Quiet"), "\(tui.text)")

            // A project snoozed shows its snooze in place of its sessions, and wakes.
            await tui.press(.char("j", []), .char("z", []))
            #expect(await tui.waitFor("beta snoozed until tomorrow"), "\(tui.text)")
            #expect(!tui.contains("Sleepy"), "\(tui.text)")
            #expect(tui.contains("[ Delete 1 session ]"), "\(tui.text)")
            await tui.press(.char("w", []))
            #expect(await tui.waitFor("Sleepy"), "\(tui.text)")

            // Delete takes the ticked sessions that cost nothing but history at once, and
            // the review closes.
            await tui.press(.char("j", []), .char(" ", []), .char("d", []))
            #expect(await waitUntil { !tui.contains("Sessions older than") }, "\(tui.text)")
            #expect(await waitUntil { tui.sidebarLine(containing: "Quiet") == nil }, "\(tui.sidebarText)")
            #expect(tui.store.session(sleepy.id) != nil)
        }

        @Test func deletingSavedWorkFromTheReviewAsksFirst() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["a.txt": "one\n"])
            let checkout = tui.scratch.path("dirty")
            try tui.git(["worktree", "add", "-q", checkout.path, "-b", "code-station/dirty"], in: alpha.url)
            try "two\n".write(to: checkout.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let dirty = tui.store.newSession(in: alpha.id, worktreePath: checkout.path,
                                             worktreeBranch: "code-station/dirty")
            tui.store.renameSession(dirty.id, to: "Dirty")
            tui.store.append(ChatMessage(role: .user, text: "Old", date: Date().addingTimeInterval(-9 * 86_400)),
                             to: dirty.id)
            try await tui.start()
            #expect(await tui.waitFor("1 session older than 3 days"), "\(tui.sidebarText)")

            await tui.press(.char("G", []), .down([]), .enter([]))
            #expect(await tui.waitFor("[ ] Dirty"), "\(tui.text)")
            #expect(tui.line(containing: "[ ] Dirty")?.text.contains("would lose work") == true, "\(tui.text)")
            #expect(tui.contains("⑂ code-station/dirty · +1 -1 uncommitted"), "\(tui.text)")
            #expect(tui.contains("One session has uncommitted changes in its worktree"), "\(tui.text)")

            await tui.press(.char("j", []), .char(" ", []), .char("d", []))
            #expect(tui.frame[0].text == " Delete a session with saved work?", "\(tui.text)")
            #expect(tui.line(containing: "1 worktree with uncommitted changes")?.text.hasPrefix(" − ") == true,
                    "\(tui.text)")
            #expect(tui.contains("This work cannot be restored."), "\(tui.text)")
            #expect(tui.contains("[ Delete 1 session ]"), "\(tui.text)")

            await tui.press(.escape)
            #expect(tui.frame[0].text == " Sessions older than 3 days", "\(tui.text)")
            #expect(tui.store.session(dirty.id) != nil)

            await tui.press(.char("d", []), .enter([]))
            #expect(await waitUntil { tui.store.session(dirty.id) == nil })
            #expect(await waitUntil { !tui.contains("Sessions older than") }, "\(tui.text)")
        }

        @Test func aLostWorktreeIsRebuiltFromTheWarningStrip() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 200, rows: 24), agentScript: "exit 0")
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["a.txt": "one\n"])
            let checkout = tui.scratch.path("lost")
            try tui.git(["worktree", "add", "-q", checkout.path, "-b", "code-station/lost"], in: alpha.url)
            try FileManager.default.removeItem(at: checkout)
            let lost = tui.store.newSession(in: alpha.id, worktreePath: checkout.path,
                                            worktreeBranch: "code-station/lost")
            tui.store.renameSession(lost.id, to: "Lost checkout")
            try await tui.start()

            await tui.press(.enter([]))
            #expect(tui.topBar.count == 4, "\(tui.topBarText)")
            #expect(tui.topBar[3].text.contains("It was removed outside the app.  R rebuild"), "\(tui.topBarText)")

            await tui.press(.char("R", []))
            #expect(tui.frame[0].text == " Rebuild the missing folder?", "\(tui.text)")
            #expect(tui.contains("code-station/lost is still on this machine"), "\(tui.text)")
            let button = try #require(tui.line(containing: "[ Rebuild ]"), "\(tui.text)")
            #expect(button.style(of: "[ Rebuild ]")?.foreground == .basic(32))

            await tui.press(.escape)
            #expect(!FileManager.default.fileExists(atPath: checkout.path))

            await tui.press(.char("R", []))
            await tui.press(.enter([]))
            #expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("a.txt").path))
            #expect(await waitUntil { tui.topBar.count == 3 }, "\(tui.topBarText)")
            #expect(!tui.contains("⚠"), "\(tui.text)")
        }
    }
}
