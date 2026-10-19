import CodeStationCore
import Foundation
import TerminalKit
import Testing

extension TUITests {
    // Compact and Clear from the top bar, as the GUI offers them under CONTEXT: the tab
    // row says which are on offer, C asks before compacting (it costs a turn), and X
    // clears at once.
    @MainActor
    @Suite
    struct ContextActionsTests {

        private static let script = """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        case "$input" in
        *'/compact'*) printf '%s\\n' '{"type":"system","subtype":"compact_boundary","compact_metadata":{"pre_tokens":90000,"post_tokens":12000}}' ;;
        *) printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello there."}]}}' ;;
        esac
        """

        private func sessionWithATurn() async throws -> TUIHarness {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24), agentScript: Self.script)
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))
            #expect(!tui.topBar[2].text.contains("compact"), "\(tui.topBarText)")
            await tui.press(.char("i", []))
            await tui.type("Hi")
            await tui.press(.enter([]))
            #expect(await tui.waitFor("Hello there."), "\(tui.text)")
            await tui.press(.tab([]))
            #expect(await waitUntil { tui.topBar[2].text.hasSuffix("C compact · X clear") }, "\(tui.topBarText)")
            return tui
        }

        @Test func compactingAsksFirstThenRunsTheTurn() async throws {
            let tui = try await sessionWithATurn()
            defer { tui.tearDown() }

            await tui.press(.char("C", []))

            #expect(tui.contains("Compact this session's context?"), "\(tui.text)")
            #expect(tui.contains("enter compact · esc cancel"), "\(tui.text)")

            await tui.press(.escape)

            #expect(!tui.contains("Compact this session's context?"), "\(tui.text)")
            #expect(!tui.contains("Compacting the context"), "\(tui.text)")

            await tui.press(.char("C", []))
            await tui.press(.enter([]))

            #expect(await tui.waitFor("Context compacted, from"), "\(tui.text)")
        }

        @Test func clearingDropsTheConversationAtOnce() async throws {
            let tui = try await sessionWithATurn()
            defer { tui.tearDown() }

            await tui.press(.char("X", []))

            #expect(await tui.waitFor("Context cleared. The next turn starts a fresh conversation."), "\(tui.text)")
            #expect(await waitUntil { !tui.topBar[2].text.contains("clear") }, "\(tui.topBarText)")
        }

        // The actions reach the session from any tab, and a refusal says why.
        @Test func aRefusedActionSaysWhy() async throws {
            let tui = try TUIHarness(size: TerminalSize(cols: 140, rows: 24))
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            try tui.addSession("Fix the login bug", in: alpha)
            try await tui.start()
            await tui.press(.enter([]))

            await tui.press(.char("X", []))

            #expect(tui.contains("There is no conversation to act on yet."), "\(tui.text)")
        }
    }
}
