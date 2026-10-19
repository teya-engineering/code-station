import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Home: what the main pane shows with no session open, as a list of what needs the
    // person, what is running and the sessions most recently at work.
    @MainActor
    @Suite
    struct HomeTests {

        @Test func homeListsWhatNeedsYouWhatIsRunningAndRecentSessions() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24), agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            wait_for "$folder/release"
            exit 0
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let beta = try tui.addProject("beta")
            try tui.addSession("Write the docs", in: alpha, ago: 3 * 3_600)
            let done = try tui.addSession("Fix the login bug", in: alpha, ago: 120)
            tui.store.setMarkedUnread(true, for: done.id)
            let busy = try tui.addSession("Refactor the parser", in: beta, ago: 60)
            try await tui.start()

            tui.runner.send("hello", sessionID: busy.id, store: tui.store)

            #expect(await waitUntil { tui.mainText.contains("· RUNNING") }, "\(tui.mainText)")
            let rows = tui.mainPane.map(\.text)
            func row(_ fragment: String) -> Int? { rows.firstIndex { $0.contains(fragment) } }
            let order = [row(" Home"), row("NEEDS YOU"), row("Fix the login bug"), row(" RUNNING"),
                         row("Refactor the parser"), row("RECENT"), row("Write the docs")]
            #expect(order.allSatisfy { $0 != nil }, "\(tui.mainText)")
            let found = order.compactMap { $0 }
            #expect(found == found.sorted(), "\(tui.mainText)")
            #expect(tui.mainLine(containing: "1 needs you · 1 running") != nil, "\(tui.mainText)")
            // Each entry says where it is, why it is listed and how long ago.
            let needs = try #require(tui.mainLine(containing: "Fix the login bug"))
            #expect(needs.text.contains("alpha · finished · 2m"), "\(needs.text)")
            #expect(tui.mainLine(containing: "NEEDS YOU")?.style(of: "NEEDS YOU")?.bold == true)
            let running = try #require(tui.mainLine(containing: "Refactor the parser"))
            #expect(running.text.contains("beta · RUNNING"), "\(running.text)")
            #expect(running.style(of: "RUNNING")?.foreground == .basic(32))
            // A session is listed once: the running one is not also under Recent.
            #expect(rows.filter { $0.contains("Refactor the parser") }.count == 1, "\(tui.mainText)")
            try Data().write(to: tui.scratch.path("release"))
        }

        // The focus key gives Home the keys; its list moves like the sidebar's and Enter
        // opens the session, with the sidebar pointing at it.
        @Test func theFocusKeyGivesHomeTheKeysAndEnterOpensTheSession() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Newest", in: alpha, ago: 60)
            try tui.addSession("Older", in: alpha, ago: 3_600)
            try await tui.start()
            // Home shows no selection while the sidebar has the keys.
            #expect(tui.mainLine(containing: "Newest")?.text.contains("▸") == false, "\(tui.mainText)")

            await tui.press(.char("o", .ctrl))
            let first = try #require(tui.mainLine(containing: "Newest"), "\(tui.mainText)")
            #expect(first.text.hasPrefix("▸"), "\(tui.mainText)")
            #expect(first.style(of: "Newest")?.inverse == true)

            await tui.press(.char("j", []))
            #expect(tui.mainLine(containing: "Older")?.text.hasPrefix("▸") == true, "\(tui.mainText)")

            await tui.press(.enter([]))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Older") == true, "\(tui.mainText)")
            #expect(tui.sidebarLine(containing: "Older")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
        }

        @Test func anEmptyStationSaysHowToStart() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            try await tui.start()

            #expect(tui.mainLine(containing: "No sessions yet.") != nil, "\(tui.mainText)")
            #expect(tui.mainLine(containing: "0 need you · 0 running · 0 sessions") != nil, "\(tui.mainText)")
        }
    }
}
