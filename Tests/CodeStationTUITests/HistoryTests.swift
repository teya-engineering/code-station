import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Back and forward walk the places the main pane has shown, as ⌘[ and ⌘] do in the
    // GUI: Home and each session opened, in the order they were visited.
    @MainActor
    @Suite
    struct HistoryTests {

        @Test func backAndForwardWalkThePlacesVisited() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("First", in: alpha, ago: 60)
            try tui.addSession("Second", in: alpha, ago: 3_600)
            try await tui.start()

            await tui.press(.enter([]))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / First") == true, "\(tui.mainText)")
            await tui.press(.char("o", .ctrl), .char("j", []), .enter([]))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Second") == true, "\(tui.mainText)")

            // From the open session, where letters are keys.
            await tui.press(.char("[", []))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / First") == true, "\(tui.mainText)")
            #expect(tui.sidebarLine(containing: "First")?.text.hasPrefix("▸") == true, "\(tui.sidebarText)")
            await tui.press(.left(.alt))
            #expect(tui.mainPane.first?.text == " Home", "\(tui.mainText)")
            // Nothing before Home: the key leaves it there.
            await tui.press(.char("[", []))
            #expect(tui.mainPane.first?.text == " Home", "\(tui.mainText)")

            await tui.press(.char("]", []))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / First") == true, "\(tui.mainText)")
            await tui.press(.right(.alt))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Second") == true, "\(tui.mainText)")
        }

        // Going somewhere new from the middle of the trail drops what was ahead of it.
        @Test func aNewPlaceFromTheMiddleDropsThePlacesAhead() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("First", in: alpha, ago: 60)
            try tui.addSession("Second", in: alpha, ago: 3_600)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("[", []))
            #expect(tui.mainPane.first?.text == " Home", "\(tui.mainText)")

            await tui.press(.char("o", .ctrl), .char("j", []), .enter([]))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Second") == true, "\(tui.mainText)")
            await tui.press(.char("]", []))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Second") == true, "\(tui.mainText)")
            await tui.press(.char("[", []))
            #expect(tui.mainPane.first?.text == " Home", "\(tui.mainText)")
        }

        // A session deleted since it was visited is stepped over.
        @Test func backStepsOverASessionThatHasGone() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let first = try tui.addSession("First", in: alpha, ago: 60)
            try tui.addSession("Second", in: alpha, ago: 3_600)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("o", .ctrl), .char("j", []), .enter([]))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / Second") == true, "\(tui.mainText)")

            _ = tui.store.removeSession(first.id)
            #expect(await waitUntil { tui.sidebarLine(containing: "First") == nil }, "\(tui.sidebarText)")

            await tui.press(.char("[", []))
            #expect(tui.mainPane.first?.text == " Home", "\(tui.mainText)")
        }

        // Home is a place too, reached from the palette, and back returns from it.
        @Test func thePalettesHomeActionIsAPlaceOnTheTrail() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("First", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("k", .ctrl))
            await tui.type("home")
            await tui.press(.enter([]))
            #expect(tui.mainPane.first?.text == " Home", "\(tui.mainText)")

            await tui.press(.char("[", []))
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / First") == true, "\(tui.mainText)")
        }

        // While a prompt is written the brackets are text, not steps.
        @Test func bracketsTypeInThePrompt() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 100, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("First", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            await tui.press(.char("i", []))

            await tui.type("a[0]")

            #expect(tui.mainLine(containing: "a[0]") != nil, "\(tui.mainText)")
            #expect(tui.topBar.first?.text.hasPrefix(" ■ alpha / First") == true, "\(tui.mainText)")
        }
    }
}
