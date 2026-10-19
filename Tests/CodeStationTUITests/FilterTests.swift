import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Typing a filter over the sidebar.
    @MainActor
    @Suite
    struct FilterTests {

        @Test func typedWordsNarrowTheListAndShowInTheFooter() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try tui.addSession("Write the docs", in: alpha)
            try await tui.start()

            await tui.press(.char("/", []))
            await tui.type("login")

            #expect(tui.sidebarLine(containing: "Fix the login bug") != nil, "\(tui.text)")
            #expect(tui.sidebarLine(containing: "Write the docs") == nil, "\(tui.text)")
            let footer = try #require(tui.sidebar.last)
            #expect(footer.text.hasPrefix(" / login"))
            #expect(footer.style(of: "/ login")?.bold == true)
            // The cursor waits just after the typed text.
            #expect(tui.terminal.screen.cursorVisible)
            #expect(tui.terminal.screen.cursorRow == 23)
            #expect(tui.terminal.screen.cursorCol == 8)
        }

        @Test func aFilterThatMatchesNothingSaysSo() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()

            await tui.press(.char("/", []))
            await tui.type("zebra")

            #expect(tui.sidebarLine(containing: "Nothing matches “zebra”.") != nil, "\(tui.text)")
        }

        // The GUI's rules: a project stays on its name, a workspace on a member project's
        // name too, with only the sessions that match; a session matches on its title, or
        // a troubleshooting one on "troubleshoot". Every container shows open.
        @Test func theFilterMatchesAsTheGUIsDoes() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Fix the login bug", in: alpha)
            try tui.addSession("Write the docs", in: beta)
            let both = try tui.addWorkspace("both", of: [alpha, beta])
            try tui.addSession("Cross repo change", in: both)
            let probe = try tui.store.insertSession(in: beta.id, seed: .init(agent: .claudeCode,
                                                                                isTroubleshooting: true)).get()
            tui.store.renameSession(probe.id, to: "Why is it slow")
            try await tui.start()

            await tui.press(.char("/", []))
            await tui.type("ALPHA")
            // alpha by its name, with no session matching; the workspace by its member.
            #expect(tui.sidebarLine(containing: "■ alpha") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "▤ both") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "■ beta") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Fix the login bug") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Cross repo change") == nil, "\(tui.sidebarText)")

            await tui.press(.char("u", .ctrl))
            await tui.type("trouble")
            #expect(tui.sidebarLine(containing: "Why is it slow") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Write the docs") == nil, "\(tui.sidebarText)")
            // Matching is on the whole text, not word by word.
            await tui.press(.char("u", .ctrl))
            await tui.type("the docs")
            #expect(tui.sidebarLine(containing: "Write the docs") != nil, "\(tui.sidebarText)")
            await tui.press(.char("u", .ctrl))
            await tui.type("docs write")
            #expect(tui.sidebarLine(containing: "Nothing matches “docs write”.") != nil, "\(tui.sidebarText)")
        }

        // Enter on a container while filtering shows all its sessions, as clicking it does
        // in the GUI; typing again narrows it back.
        @Test func enterOnAContainerWhileFilteringShowsAllItsSessions() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try tui.addSession("Write the docs", in: alpha)
            try await tui.start()

            await tui.press(.char("/", []))
            await tui.type("login")
            await tui.press(.up([]), .enter([]))

            #expect(tui.sidebarLine(containing: "Write the docs") != nil, "\(tui.sidebarText)")
            #expect(tui.sidebar.last?.text.hasPrefix(" / login") == true, "\(tui.sidebarText)")
            await tui.press(.char("/", []))
            await tui.type("x")
            #expect(tui.sidebarLine(containing: "Write the docs") == nil, "\(tui.sidebarText)")
        }

        // The open session's container filtered out: the sidebar says so, and the link
        // under it clears the filter and points at the session.
        @Test func aCurrentSessionOutsideTheFilterIsNamedWithAWayBack() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 30))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Fix the login bug", in: alpha, ago: 60)
            try tui.addSession("Write the docs", in: beta, ago: 120)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(tui.mainText.contains("alpha / Fix the login bug"), "\(tui.mainText)")

            await tui.press(.char("o", .ctrl), .char("/", []))
            await tui.type("docs")

            #expect(tui.sidebarLine(containing: "Current session is outside") != nil, "\(tui.sidebarText)")
            let link = try #require(tui.sidebarLine(containing: "Show alpha in sidebar"), "\(tui.sidebarText)")
            #expect(link.style(of: "Show alpha in sidebar")?.foreground == .basic(36))
            await tui.press(.up([]), .up([]))
            #expect(tui.sidebarLine(containing: "Show alpha in sidebar")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.enter([]))

            #expect(tui.sidebarLine(containing: "Current session is outside") == nil, "\(tui.sidebarText)")
            #expect(tui.sidebarLine(containing: "Fix the login bug")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            #expect(tui.sidebar.last?.text.contains("? keys") == true, "\(tui.sidebarText)")
        }

        @Test func escapeBringsTheWholeTreeBack() async throws {
            let tui = try TUIHarness()
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try tui.addSession("Write the docs", in: alpha)
            try await tui.start()
            await tui.press(.char("/", []))
            await tui.type("login")

            await tui.press(.escape)

            #expect(tui.sidebarLine(containing: "Write the docs") != nil, "\(tui.text)")
            #expect(tui.sidebar.last?.text.contains("? keys") == true)
        }
    }
}
