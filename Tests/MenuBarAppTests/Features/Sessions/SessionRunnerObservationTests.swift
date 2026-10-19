import Foundation
import Observation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// A turn starts and ends tools many times, and the sidebar has a row for every session.
// A tool call has to reach only what shows that session's tools: if it reached everything
// that reads any session's state, the whole sidebar would be rebuilt on every call.
@MainActor
struct SessionRunnerObservationTests {
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    private static let script = """
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"abc"}'
    printf '%s\\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."}]}}'
    wait_for "$folder/start-tool"
    printf '%s\\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}'
    wait_for "$folder/end-tool"
    printf '%s\\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
    wait_for "$folder/end-turn"
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
    cat > /dev/null
    """

    // Raises the flag the first time anything `read` looked at changes.
    private func watch(_ read: @escaping () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking(read) { flag.raised = true }
        return flag
    }

    private func touch(_ name: String, in fixture: RunnerHarness) throws {
        try Data().write(to: fixture.scratch.path(name))
    }

    @Test func aToolCallReachesOnlyWhatShowsThatSessionsTools() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.script)
        defer { fixture.tearDown() }
        let running = fixture.session.id
        let other = try fixture.store.insertSession(
            in: fixture.session.projectID, seed: .init(agent: .claudeCode)).get().id
        fixture.runner.send("go", sessionID: running, store: fixture.store)
        #expect(await waitUntil { fixture.runner.state(running) == .streaming })

        for (marker, toolRunning) in [("start-tool", true), ("end-tool", false)] {
            let states = watch {
                _ = fixture.runner.state(running)
                _ = fixture.runner.question(running)
                _ = fixture.runner.waitIsStale(running)
                _ = fixture.runner.state(other)
                _ = SidebarNotices.all(store: fixture.store, runner: fixture.runner)
            }
            let tools = watch { _ = fixture.runner.runningTool(running) }

            try touch(marker, in: fixture)
            #expect(await waitUntil { (fixture.runner.runningTool(running) != nil) == toolRunning })

            #expect(tools.raised, "\(marker): the session's tools did not report the change")
            #expect(!states.raised, "\(marker): reached readers of session state")
        }

        try touch("end-turn", in: fixture)
        #expect(await waitUntil { fixture.runner.state(running) == .idle })
    }
}
