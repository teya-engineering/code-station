import Foundation
import Testing
@testable import MenuBarApp

// A prompt typed while a turn runs reaches the agent inside that turn when the agent can
// take it, and waits in the queue when asked to or when it cannot.
@MainActor
struct SteerTests {
    // A Claude Code that answers at once, then keeps its input open and copies every line
    // it is given to a file, until the test lets it finish. The copy runs in the
    // background, which the shell would otherwise start on an empty input, so it is
    // handed the real one through a spare descriptor.
    private static let claude = """
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"steer-1"}'
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it"}]}}'
    exec 3<&0
    cat <&3 > "$folder/stdin.txt" &
    wait_for "$folder/finish"
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done","num_turns":1}'
    wait
    """

    @Test func aPromptSentDuringATurnGoesStraightToClaudeCode() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.claude)
        defer { harness.tearDown() }
        let id = harness.session.id
        let runner = harness.runner
        let store = harness.store

        runner.send("Start the work", sessionID: id, store: store)
        #expect(await waitUntil {
            store.transcript(of: id).contains { $0.role == .assistant && $0.text.contains("Working") }
        })
        #expect(runner.canSteer(id))

        runner.send("Also check the tests", sessionID: id, store: store)

        #expect(runner.queued(id).isEmpty)
        let stdin = harness.scratch.path("stdin.txt")
        #expect(await waitUntil {
            (try? String(contentsOf: stdin, encoding: .utf8))?.contains("Also check the tests") == true
        })
        // The transcript keeps the order things happened in: the reply so far, the new
        // prompt under it, and a fresh bubble for what the agent says next.
        let transcript = store.transcript(of: id)
        #expect(transcript.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(transcript[2].text == "Also check the tests")
        #expect(transcript[3].isEmpty)
        #expect(runner.state(id).isBusy)

        // Asked to wait, a prompt still queues behind the turn.
        runner.send("And then stop", delivery: .afterTurn, sessionID: id, store: store)
        #expect(runner.queued(id).map(\.text) == ["And then stop"])
        #expect(store.transcript(of: id).count == 4)

        runner.stop(id)
        #expect(await waitUntil { !runner.state(id).isBusy })
    }

    @Test func choosingTheQueueInSettingsMakesAPlainSendWait() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.claude)
        defer { harness.tearDown() }
        let id = harness.session.id
        let runner = harness.runner
        let store = harness.store
        Preferences.setMidTurnPromptDelivery(.afterTurn, in: harness.scratch.preferences.store)

        runner.send("Start the work", sessionID: id, store: store)
        #expect(await waitUntil {
            store.transcript(of: id).contains { $0.role == .assistant && $0.text.contains("Working") }
        })
        #expect(runner.canSteer(id))

        runner.send("Also check the tests", sessionID: id, store: store)
        #expect(runner.queued(id).map(\.text) == ["Also check the tests"])
        #expect(store.transcript(of: id).count == 2)

        // Asking for it now still steers, whatever the setting says.
        runner.send("And the docs", delivery: .now, sessionID: id, store: store)
        let stdin = harness.scratch.path("stdin.txt")
        #expect(await waitUntil {
            (try? String(contentsOf: stdin, encoding: .utf8))?.contains("And the docs") == true
        })
        #expect(runner.queued(id).map(\.text) == ["Also check the tests"])

        runner.stop(id)
        #expect(await waitUntil { !runner.state(id).isBusy })
    }

    @Test func steeringAQueuedPromptTakesItOutOfTheQueueAndIntoTheTurn() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.claude)
        defer { harness.tearDown() }
        let id = harness.session.id
        let runner = harness.runner
        let store = harness.store

        runner.send("Start the work", sessionID: id, store: store)
        #expect(await waitUntil {
            store.transcript(of: id).contains { $0.role == .assistant && $0.text.contains("Working") }
        })
        runner.send("First", delivery: .afterTurn, sessionID: id, store: store)
        runner.send("Second", delivery: .afterTurn, sessionID: id, store: store)
        let second = try #require(runner.queued(id).last)

        #expect(runner.steer(second.id, sessionID: id, store: store))

        #expect(runner.queued(id).map(\.text) == ["First"])
        let stdin = harness.scratch.path("stdin.txt")
        #expect(await waitUntil {
            (try? String(contentsOf: stdin, encoding: .utf8))?.contains("Second") == true
        })
        let steered = try #require(store.transcript(of: id).last { $0.role == .user })
        #expect(steered.text == "Second")
        #expect(steered.steered == true)
        // A prompt that starts a turn is not marked.
        #expect(store.transcript(of: id).first?.steered == nil)

        runner.stop(id)
        #expect(await waitUntil { !runner.state(id).isBusy })
    }

    @Test func aQueuedPromptStaysWhenTheTurnCannotTakeIt() async throws {
        let harness = try RunnerHarness(agent: .claudeCode, script: Self.claude)
        defer { harness.tearDown() }
        let id = harness.session.id
        let runner = harness.runner
        let store = harness.store

        runner.send("Start the work", sessionID: id, store: store)
        #expect(await waitUntil {
            store.transcript(of: id).contains { $0.role == .assistant && $0.text.contains("Working") }
        })
        runner.send("Later", delivery: .afterTurn, sessionID: id, store: store)
        let item = try #require(runner.queued(id).first)
        runner.stop(id)

        #expect(!runner.steer(item.id, sessionID: id, store: store))
        #expect(runner.queued(id).map(\.text) == ["Later"])
        #expect(await waitUntil { !runner.state(id).isBusy })
    }

    @Test func copilotKeepsTheQueue() throws {
        #expect(AgentKind.copilot.canSteer == false)
        #expect(AgentKind.claudeCode.canSteer)
        #expect(AgentKind.codex.canSteer)
    }
}
