import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The top bar's tab row over an open session, as the GUI's destination deck: Chat,
    // Design, Troubleshoot, Changes and Explorer, reached with the number keys by
    // position. Tabs whose screens have not reached the terminal yet say so.
    @MainActor
    @Suite
    struct SessionTabsTests {

        @Test func theTabRowNamesEveryTabWithItsNumber() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.enter([]))

            let row = try #require(tui.topBar.dropFirst(2).first, "\(tui.topBarText)")
            #expect(row.text.hasPrefix(" 1 Chat  2 Design  3 Troubleshoot  4 Changes  5 Explorer"), "\(row.text)")
            #expect(row.style(of: "Chat")?.bold == true)
            #expect(row.style(of: "Design")?.bold != true)
            // The transcript is under the whole top bar.
            #expect(tui.mainPane.contains { $0.text.contains("Nothing here yet.") }, "\(tui.text)")
        }

        @Test func numberKeysSwitchTabsByPosition() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha", committing: ["README.md": "hello\n"])
            try "hello\nworld\n".write(to: alpha.url.appendingPathComponent("README.md"),
                                       atomically: true, encoding: .utf8)
            try tui.addSession("Edit the readme", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("4", []))

            #expect(await tui.waitFor("README.md"), "\(tui.text)")
            #expect(tui.mainPane[0].text.hasPrefix(" Changes · Edit the readme · 1 file"), "\(tui.text)")
            #expect(tui.topBar[2].style(of: "Changes")?.bold == true)
            #expect(tui.topBar[2].style(of: "Chat")?.bold != true)

            await tui.press(.char("2", []))

            #expect(await tui.waitFor("canvas: nothing drawn yet"), "\(tui.text)")
            #expect(tui.topBar[2].style(of: "Design")?.bold == true)

            await tui.press(.char("1", []))

            #expect(tui.contains("› write a prompt: enter"), "\(tui.text)")
            #expect(tui.topBar[2].style(of: "Chat")?.bold == true)
        }

        // `d` is still the way to the changes, and Esc from a tab comes back to the chat.
        @Test func escapeFromATabComesBackToTheChat() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("d", []))
            #expect(tui.topBar[2].style(of: "Changes")?.bold == true, "\(tui.topBarText)")

            await tui.press(.escape)
            #expect(tui.topBar[2].style(of: "Chat")?.bold == true, "\(tui.topBarText)")

            await tui.press(.char("3", []))
            #expect(await tui.waitFor("Give your agent a starting point"), "\(tui.text)")

            await tui.press(.escape)
            #expect(tui.contains("› write a prompt: enter"), "\(tui.text)")
        }

        // Numbers typed into a prompt are text, not tabs.
        @Test func numbersInThePromptAreText() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))

            await tui.type("42")

            #expect(tui.contains(" 42"), "\(tui.text)")
            #expect(tui.topBar[2].style(of: "Chat")?.bold == true)
        }
    }
}
