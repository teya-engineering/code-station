import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Folding containers and sections, the GUI's "Sessions shown" limit with See more,
    // what a card says beyond its state, and the sidebar folding away on a narrow
    // terminal or by hand.
    @MainActor
    @Suite
    struct SidebarFoldingTests {

        // MARK: - Folding

        // With nothing stored, the GUI's defaults: the current container (the first
        // session's, before one is opened) and workspaces are open, other projects folded.
        @Test func theCurrentProjectAndWorkspacesStartOpenAndOtherProjectsFolded() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            let both = try tui.addWorkspace("both", of: [alpha, beta])
            try tui.addSession("Alpha work", in: alpha)
            try tui.addSession("Beta work", in: beta)
            try tui.addSession("Cross repo change", in: both)

            try await tui.start()

            #expect(tui.sidebarLine(containing: "Alpha work") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Cross repo change") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Beta work") == nil, "\(tui.sidebarText)")
            // The disclosure says which way each container is.
            #expect(tui.sidebarLine(containing: "■ alpha")?.text.hasSuffix("▾") == true, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "■ beta")?.text.hasSuffix("▸") == true, "\(tui.sidebarText)")
        }

        // What the GUI remembers wins over the defaults.
        @Test func theGUIsStoredFoldingAndCollapsedSectionsSeedTheTree() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            Preferences.setProjectGrouping(.kind, in: tui.preferences)
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            let both = try tui.addWorkspace("both", of: [alpha, beta])
            try tui.addTask("nightly")
            try tui.addSession("Alpha work", in: alpha)
            try tui.addSession("Beta work", in: beta)
            try tui.addSession("Cross repo change", in: both)
            Preferences.setSidebarExpansion([both.id: false, alpha.id: false, beta.id: true], in: tui.preferences)
            Preferences.setCollapsedSidebarGroups([.tasks], in: tui.preferences)

            try await tui.start()

            #expect(tui.sidebarLine(containing: "Beta work") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Alpha work") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Cross repo change") == nil, "\(tui.sidebarText)")
            // A folded section is its heading alone, with its count.
            #expect(tui.sidebarLine(containing: "TASKS")?.text == "  TASKS 1", "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "nightly") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "PROJECTS")?.text == "  PROJECTS", "\(tui.sidebarText)")
        }

        // Space folds and unfolds the container or section under the selection; on a card
        // it folds the card's container and selects it.
        @Test func spaceFoldsAndUnfoldsContainersAndSections() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            Preferences.setProjectGrouping(.kind, in: tui.preferences)
            let alpha = try tui.addProject("alpha")
            try tui.addProject("beta")
            try tui.addSession("Alpha work", in: alpha)
            try await tui.start()
            #expect(tui.sidebarLine(containing: "Alpha work")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")

            await tui.press(.char(" ", []))

            #expect(tui.sidebarLine(containing: "Alpha work") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "■ alpha")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "■ alpha")?.text.hasSuffix("▸") == true, "\(tui.sidebarText)")

            await tui.press(.char(" ", []))
            #expect(tui.sidebarLine(containing: "Alpha work") != nil, "\(tui.sidebarText)")

            // Up to the PROJECTS heading, which folds the whole section away.
            await tui.press(.char("k", []))
            #expect(tui.sidebarLine(containing: "PROJECTS")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.char(" ", []))
            #expect(tui.sidebarLine(containing: "PROJECTS")?.text == "▸ PROJECTS 2", "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "alpha") == nil, "\(tui.sidebarText)")
            // Enter on a heading does the same.
            await tui.press(.enter([]))
            #expect(tui.sidebarLine(containing: "Alpha work") != nil, "\(tui.sidebarText)")
        }

        // MARK: - Sessions shown and See more

        @Test func aContainerShowsTheGUIsNumberOfCardsThenSeeMore() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 80, rows: 30))
            defer { tui.tearDown() }
            Preferences.setSidebarSessionLimit(2, in: tui.preferences)
            let alpha = try tui.addProject("alpha")
            try tui.addSession("One", in: alpha, ago: 60)
            try tui.addSession("Two", in: alpha, ago: 120)
            try tui.addSession("Three", in: alpha, ago: 180)
            try tui.addSession("Four", in: alpha, ago: 240)
            try await tui.start()

            #expect(tui.sidebarLine(containing: "One") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Two") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Three") == nil, "\(tui.sidebarText)")
            let more = try #require(tui.sidebarLine(containing: "See 2 more…"), "\(tui.sidebarText)")
            #expect(more.text == "  ┆ See 2 more…")

            await tui.press(.char("G", []))
            #expect(tui.sidebarLine(containing: "See 2 more…")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.enter([]))

            // Every card shows, and the selection is on the first one See more brought in.
            #expect(tui.sidebarLine(containing: "See") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Four") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Three")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")

            // Folding the container starts its limit over.
            await tui.press(.char(" ", []), .char(" ", []))
            #expect(tui.sidebarLine(containing: "See 2 more…") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Four") == nil, "\(tui.sidebarText)")
        }

        // The open session stays on screen when it falls past the limit: it takes the last
        // card's place, so the container still shows the same number of cards.
        @Test func theOpenSessionReplacesTheLastCardWhenItFallsPastTheLimit() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 80, rows: 30))
            defer { tui.tearDown() }
            Preferences.setSidebarSessionLimit(2, in: tui.preferences)
            let alpha = try tui.addProject("alpha")
            try tui.addSession("One", in: alpha, ago: 60)
            try tui.addSession("Two", in: alpha, ago: 120)
            try tui.addSession("Three", in: alpha, ago: 180)
            try tui.addSession("Four", in: alpha, ago: 240)
            try await tui.start()
            await tui.press(.char("G", []), .enter([]), .char("G", []), .enter([]))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Four") == true, "\(tui.mainText)")

            // Back to the sidebar, fold and unfold alpha: the limit is back, and Four stands
            // in for Two.
            await tui.press(.escape, .char("h", []), .char(" ", []), .char(" ", []))

            let rows = tui.sidebarRows(of: ["One", "Four", "See 2 more…"])
            #expect(rows.allSatisfy { $0 != nil }, "\(tui.sidebarText)")
            #expect(rows.compactMap { $0 } == rows.compactMap { $0 }.sorted(), "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Two") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Three") == nil, "\(tui.sidebarText)")
        }

        // MARK: - Cards

        @Test func cardsShowTheirChipsAndActivityLine() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["README.md": "hello"])
            try "not yet".write(to: alpha.url.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
            let beta = try tui.addProject("beta")
            try tui.addSession("Plain", in: alpha, messages: [
                ChatMessage(role: .assistant, tools: [
                    ToolUse(id: "shell", name: "Bash", input: #"{"command":"swift build"}"#, result: "ok"),
                ]),
            ])
            let isolated = try tui.store.insertSession(in: alpha.id, worktreePath: tui.scratch.path("wt").path,
                                                       worktreeBranch: "feature",
                                                       seed: .init(agent: .claudeCode, isTroubleshooting: true)).get()
            tui.store.renameSession(isolated.id, to: "Isolated")
            let both = try tui.addWorkspace("both", of: [alpha, beta])
            let mixed = try tui.store.insertSession(in: both.id, projects: [
                SessionProject(projectID: alpha.id, worktreePath: tui.scratch.path("wt2").path, worktreeBranch: "x"),
                SessionProject(projectID: beta.id),
            ], seed: .init(agent: .claudeCode)).get()
            tui.store.renameSession(mixed.id, to: "Mixed")

            try await tui.start()

            // Git answers off the main thread, so the uncommitted mark comes a moment later.
            #expect(await waitUntil {
                guard let row = tui.sidebarRows(of: ["Plain"]).first ?? nil else { return false }
                return tui.sidebar[row + 1].text.contains("±")
            }, "\(tui.sidebarText)")
            let plain = try #require(tui.sidebarRows(of: ["Plain"]).first ?? nil)
            #expect(tui.sidebar[plain + 1].text == "  │ IDLE ± · now", "\(tui.sidebarText)")
            #expect(tui.sidebar[plain + 1].style(of: "±")?.foreground == .basic(33))
            #expect(tui.sidebar[plain + 2].text == "  │ last: Bash · swift build", "\(tui.sidebarText)")
            #expect(tui.sidebar[plain + 2].style(of: "last:")?.dim == true)

            let isolatedRow = try #require(tui.sidebarRows(of: ["Isolated"]).first ?? nil)
            #expect(tui.sidebar[isolatedRow + 1].text == "  │ IDLE WT TROUBLESHOOT · now", "\(tui.sidebarText)")
            #expect(tui.sidebar[isolatedRow + 1].style(of: "TROUBLESHOOT")?.foreground == .basic(35))
            let mixedRow = try #require(tui.sidebarRows(of: ["Mixed"]).first ?? nil)
            #expect(tui.sidebar[mixedRow + 1].text == "  │ IDLE MIXED · now", "\(tui.sidebarText)")
            #expect(tui.sidebar[mixedRow + 1].style(of: "MIXED")?.foreground == .basic(33))
        }

        // A folded container says how many of its sessions need the person, and a light
        // while one runs.
        @Test func aFoldedContainerShowsItsNeedsYouCountAndARunningLight() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            wait_for "$folder/release"
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Alpha work", in: alpha)
            let done = try tui.addSession("Finished", in: beta, ago: 60)
            let busy = try tui.addSession("Busy", in: beta, ago: 120)
            tui.store.setMarkedUnread(true, for: done.id)
            try await tui.start()
            #expect(tui.sidebarLine(containing: "Finished") == nil, "\(tui.sidebarText)")

            let folded = try #require(tui.sidebarLine(containing: "■ beta"), "\(tui.sidebarText)")
            #expect(folded.text.hasSuffix(" !1 ▸"), "\(tui.sidebarText)")
            #expect(folded.style(of: "!1")?.foreground == .basic(33))

            tui.runner.send("hello", sessionID: busy.id, store: tui.store)
            #expect(await waitUntil { tui.sidebarLine(containing: "■ beta")?.text.hasSuffix(" !1 ● ▸") == true },
                    "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "■ beta")?.style(of: "●")?.foreground == .basic(32))
            try Data().write(to: tui.scratch.path("release"))
        }

        // MARK: - Hiding and the narrow fold

        // The sidebar key puts the sidebar away and the session takes the whole width; the
        // same key brings it back with the keys.
        @Test func theSidebarKeyHidesAndBringsBackTheSidebar() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(tui.borderColumn == 32, "\(tui.text)")

            await tui.press(.char("b", .ctrl))

            #expect(tui.borderColumn == nil, "\(tui.text)")
            #expect(tui.frame[0].text.contains("■ alpha / Fix"), "\(tui.text)")

            await tui.press(.char("b", .ctrl))

            #expect(tui.borderColumn == 32, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Fix the login bug")?.style(of: "Fix the login bug")?.inverse == true)
        }

        // While a prompt is written Ctrl-B moves back one character, as in a shell, and
        // leaves the sidebar where it is.
        @Test func ctrlBInThePromptMovesBackRatherThanHidingTheSidebar() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("helo")

            await tui.press(.char("b", .ctrl))
            await tui.type("l")

            #expect(tui.borderColumn == 32, "\(tui.text)")
            #expect(tui.mainLine(containing: "hello") != nil, "\(tui.mainText)")
        }

        // Too narrow for both, the sidebar folds away. It opens over the main pane while it
        // has the keys: with nothing open, and with the sidebar key or Esc from a session.
        @Test func aNarrowTerminalFoldsTheSidebarAwayAndTheSidebarKeyOpensItOver() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 40, rows: 16))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            // Nothing is open, so the sidebar is over the main pane.
            #expect(tui.borderColumn == 22, "\(tui.text)")
            #expect(tui.sidebar[0].text == " Code Station", "\(tui.text)")

            await tui.press(.enter([]))

            #expect(tui.borderColumn == nil, "\(tui.text)")
            #expect(tui.frame[0].text.contains("■ alpha / Fix"), "\(tui.text)")

            await tui.press(.char("b", .ctrl))
            #expect(tui.borderColumn == 22, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Fix the login")?.style(of: "Fix the login")?.inverse == true,
                    "\(tui.text)")
            // The session shows in what is left beside it, under its top bar.
            #expect(tui.topBar.first?.text.contains("● IDLE") == true, "\(tui.text)")

            await tui.press(.char("b", .ctrl))
            #expect(tui.borderColumn == nil, "\(tui.text)")

            await tui.press(.escape)
            #expect(tui.borderColumn == 22, "\(tui.text)")
            await tui.press(.enter([]))
            #expect(tui.borderColumn == nil, "\(tui.text)")
        }

        // A session picked in the palette on a narrow terminal closes the sidebar over the
        // main pane, and the sidebar, brought back, has its folded project open on it.
        @Test func aSessionFromThePaletteClosesTheNarrowSidebarAndUnfoldsItsProject() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 40, rows: 16))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Alpha work", in: alpha, ago: 60)
            try tui.addSession("Beta work", in: beta, ago: 3_600)
            try await tui.start()
            #expect(tui.borderColumn == 22, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Beta work") == nil, "\(tui.sidebarText)")

            await tui.press(.char("k", .ctrl))
            await tui.type("beta work")
            await tui.press(.enter([]))

            #expect(await waitUntil { tui.frame[0].text.contains("■ beta / Beta") }, "\(tui.text)")
            #expect(tui.borderColumn == nil, "\(tui.text)")

            await tui.press(.char("b", .ctrl))
            #expect(tui.borderColumn == 22, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Beta work")?.style(of: "Beta work")?.inverse == true,
                    "\(tui.sidebarText)")
        }

        // Narrowing the terminal folds a docked sidebar away; widening it docks it again.
        @Test func resizingAcrossTheThresholdFoldsAndDocksTheSidebar() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            tui.resize(cols: 40, rows: 16)
            #expect(await waitUntil { tui.borderColumn == nil }, "\(tui.text)")
            #expect(tui.frame[0].text.contains("■ alpha / Fix"), "\(tui.text)")

            tui.resize(cols: 80, rows: 24)
            #expect(await waitUntil { tui.borderColumn == 32 }, "\(tui.text)")
        }
    }
}
