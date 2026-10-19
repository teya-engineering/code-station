import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // The command palette: Ctrl-K from anywhere letters are keys, then typing narrows
    // sessions, projects and actions, and Enter goes to the one picked.
    @MainActor
    @Suite
    struct PaletteTests {

        @Test func ctrlKListsSessionsProjectsAndActionsUnderHeadings() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addTask("nightly")
            let done = try tui.addSession("Fix the login bug", in: alpha, ago: 120)
            tui.store.setMarkedUnread(true, for: done.id)
            try tui.addSession("Write the docs", in: alpha, ago: 3_600)
            try await tui.start()

            await tui.press(.char("k", .ctrl))

            #expect(tui.frame[0].text == " Go to", "\(tui.text)")
            let rows = tui.frame.map(\.text)
            func row(_ fragment: String) -> Int? { rows.firstIndex { $0.contains(fragment) } }
            let order = [row("NEEDS YOU"), row("Fix the login bug"), row("RECENT"), row("Write the docs"),
                         row("PROJECTS"), row("■ alpha"), row("□ nightly"), row("ACTIONS"), row("New session")]
            #expect(order.allSatisfy { $0 != nil }, "\(tui.text)")
            let found = order.compactMap { $0 }
            #expect(found == found.sorted(), "\(tui.text)")
            // The first result is picked, and each says what kind of thing it is.
            #expect(tui.line(containing: "Fix the login bug")?.text.hasPrefix("▸") == true, "\(tui.text)")
            #expect(tui.line(containing: "Fix the login bug")?.text.contains("REVIEW") == true, "\(tui.text)")
            #expect(tui.line(containing: "nightly")?.text.contains("TASK") == true, "\(tui.text)")

            await tui.press(.escape)
            #expect(!tui.contains("Go to"), "\(tui.text)")
            #expect(tui.sidebar.first?.text == " Code Station", "\(tui.text)")
        }

        // Typed words narrow the list; letters a title holds in order also match, so a
        // few keys reach a session.
        @Test func typingNarrowsByWordsAndByLettersInOrder() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Fix the login bug", in: alpha)
            try tui.addSession("Write the docs", in: beta)
            try await tui.start()
            await tui.press(.char("k", .ctrl))

            await tui.type("beta docs")
            #expect(tui.line(containing: "Write the docs") != nil, "\(tui.text)")
            #expect(tui.line(containing: "Fix the login bug") == nil, "\(tui.text)")
            #expect(tui.frame[1].text.contains("beta docs"), "\(tui.text)")

            await tui.press(.char("u", .ctrl))
            await tui.type("flb")
            #expect(tui.line(containing: "Fix the login bug")?.text.hasPrefix("▸") == true, "\(tui.text)")
            #expect(tui.line(containing: "Write the docs") == nil, "\(tui.text)")

            await tui.press(.char("u", .ctrl))
            await tui.type("zzz")
            #expect(tui.contains("No matching projects, sessions or actions."), "\(tui.text)")
        }

        @Test func enterOnASessionOpensIt() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha, ago: 60)
            try tui.addSession("Write the docs", in: alpha, ago: 3_600)
            try await tui.start()

            await tui.press(.char("k", .ctrl))
            await tui.type("docs")
            await tui.press(.enter([]))

            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Write the docs") == true, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Write the docs")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
        }

        @Test func theNewSessionActionOpensTheForm() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30), agentScript: "exit 0")
            defer { tui.tearDown() }
            try tui.addProject("alpha")
            try await tui.start()

            await tui.press(.char("k", .ctrl))
            await tui.type("new session")
            await tui.press(.enter([]))

            #expect(tui.contains("New session"), "\(tui.text)")
            #expect(tui.contains("alpha"), "\(tui.text)")
            #expect(!tui.contains("Go to"), "\(tui.text)")
        }

        // In the palette `?` is text; its Keys action opens the key list.
        @Test func theKeysActionOpensTheKeyList() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            try await tui.start()

            await tui.press(.char("k", .ctrl))
            await tui.type("?")
            #expect(tui.frame[1].text.contains("?"), "\(tui.text)")
            await tui.press(.char("u", .ctrl))
            await tui.type("keys")
            await tui.press(.enter([]))

            #expect(tui.frame[0].text == " Code Station · Keys", "\(tui.text)")
            // It starts with the keys of the screen under the palette.
            let section = try #require(tui.frame.dropFirst().first { !$0.text.isEmpty })
            #expect(section.text == " Sidebar", "\(tui.text)")
        }

        // While a prompt is written Ctrl-K deletes to the end of the line, as in a shell.
        @Test func ctrlKInThePromptDeletesRatherThanOpening() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("First", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))
            await tui.type("hello")

            await tui.press(.char("a", .ctrl), .char("k", .ctrl))

            #expect(!tui.contains("Go to"), "\(tui.text)")
            #expect(tui.mainLine(containing: "hello") == nil, "\(tui.mainText)")
        }

        // Tab steps through the kinds, as the GUI's pills do.
        @Test func tabNarrowsToOneKindOfResult() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.char("k", .ctrl))

            await tui.press(.tab([]))
            #expect(tui.line(containing: "Sessions")?.style(of: "Sessions")?.inverse == true, "\(tui.text)")
            #expect(tui.line(containing: "Fix the login bug") != nil, "\(tui.text)")
            #expect(!tui.contains("PROJECTS"), "\(tui.text)")

            await tui.press(.tab([]))
            #expect(tui.contains("PROJECTS"), "\(tui.text)")
            #expect(tui.line(containing: "Fix the login bug") == nil, "\(tui.text)")
        }
    }
}
