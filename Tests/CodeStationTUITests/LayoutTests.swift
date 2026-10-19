import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The frame the TUI opens on, driven from keys to the drawn frame: the sidebar, the top
    // bar and the main pane, how they follow the station and the terminal's size, and
    // quitting.
    @MainActor
    @Suite
    struct LayoutTests {

        @Test func anEmptyStationSaysWhereToAddAProject() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }

            try await tui.start()

            #expect(tui.sidebarLine(containing: "No projects yet.") != nil, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Add below") != nil, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "+ Add") != nil, "\(tui.text)")
        }

        // A session renamed in the station shows in the sidebar without a key being pressed.
        @Test func followsTheStationAsItChanges() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Old title", in: alpha)
            try await tui.start()

            tui.store.renameSession(session.id, to: "New title")

            #expect(await tui.waitFor("New title"), "\(tui.text)")
            #expect(!tui.contains("Old title"))
        }

        // The sidebar narrows with the terminal, and the main pane takes what is left.
        @Test func aResizeRepaintsTheRegionsAtTheNewWidth() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 20))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            #expect(tui.borderColumn == 34, "\(tui.text)")

            tui.resize(cols: 60, rows: 12)

            #expect(tui.frame.count == 12)
            #expect(tui.borderColumn == 24, "\(tui.text)")
            let card = try #require(tui.sidebarLine(containing: "Fix the login"), "\(tui.text)")
            #expect(card.text.count <= 24)
            #expect(tui.sidebar[11].text.contains("move"))
        }

        // Quitting puts the terminal back the way it was found before the process ends.
        @Test func qPutsTheTerminalBackAndEnds() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            try await tui.start()
            #expect(tui.terminal.screen.alternateScreen)

            await tui.press(.char("q", []))

            #expect(tui.exited)
            #expect(!tui.terminal.isRunning)
            #expect(!tui.terminal.screen.alternateScreen)
            #expect(tui.terminal.screen.cursorVisible)
        }
    }
}
