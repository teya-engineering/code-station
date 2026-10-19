import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Command shortcuts in the terminal: `!` on a project's screen or in an open session,
    // and Tools › Shortcuts for the Mac's own list, open one screen over everything that
    // lists the saved commands with how each last ran, runs and stops them, shows what a
    // run printed, and adds, edits and removes them through the station.
    @MainActor
    @Suite
    struct ShortcutsTests {

        private func openProject(_ name: String, in tui: TUIHarness) async throws {
            await tui.press(.char("g", []))
            for _ in 0..<12 where tui.sidebarLine(containing: "▸ ")?.text.contains(name) != true {
                await tui.press(.down([]))
            }
            await tui.press(.enter([]))
            try #require(tui.topBar.first?.text.hasPrefix(" ■ \(name)") == true, "\(tui.text)")
        }

        @Test func theProjectStripCountsItsShortcutsAndBangOpensThem() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            _ = tui.commands.shortcuts.add(name: "Tests", text: "swift test", projectID: alpha.id)
            _ = tui.commands.shortcuts.add(name: "Prune", text: "git prune", availableInAllProjects: true)
            _ = tui.commands.shortcuts.add(name: "Docker", text: "docker ps")
            try await tui.start()
            try await openProject("alpha", in: tui)

            #expect(await waitUntil { tui.topBar[1].text.contains("⚡ 2") }, "\(tui.topBarText)")
            #expect(tui.frame.last?.text.contains("! shortcuts") == true, "\(tui.text)")

            await tui.press(.char("!", []))

            #expect(tui.frame[0].text == " Shortcuts · alpha", "\(tui.text)")
            #expect(tui.frame[1].text.contains("Run in alpha's checkout · 2 saved"), "\(tui.text)")
            let tests = try #require(tui.line(containing: "Tests"), "\(tui.text)")
            #expect(tests.text.hasPrefix("  ▸ · Tests"), "\(tests.text)")
            #expect(tests.text.contains("swift test"))
            #expect(tests.text.hasSuffix("Never run"), "\(tests.text)")
            #expect(tui.line(containing: "Prune")?.text.hasSuffix("Never run · all projects") == true, "\(tui.text)")
            #expect(!tui.contains("Docker"))
            #expect(tui.frame.last?.text.contains("enter run") == true)

            await tui.press(.escape)
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha") == true, "\(tui.text)")
        }

        @Test func runningAShortcutShowsWhatItPrintsAndHowItEnded() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            _ = tui.commands.shortcuts.add(name: "Greet", text: "echo hello from $(basename $PWD); exit 2",
                                           projectID: alpha.id)
            try await tui.start()
            try await openProject("alpha", in: tui)
            await tui.press(.char("!", []))

            await tui.press(.enter([]))

            #expect(await tui.waitFor("hello from alpha"), "\(tui.text)")
            #expect(await tui.waitFor("EXIT 2"), "\(tui.text)")
            let heading = try #require(tui.line(containing: "─ Output · Greet"), "\(tui.text)")
            #expect(heading.style(of: "EXIT 2")?.foreground == .basic(31))
            let row = try #require(tui.line(containing: "▸ ✗ Greet"), "\(tui.text)")
            #expect(row.text.contains("Failed just now in"), "\(row.text)")
            #expect(row.text.hasSuffix("· exit 2"), "\(row.text)")
            #expect(tui.frame[1].text.contains("1 failed"), "\(tui.text)")

            // Esc hides the output first, then closes.
            await tui.press(.escape)
            #expect(!tui.contains("─ Output"), "\(tui.text)")
            #expect(tui.frame[0].text == " Shortcuts · alpha")
        }

        @Test func aRunningShortcutIsStopped() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let id = try #require(tui.commands.shortcuts.add(name: "Serve", text: "echo serving; sleep 30",
                                                             projectID: alpha.id))
            try await tui.start()
            try await openProject("alpha", in: tui)
            await tui.press(.char("!", []))
            await tui.press(.enter([]))
            #expect(await tui.waitFor("serving"), "\(tui.text)")
            #expect(tui.line(containing: "▸ ● Serve")?.text.contains("Running now") == true, "\(tui.text)")

            await tui.press(.char("s", []))

            #expect(await tui.waitFor("STOPPED"), "\(tui.text)")
            #expect(tui.line(containing: "▸ ■ Serve")?.text.hasSuffix("Stopped") == true, "\(tui.text)")
            #expect(!tui.commands.shortcuts.isRunningAnywhere(id))
        }

        @Test func aShortcutIsAddedFromASessionAndEdited() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 24), agentScript: "exit 0")
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.char("G", []))
            await tui.press(.enter([]))
            #expect(await tui.waitFor("Fix the login bug"))

            await tui.press(.char("!", []))
            #expect(tui.frame[0].text == " Shortcuts · Fix the login bug", "\(tui.text)")
            #expect(tui.contains("Nothing saved yet"), "\(tui.text)")

            await tui.press(.char("n", []))
            #expect(tui.frame[0].text == " New shortcut", "\(tui.text)")
            #expect(tui.line(containing: "Where")?.text.contains("‹ Only alpha ›") == true, "\(tui.text)")
            await tui.type("Tests")
            await tui.press(.tab([]))
            await tui.type("swift test")
            await tui.press(.enter([]))

            #expect(tui.frame[0].text == " Shortcuts · Fix the login bug", "\(tui.text)")
            #expect(tui.line(containing: "▸ · Tests")?.text.contains("swift test") == true, "\(tui.text)")
            let saved = try #require(tui.commands.shortcuts.shortcuts.first)
            #expect(saved.name == "Tests")
            #expect(saved.projectID == alpha.id)

            await tui.press(.char("e", []))
            #expect(tui.frame[0].text == " Edit Tests", "\(tui.text)")
            await tui.press(.tab([]))
            await tui.type(" --parallel")
            await tui.press(.tab([]))
            await tui.press(.right([]))
            #expect(tui.line(containing: "Where")?.text.contains("‹ All projects ›") == true, "\(tui.text)")
            await tui.press(.enter([]))

            let edited = try #require(tui.commands.shortcuts.shortcut(saved.id))
            #expect(edited.text == "swift test --parallel")
            #expect(edited.availableInAllProjects)
            #expect(tui.line(containing: "▸ · Tests")?.text.contains("all projects") == true, "\(tui.text)")
        }

        @Test func removingAShortcutAsksFirst() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let id = try #require(tui.commands.shortcuts.add(name: "Tests", text: "swift test", projectID: alpha.id))
            try await tui.start()
            try await openProject("alpha", in: tui)
            await tui.press(.char("!", []))

            await tui.press(.char("x", []))

            #expect(tui.contains("Remove Tests?"), "\(tui.text)")
            #expect(tui.contains("− Saved command"), "\(tui.text)")
            #expect(tui.contains("✓ Projects and conversations"), "\(tui.text)")
            #expect(tui.contains("This shortcut cannot be restored after removal."), "\(tui.text)")
            await tui.press(.escape)
            #expect(tui.commands.shortcuts.shortcut(id) != nil)

            await tui.press(.char("x", []))
            await tui.press(.char("y", []))

            #expect(tui.commands.shortcuts.shortcut(id) == nil)
            #expect(await tui.waitFor("Nothing saved yet"), "\(tui.text)")
        }

        @Test func toolsOpensTheMacsOwnList() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 120, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            _ = tui.commands.shortcuts.add(name: "Tests", text: "swift test", projectID: alpha.id)
            _ = tui.commands.shortcuts.add(name: "Docker", text: "docker ps")
            try await tui.start()

            await tui.press(.char("G", []), .down([]), .down([]), .enter([]))
            #expect(tui.frame[0].text == " Tools", "\(tui.text)")
            let entry = try #require(tui.line(containing: "▸ Shortcuts"), "\(tui.text)")
            #expect(!entry.text.contains("in the GUI"), "\(entry.text)")
            await tui.press(.enter([]))

            #expect(tui.frame[0].text == " Shortcuts · This Mac", "\(tui.text)")
            #expect(tui.frame[1].text.contains("Run from your home folder · 1 saved"), "\(tui.text)")
            #expect(tui.contains("Docker"))
            #expect(!tui.contains("swift test"))
        }
    }
}
