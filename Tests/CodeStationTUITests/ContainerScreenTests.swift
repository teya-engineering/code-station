import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Project, workspace and task screens: Enter on a container in the sidebar opens its
    // screen in the main pane, with a top bar of its own naming it and a status strip
    // under that, as the GUI's detail screens have, over the list of its sessions.
    @MainActor
    @Suite
    struct ContainerScreenTests {

        private func selectContainer(_ name: String, in tui: TUIHarness) async throws {
            let isSelected = { (tui: TUIHarness) -> Bool in
                guard let row = tui.sidebarLine(containing: "▸ ")?.text.trimmingCharacters(in: .whitespaces) else {
                    return false
                }
                return row.contains(" \(name) ") || row.hasSuffix(" \(name)")
            }
            await tui.press(.char("g", []))
            for _ in 0..<12 where !isSelected(tui) { await tui.press(.down([])) }
            try #require(isSelected(tui), "\(tui.sidebarText)")
        }

        private func paneLine(containing fragment: String, in tui: TUIHarness) -> String? {
            tui.mainPane.first { $0.text.contains(fragment) }?.text
        }

        @Test func aProjectScreenShowsItsCheckoutAndSessions() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["README.md": "one\n"])
            try "two\n".write(to: alpha.url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try tui.addSession("Fix the login bug", in: alpha, ago: 120)
            try await tui.start()
            try await selectContainer("alpha", in: tui)

            await tui.press(.enter([]))

            #expect(tui.topBar.count == 2, "\(tui.topBarText)")
            #expect(tui.topBar[0].text.hasPrefix(" ■ alpha"), "\(tui.topBarText)")
            #expect(tui.topBar[0].style(of: "alpha")?.bold == true)
            #expect(await waitUntil { tui.topBar[1].text.contains("1 UNCOMMITTED FILE") }, "\(tui.topBarText)")
            let strip = tui.topBar[1]
            #expect(strip.text.hasPrefix(" ⎇ main"), "\(strip.text)")
            #expect(strip.style(of: "1 UNCOMMITTED FILE")?.foreground == .basic(33))
            #expect(strip.text.hasSuffix("JUST NOW · first"), "\(strip.text)")
            #expect(tui.mainPane[0].text.hasPrefix(" SESSIONS"), "\(tui.text)")
            let card = try #require(tui.mainLine(containing: "Fix the login bug"), "\(tui.text)")
            #expect(card.text.contains("IDLE · 2m"), "\(card.text)")

            // Enter on a session opens it; back returns to the project screen.
            await tui.press(.enter([]))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Fix the login bug") == true, "\(tui.topBarText)")
            await tui.press(.char("[", []))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha") == true, "\(tui.topBarText)")
            #expect(tui.mainPane[0].text.hasPrefix(" SESSIONS"), "\(tui.text)")

            // Esc gives the sidebar the keys and leaves the screen where it is.
            await tui.press(.escape)
            #expect(tui.mainPane[0].text.hasPrefix(" SESSIONS"), "\(tui.text)")
            #expect(tui.sidebarLine(containing: "▸ ")?.text.contains("alpha") == true, "\(tui.sidebarText)")
        }

        @Test func aCleanProjectSaysSo() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            try tui.addProject("alpha", committing: ["README.md": "one\n"])
            try await tui.start()
            try await selectContainer("alpha", in: tui)

            await tui.press(.enter([]))

            #expect(await waitUntil { tui.topBar[1].text.contains("CLEAN") }, "\(tui.topBarText)")
            #expect(tui.mainLine(containing: "No sessions yet") != nil, "\(tui.text)")
        }

        @Test func aWorkspaceScreenListsItsProjectsLeadFirst() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["README.md": "one\n"])
            let beta = try tui.addProject("beta")
            let both = try tui.addWorkspace("both", of: [alpha, beta])
            try tui.addSession("Cross repo change", in: both)
            try await tui.start()
            try await selectContainer("both", in: tui)

            await tui.press(.enter([]))

            #expect(tui.topBar[0].text.hasPrefix(" ▤ both"), "\(tui.topBarText)")
            #expect(await waitUntil { tui.topBar[1].text.contains("alpha · main") }, "\(tui.topBarText)")
            #expect(tui.topBar[1].text.hasPrefix(" WORKSPACE · 2 PROJECTS"), "\(tui.topBarText)")
            #expect(tui.mainPane[0].text.hasPrefix(" PROJECTS"), "\(tui.text)")
            #expect(paneLine(containing: "alpha", in: tui)?.contains("lead") == true, "\(tui.text)")
            #expect(paneLine(containing: "beta", in: tui)?.contains("not a git repository") == true, "\(tui.text)")
            #expect(tui.mainLine(containing: "Cross repo change") != nil, "\(tui.text)")
        }

        @Test func aTaskScreenCountsItsRunsAndInputs() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let nightly = try tui.store.addTask(named: "nightly", prompt: "Check {{branch}} on {{host}}",
                                                in: tui.scratch.path("tasks")).get()
            var schedule = TaskSchedule()
            schedule.isEnabled = true
            schedule.interval = 15
            schedule.intervalUnit = .minutes
            schedule.restart(at: Date())
            var spec = try #require(nightly.task)
            spec.schedule = schedule
            tui.store.setTaskSpec(spec, for: nightly.id)
            try tui.addSession("Last night", in: nightly, ago: 60)
            try await tui.start()
            try await selectContainer("nightly", in: tui)

            await tui.press(.enter([]))

            #expect(tui.topBar[0].text.hasPrefix(" □ nightly"), "\(tui.topBarText)")
            #expect(await waitUntil { tui.topBar[1].text.contains("1 RUN · 2 INPUTS") }, "\(tui.topBarText)")
            #expect(tui.topBar[1].text.hasPrefix(" IDLE · 1m"), "\(tui.topBarText)")
            #expect(tui.topBar[1].text.contains("Next run in 1"), "\(tui.topBarText)")
            // The body is the task's own screen: its prompt first, its runs below.
            #expect(await waitUntil { tui.mainPane[0].text.hasPrefix(" PROMPT") }, "\(tui.text)")
            #expect(tui.mainText.contains(" RUNS 1"), "\(tui.text)")
        }

        // The palette goes to a project's screen too.
        @Test func thePaletteOpensAProjectsScreen() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addProject("beta")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.char("k", .ctrl))
            await tui.type("beta")
            await tui.press(.enter([]))

            #expect(tui.topBar.first?.text.hasPrefix(" ■ beta") == true, "\(tui.topBarText)")
            #expect(tui.sidebarLine(containing: "beta")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
        }
    }
}
