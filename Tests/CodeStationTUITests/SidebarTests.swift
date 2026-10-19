import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The sidebar: the GUI's tree of tasks, workspaces and projects with their session
    // cards, arranged by the shared sort and grouping, beside the top bar and main pane.
    @MainActor
    @Suite
    struct SidebarTests {

        @Test func theSidebarListsContainersAndSessionCardsBesideTheMainPane() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)

            try await tui.start()

            let border = try #require(tui.borderColumn, "\(tui.text)")
            #expect(border == 32)
            #expect(tui.sidebar[0].text == " Code Station", "\(tui.sidebarText)")
            #expect(tui.sidebar[0].style(of: "Code Station")?.bold == true)
            #expect(tui.sidebar[1].text == " Name, A to Z · Ungrouped")
            let container = try #require(tui.sidebarLine(containing: "alpha"), "\(tui.sidebarText)")
            // The disclosure at the end says the container is open.
            #expect(container.text.hasPrefix("  ■ alpha "))
            #expect(container.text.hasSuffix(" ▾"))
            #expect(container.style(of: "alpha")?.bold == true)
            let card = try #require(tui.sidebarLine(containing: "Fix the login bug"), "\(tui.sidebarText)")
            // The first session is selected, and the sidebar has the keys.
            #expect(card.text.hasPrefix("▸ │ Fix the login bug"))
            #expect(card.style(of: "Fix the login bug")?.inverse == true)
            let state = try #require(tui.sidebarRows(of: ["Fix the login bug"]).first ?? nil)
            #expect(tui.sidebar[state + 1].text == "  │ IDLE · now")
            #expect(tui.sidebar.last?.text.contains("? keys") == true)
            // The top bar is empty until it has something to say, and the main pane shows
            // Home until a session opens.
            #expect(tui.main[0].text.isEmpty, "\(tui.mainText)")
            #expect(tui.mainPane.first?.text == " Home", "\(tui.mainText)")
        }

        @Test func byTypeSplitsTheTreeIntoTasksWorkspacesAndProjects() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            Preferences.setProjectGrouping(.kind, in: tui.preferences)
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addTask("nightly")
            let both = try tui.addWorkspace("both", of: [alpha, beta])
            try tui.addSession("Cross repo change", in: both)
            try tui.addSession("Fix the login bug", in: alpha)
            // The workspace, first with a session, is the current container; alpha is
            // opened as the GUI remembers it.
            Preferences.setSidebarExpansion([alpha.id: true], in: tui.preferences)

            try await tui.start()

            #expect(tui.sidebar[1].text == " Name, A to Z · By type", "\(tui.sidebarText)")
            let rows = tui.sidebarRows(of: ["TASKS", "□ nightly", "WORKSPACES", "▤ both", "Cross repo change",
                                            "PROJECTS", "■ alpha", "Fix the login bug", "■ beta"])
            #expect(rows.allSatisfy { $0 != nil }, "\(tui.sidebarText)")
            let found = rows.compactMap { $0 }
            #expect(found == found.sorted(), "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "TASKS")?.style(of: "TASKS")?.bold == true)
        }

        @Test func noGroupingListsEveryContainerInOneRunWithoutHeadings() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addTask("nightly")
            _ = try tui.addWorkspace("both", of: [alpha, beta])

            try await tui.start()

            let rows = tui.sidebarRows(of: ["■ alpha", "■ beta", "▤ both", "□ nightly"])
            #expect(rows.allSatisfy { $0 != nil }, "\(tui.sidebarText)")
            let found = rows.compactMap { $0 }
            #expect(found == found.sorted(), "\(tui.sidebarText)")
            #expect(!tui.sidebarText.contains("PROJECTS"))
        }

        @Test func lastUsedPutsTheNewestWorkFirstAndPinnedAboveAll() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            Preferences.setProjectSort(.lastUsed, in: tui.preferences)
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            let gamma = try tui.addProject("gamma")
            try tui.addSession("Old work", in: alpha, ago: 3 * 3_600)
            try tui.addSession("New work", in: beta, ago: 120)
            tui.store.setPinned(true, forProject: gamma.id)
            Preferences.setSidebarExpansion([alpha.id: true], in: tui.preferences)

            try await tui.start()

            #expect(tui.sidebar[1].text == " Last used · Ungrouped", "\(tui.sidebarText)")
            let rows = tui.sidebarRows(of: ["gamma", "beta", "New work", "alpha", "Old work"]).compactMap { $0 }
            #expect(rows.count == 5 && rows == rows.sorted(), "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "gamma")?.text == "  ■ gamma ⚑")
            let newRow = try #require(tui.sidebarRows(of: ["New work"]).first ?? nil)
            #expect(tui.sidebar[newRow + 1].text == "  │ IDLE · 2m", "\(tui.sidebarText)")
            let oldRow = try #require(tui.sidebarRows(of: ["Old work"]).first ?? nil)
            #expect(tui.sidebar[oldRow + 1].text == "  │ IDLE · 3h", "\(tui.sidebarText)")
        }

        @Test func aPinnedSessionComesFirstInItsContainerWithAPinForItsNode() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let older = try tui.addSession("Older", in: alpha, ago: 3_600)
            try tui.addSession("Newer", in: alpha, ago: 60)
            tui.store.setPinned(true, forSession: older.id)

            try await tui.start()

            let rows = tui.sidebarRows(of: ["Older", "Newer"]).compactMap { $0 }
            #expect(rows.count == 2 && rows[0] < rows[1], "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Older")?.text.hasSuffix(" ⚑ Older") == true, "\(tui.sidebarText)")
        }

        // The GUI's settings write the shared preferences; the tree follows them.
        @Test func changingTheSortInTheGUIReordersTheTree() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Old work", in: alpha, ago: 3_600)
            try tui.addSession("New work", in: beta, ago: 60)
            try await tui.start()
            let before = tui.sidebarRows(of: ["■ alpha", "■ beta"]).compactMap { $0 }
            #expect(before.count == 2 && before[0] < before[1], "\(tui.sidebarText)")

            Preferences.setProjectSort(.lastUsed, in: tui.preferences)
            Preferences.setProjectGrouping(.kind, in: tui.preferences)

            #expect(await waitUntil {
                let after = tui.sidebarRows(of: ["■ beta", "■ alpha"]).compactMap { $0 }
                return after.count == 2 && after[0] < after[1] && tui.sidebarText.contains("PROJECTS")
            }, "\(tui.sidebarText)")
        }

        // MARK: - Cards

        @Test func anUnreadSessionAsksForThePersonInAmberWithAMarkOnItsNode() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Quiet", in: alpha, ago: 30)
            let done = try tui.addSession("Finished", in: alpha, ago: 60)
            tui.store.setMarkedUnread(true, for: done.id)

            try await tui.start()

            let card = try #require(tui.sidebarLine(containing: "Finished"), "\(tui.sidebarText)")
            #expect(card.text.hasSuffix(" ● Finished"))
            #expect(card.style(of: "●")?.foreground == .basic(33))
            #expect(card.style(of: "Finished")?.bold == true)
            let row = try #require(tui.sidebarRows(of: ["Finished"]).first ?? nil)
            let state = tui.sidebar[row + 1]
            #expect(state.text == "  │ NEEDS YOU · 1m", "\(tui.sidebarText)")
            #expect(state.style(of: "NEEDS YOU")?.foreground == .basic(33))
            let quietRow = try #require(tui.sidebarRows(of: ["Quiet"]).first ?? nil)
            let quiet = tui.sidebar[quietRow + 1]
            #expect(quiet.style(of: "IDLE")?.dim == true)
            #expect(quiet.style(of: "IDLE")?.foreground == nil)
        }

        @Test func aRunningTurnIsGreenAndAFailedOneRed() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            wait_for "$folder/release"
            echo "the model is unavailable" >&2
            exit 3
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Busy", in: alpha)
            try await tui.start()

            tui.runner.send("hello", sessionID: session.id, store: tui.store)

            #expect(await waitUntil { tui.sidebarText.contains("RUNNING") }, "\(tui.sidebarText)")
            let running = try #require(tui.sidebarLine(containing: "RUNNING"))
            #expect(running.style(of: "RUNNING")?.foreground == .basic(32))

            try Data().write(to: tui.scratch.path("release"))

            #expect(await waitUntil { tui.sidebarText.contains("FAILED") }, "\(tui.sidebarText)")
            let failed = try #require(tui.sidebarLine(containing: "FAILED"))
            #expect(failed.style(of: "FAILED")?.foreground == .basic(31))
        }

        // MARK: - Keys

        @Test func arrowsAndVimKeysWalkContainersAndSessions() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("First", in: alpha)
            try tui.addSession("Second", in: beta)
            Preferences.setSidebarExpansion([beta.id: true], in: tui.preferences)
            try await tui.start()
            #expect(tui.sidebarLine(containing: "First")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")

            await tui.press(.char("j", []))
            #expect(tui.sidebarLine(containing: "beta")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.down([]))
            #expect(tui.sidebarLine(containing: "Second")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.char("k", []), .up([]))
            #expect(tui.sidebarLine(containing: "First")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.char("k", []))
            #expect(tui.sidebarLine(containing: "alpha")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "alpha")?.style(of: "alpha")?.inverse == true)
            // Left and right step from container to container.
            await tui.press(.char("l", []))
            #expect(tui.sidebarLine(containing: "beta")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.left([]))
            #expect(tui.sidebarLine(containing: "alpha")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.char("G", []))
            #expect(tui.sidebarLine(containing: "Second")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
        }

        // Enter opens the session in the main pane beside the sidebar, which keeps its
        // place; the focus key moves between the two.
        @Test func enterOpensTheSessionInTheMainPaneAndTheFocusKeyMovesBetweenThem() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha, messages: [
                ChatMessage(role: .user, text: "Why does login fail?")
            ])
            try tui.addSession("Write the docs", in: alpha, ago: 3_600)
            try await tui.start()

            await tui.press(.enter([]))

            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Fix the login bug") == true, "\(tui.mainText)")
            #expect(tui.mainLine(containing: "Why does login fail?") != nil, "\(tui.mainText)")
            // The sidebar still shows, with the session selected but the keys in the main pane.
            let card = try #require(tui.sidebarLine(containing: "Fix the login bug"), "\(tui.sidebarText)")
            #expect(card.text.hasPrefix("▸"))
            #expect(card.style(of: "Fix the login bug")?.inverse != true)

            await tui.press(.char("o", .ctrl))
            #expect(tui.sidebarLine(containing: "Fix the login bug")?.style(of: "Fix the login bug")?.inverse == true)
            await tui.press(.char("j", []))
            #expect(tui.sidebarLine(containing: "Write the docs")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            // The open session stays in the main pane while the sidebar moves.
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Fix the login bug") == true, "\(tui.mainText)")

            await tui.press(.enter([]))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Write the docs") == true, "\(tui.mainText)")

            // Going back from the session gives the sidebar the keys and leaves it open.
            await tui.press(.escape)
            #expect(tui.sidebarLine(containing: "Write the docs")?.style(of: "Write the docs")?.inverse == true)
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Write the docs") == true, "\(tui.mainText)")
        }

        // Enter on a container opens its screen in the main pane (see ContainerScreenTests).
        @Test func enterOnAContainerOpensItsScreen() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.char("k", []), .enter([]))

            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha") == true, "\(tui.mainText)")
            #expect(tui.mainPane.first?.text.hasPrefix(" SESSIONS") == true, "\(tui.mainText)")
        }
    }
}
