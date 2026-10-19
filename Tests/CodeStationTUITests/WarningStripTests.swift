import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The strip under the top bar that says why a session cannot work as it is, as the
    // GUI's warning strip does: a missing folder, a lost checkout.
    @MainActor
    @Suite
    struct WarningStripTests {

        @Test func aMissingFolderIsWarnedAboutUnderTheTopBar() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24), agentScript: "exit 0")
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try FileManager.default.removeItem(at: alpha.url)
            try await tui.start()

            await tui.press(.enter([]))

            #expect(tui.topBar.count == 4, "\(tui.topBarText)")
            let strip = tui.topBar[3]
            #expect(strip.text.hasPrefix(" ⚠ Folder not found at "), "\(strip.text)")
            #expect(strip.style(of: "Folder not found")?.foreground == .basic(33))
            #expect(tui.mainPane.contains { $0.text.contains("Nothing here yet.") }, "\(tui.text)")
        }

        @Test func aLostWorktreeIsWarnedAbout() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 160, rows: 24), agentScript: "exit 0")
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let lost = tui.store.newSession(in: alpha.id, worktreePath: tui.scratch.path("gone").path,
                                            worktreeBranch: "feature")
            tui.store.renameSession(lost.id, to: "Lost checkout")
            try await tui.start()

            await tui.press(.enter([]))

            #expect(tui.topBar.count == 4, "\(tui.topBarText)")
            #expect(tui.topBar[3].text.contains("Worktree not found at"), "\(tui.topBarText)")
        }

        @Test func aHealthySessionHasNoStrip() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24), agentScript: "exit 0")
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.enter([]))

            #expect(tui.topBar.count == 3, "\(tui.topBarText)")
            #expect(!tui.contains("⚠"), "\(tui.text)")
        }
    }
}
