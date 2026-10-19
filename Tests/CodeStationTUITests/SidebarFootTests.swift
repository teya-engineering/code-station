@testable import CodeStationCore
import Darwin
import Foundation
import TerminalKit
import Testing
@testable import CodeStationTUI

extension TUITests {
    // The foot of the sidebar and the menus it opens: the cleanup strips, Add and Tools,
    // a row's actions menu with the impact confirmation a deletion asks for, and the
    // banner while the station moves to another host.
    @MainActor
    @Suite
    struct SidebarFootTests {

        // Old sessions are counted past the shared age, with the sweep's countdown once it
        // has settled on them; orphaned worktrees with their size, in amber.
        @Test func theCleanupStripsSitAtTheFoot() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fresh", in: alpha, ago: 60)
            try await tui.start()
            #expect(tui.sidebarLine(containing: "older than") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "orphaned") == nil, "\(tui.sidebarText)")

            try tui.addSession("Old one", in: alpha, ago: 10 * 86_400)
            try tui.addSession("Old two", in: alpha, ago: 12 * 86_400)
            #expect(await tui.waitFor("2 sessions older than 3 days"), "\(tui.sidebarText)")

            tui.startUpkeep(orphans: [GitWorktree.Orphaned(path: "/worktrees/stray", branch: "code-station/stray",
                                                           allocatedBytes: 4_096)])
            #expect(await tui.waitFor("1 orphaned worktree"), "\(tui.sidebarText)")
            // The sweep settles on its cohort and counts down to it.
            #expect(await tui.waitFor("will be deleted"), "\(tui.sidebarText)")
            let rows = tui.sidebarRows(of: ["Fresh", "will be deleted", "Older than 3 days · ⏱",
                                            "1 orphaned worktree", "No session · 4 KB", "+ Add   ⚙ Tools", "? keys"])
            #expect(rows.allSatisfy { $0 != nil }, "\(tui.sidebarText)")
            let found = rows.compactMap { $0 }
            #expect(found == found.sorted(), "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "1 orphaned worktree")?.style(of: "1 orphaned worktree")?.foreground
                    == .basic(33))
            // The countdown is counted on the second, with nothing else moving.
            let countdown = tui.sidebarLine(containing: "Older than 3 days · ⏱")?.text
            #expect(await waitUntil(timeout: .seconds(5)) {
                tui.sidebarLine(containing: "Older than 3 days · ⏱")?.text != countdown
            }, "\(tui.sidebarText)")
            // The strip opens the review (see CleanupStripsTests).
            await tui.press(.char("G", []), .down([]))
            #expect(tui.sidebarLine(containing: "will be deleted")?.text.hasPrefix("▸") == true,
                    "\(tui.sidebarText)")
        }

        // Add offers a project, a workspace and a task; Tools lists the tools, those that
        // live only in the GUI saying so. Choosing one that is not here yet says why and
        // leaves the menu open.
        @Test func addAndToolsOpenTheirMenus() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.char("G", []), .down([]))
            let foot = try #require(tui.sidebarLine(containing: "+ Add"), "\(tui.sidebarText)")
            #expect(foot.text.hasPrefix("▸+ Add"), "\(foot.text)")
            #expect(foot.style(of: "+ Add")?.inverse == true)
            #expect(foot.style(of: "⚙ Tools")?.inverse != true)
            await tui.press(.enter([]))
            #expect(tui.frame[0].text == " Add", "\(tui.text)")
            #expect(tui.line(containing: "▸ Add project…") != nil, "\(tui.text)")
            #expect(tui.contains("Create workspace…") && tui.contains("New task…"), "\(tui.text)")
            await tui.press(.escape)

            await tui.press(.down([]), .enter([]))
            #expect(tui.frame[0].text == " Tools", "\(tui.text)")
            for tool in ["MCP servers", "Skills", "Docker", "Dispatch"] {
                #expect(tui.line(containing: tool)?.text.contains("open in the GUI") == true, "\(tui.text)")
            }
            // It opens on Shortcuts, the first tool the terminal has.
            #expect(tui.line(containing: "Shortcuts")?.text.contains("▸") == true, "\(tui.text)")
            await tui.press(.char("g", []), .enter([]))
            #expect(tui.frame[0].text == " Tools", "\(tui.text)")
            #expect(tui.frame.last?.text.contains("open in the GUI") == true, "\(tui.text)")
            await tui.press(.char("q", []))
            #expect(tui.sidebarLine(containing: "⚙ Tools") != nil, "\(tui.text)")

            // Settings opens the settings screen.
            await tui.press(.enter([]), .char("G", []), .enter([]))
            #expect(await waitUntil { tui.frame.first?.text.contains("Settings") == true && !tui.contains("MCP servers") },
                    "\(tui.text)")
        }

        // `a` opens the row's actions: a session's as its context menu lists them in the
        // GUI, a project's with New session reaching the new-session form for it.
        @Test func aOpensTheRowsActionsMenu() async throws {
            let tui = try TUIHarness(agentScript: "exit 0")
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.char("a", []))
            #expect(tui.frame[0].text == " Fix the login bug", "\(tui.text)")
            #expect(tui.frame[1].text == " alpha", "\(tui.text)")
            let entries = ["▸ Open", "Pin", "Mark as unread", "Rename…", "Regenerate session title", "Delete session"]
            let rows = entries.map { entry in tui.frame.firstIndex { $0.text.contains(entry) } }
            #expect(rows.allSatisfy { $0 != nil }, "\(tui.text)")
            #expect(rows.compactMap { $0 } == rows.compactMap { $0 }.sorted(), "\(tui.text)")
            #expect(tui.line(containing: "Delete session")?.style(of: "Delete session")?.foreground == .basic(31))
            await tui.press(.enter([]))
            #expect(await waitUntil { tui.mainText.contains("alpha / Fix the login bug") }, "\(tui.mainText)")

            await tui.press(.char("o", .ctrl), .char("g", []), .char("a", []))
            #expect(tui.frame[0].text == " alpha", "\(tui.text)")
            #expect(tui.contains("Remove project") && tui.contains("Clear idle sessions"), "\(tui.text)")
            // The first entry the terminal can do is the one pointed at.
            #expect(tui.line(containing: "Pin")?.text.contains("▸") == true, "\(tui.text)")
            await tui.press(.down([]), .down([]))
            #expect(tui.line(containing: "New session")?.text.contains("▸") == true, "\(tui.text)")
            await tui.press(.enter([]))
            #expect(tui.frame[0].text == " New session", "\(tui.text)")
        }

        // A deletion in the menu asks first, with what goes and what stays, the subject
        // tile at the top and the warning; Esc keeps everything and Enter goes ahead.
        @Test func aDeletionAsksWithTheImpactConfirmation() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            var deleted: [String] = []
            tui.addRowAction { target in
                guard case .row(.session(let row, let container)) = target else { return [] }
                let confirmation = ImpactConfirmation(
                    "Delete “\(row.title)”?", subject: .init(name: container.name, kind: container.kind),
                    rows: [.init("The conversation", "Every message in it"),
                           .init("The project folder", "Your files are not touched", kept: true)],
                    warning: "This cannot be undone.", action: "Delete session")
                return [MenuAction("Delete for good", destructive: true,
                                   .confirm(confirmation, then: { deleted.append(row.title) }))]
            }

            await tui.press(.char("a", []), .char("G", []), .enter([]))
            #expect(tui.frame[0].text == " ■ alpha", "\(tui.text)")
            #expect(tui.frame[1].text == " Delete “Fix the login bug”?", "\(tui.text)")
            let goes = try #require(tui.line(containing: "The conversation"), "\(tui.text)")
            #expect(goes.text.hasPrefix(" − "), "\(goes.text)")
            #expect(goes.style(of: "−")?.foreground == .basic(31))
            let stays = try #require(tui.line(containing: "The project folder"), "\(tui.text)")
            #expect(stays.text.hasPrefix(" ✓ "), "\(stays.text)")
            #expect(stays.style(of: "✓")?.foreground == .basic(32))
            #expect(tui.line(containing: "This cannot be undone.")?.style(of: "This cannot be undone.")?.foreground
                    == .basic(31))
            let buttons = try #require(tui.line(containing: "[ Delete session ]"), "\(tui.text)")
            #expect(buttons.style(of: "[ Delete session ]")?.inverse == true)
            #expect(buttons.style(of: "[ Cancel ]")?.inverse != true)

            await tui.press(.escape)
            #expect(deleted.isEmpty)
            #expect(tui.sidebarLine(containing: "Fix the login bug") != nil, "\(tui.text)")

            // Tab to Cancel and Enter keeps everything too.
            await tui.press(.char("a", []), .char("G", []), .enter([]), .tab([]))
            #expect(tui.line(containing: "[ Cancel ]")?.style(of: "[ Cancel ]")?.inverse == true)
            await tui.press(.enter([]))
            #expect(deleted.isEmpty)

            await tui.press(.char("a", []), .char("G", []), .enter([]), .enter([]))
            #expect(deleted == ["Fix the login bug"])
            #expect(tui.sidebarLine(containing: "Fix the login bug") != nil, "\(tui.text)")
        }

        // The host starting to hand the station over shows a banner in the sidebar until
        // the client is listing from the next host.
        @Test func aHandoverShowsABannerUntilTheNextHostServes() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            let socket = StationSocketPath.usable(tui.scratch.path("s.sock").path)
            let server = StationSocketServer(station: tui.commands)
            _ = try server.start(at: socket)
            let client = StationSocketClient(path: socket)
            defer { client.close() }
            try await tui.start(over: client)
            #expect(await waitUntil { tui.commands.hostEventListeners == 1 })

            tui.commands.letGo = {}
            _ = try tui.commands.handOver(to: "the Code Station app")

            #expect(await tui.waitFor("The station is moving to the"), "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Code Station app…") != nil, "\(tui.sidebarText)")
            let banner = try #require(tui.sidebarLine(containing: "The station is moving"))
            #expect(banner.style(of: "The station is moving")?.foreground == .basic(33))

            // The next host serves the same store on the same socket; the client follows.
            server.stop()
            let next = StationCommands(store: tui.store, runner: tui.runner, refreshInterval: .milliseconds(50),
                                       preferences: tui.preferences)
            let nextServer = StationSocketServer(station: next)
            _ = try nextServer.start(at: socket)
            defer { nextServer.stop() }

            #expect(await waitUntil { !tui.sidebarText.contains("The station is moving") }, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Fix the login bug") != nil, "\(tui.sidebarText)")
        }

        // The host that comes back is from another build and refuses this terminal. The
        // terminal says why, rather than freezing on the last list it had.
        @Test func aHostThatRefusesTheReconnectIsShown() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            let socket = StationSocketPath.usable(tui.scratch.path("s.sock").path)
            let server = StationSocketServer(station: tui.commands)
            _ = try server.start(at: socket)
            let client = StationSocketClient(endpoint: { socket }, retryInterval: .milliseconds(20))
            defer { client.close() }
            try await tui.start(over: client)

            server.stop()
            let next = StationCommands(store: tui.store, runner: tui.runner, refreshInterval: .milliseconds(50),
                                       preferences: tui.preferences)
            let newer = StationSocketServer(station: next,
                                            version: StationWire.Version(protocolVersion: 99, build: "9.9.9 (999)"))
            _ = try newer.start(at: socket)
            defer { newer.stop() }

            let said = { tui.sidebar.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            #expect(await waitUntil { said().contains("cannot talk to the station host") }, "\(tui.sidebarText)")
        }

        // The host holding the station takes the connection but never answers (busy
        // handing over as it quits). The terminal says so instead of a blank frame, and
        // the notice goes once a host that answers takes the station.
        @Test func aHostThatDoesNotAnswerIsShownUntilOneDoes() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            let lockFile = tui.scratch.path("host.lock")
            let stuck = try #require(StationLock.claim(.gui, at: lockFile).lock)
            let silentPath = StationSocketPath.usable(tui.scratch.path("silent.sock").path)
            let silent = try UnixSocket.listen(at: silentPath)
            defer { Darwin.close(silent) }
            stuck.advertise(silentPath)
            let client = StationSocketClient(lockFile: lockFile, retryInterval: .milliseconds(20),
                                             patience: .init(handshake: .milliseconds(200), namingHolder: .seconds(30)))
            defer { client.close() }
            try await tui.start(over: client, settling: false)

            let said = { tui.sidebar.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            #expect(await waitUntil { said().contains("The station isn't answering") }, "\(tui.text)")

            stuck.release()
            let lock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
            defer { lock.release() }
            let server = StationSocketServer(station: tui.commands)
            lock.advertise(try server.start(at: StationSocketPath.usable(tui.scratch.path("s.sock").path)))
            defer { server.stop() }

            #expect(await waitUntil { tui.sidebarLine(containing: "Fix the login bug") != nil }, "\(tui.text)")
            #expect(!said().contains("isn't answering"), "\(tui.sidebarText)")
        }
    }
}
