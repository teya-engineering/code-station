import CodeStationCore
import Foundation
import Testing

extension TUITests {
    // What the station host tells the person reaches the terminal, whichever process runs
    // the session: the TUI hears it from the host and answers with OSC 9 and the bell.
    @MainActor
    @Suite
    struct HostEventTests {

        // A turn started elsewhere (the GUI, another terminal) ends while the TUI shows
        // its list: the terminal gets one notification naming the session.
        @Test func aTurnThatEndsOnTheHostPostsANotification() async throws {
            let tui = try TUIHarness(agentScript: """
            IFS= read -r input
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done"}'
            """)
            defer { tui.tearDown() }
            let alpha = try tui.addProject("alpha")
            let session = try tui.addSession("Greetings", in: alpha)
            try await tui.start()
            #expect(await waitUntil { tui.commands.hostEventListeners == 1 })

            tui.runner.send("Say hello", sessionID: session.id, store: tui.store)

            let notification = "\u{1B}]9;Greetings: Finished and waiting for you.\u{07}"
            #expect(await waitUntil { tui.terminal.output.contains(notification) })
            #expect(tui.terminal.output.components(separatedBy: notification).count == 2)
        }
    }
}
