import Foundation
import Testing
@testable import MenuBarApp

// Which conversation a session is left pointing at after a resumed turn ends. Claude Code
// answers a resume by forking a new conversation and copying the old one into it, and it
// only writes that copy once the turn speaks. A turn that ends before its first word
// therefore leaves a conversation nothing can be resumed from, so the session has to keep
// the one it started from instead.
struct ResumedConversationTests {

    private static let initialized =
        #"printf '%s\n' '{"type":"system","subtype":"init","session_id":"claude-2"}'"#
    private static let speaks =
        #"printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}'"#

    @MainActor private static func harness(_ body: String) throws -> RunnerHarness {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' "$@" > "$folder/arguments.txt"
        \(body)
        """)
        fixture.store.setAgentSessionID("claude-1", agent: .claudeCode, for: fixture.session.id)
        return fixture
    }

    @MainActor @Test func aStoppedTurnKeepsTheConversationItWasResuming() async throws {
        let fixture = try Self.harness("""
        \(Self.initialized)
        wait_for "$folder/never"
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("carry on", sessionID: fixture.session.id, store: fixture.store)

        try #require(await waitUntil {
            fixture.store.session(fixture.session.id)?.claudeSessionID == "claude-2"
        })
        let arguments = try String(contentsOf: fixture.scratch.path("arguments.txt"),
                                   encoding: .utf8)
        #expect(arguments.contains("--resume"))
        #expect(arguments.contains("claude-1"))

        fixture.runner.stop(fixture.session.id)

        #expect(await waitUntil { !fixture.runner.state(fixture.session.id).isBusy })
        #expect(fixture.store.session(fixture.session.id)?.claudeSessionID == "claude-1")
    }

    @MainActor @Test func aStoppedTurnThatSpokeKeepsItsOwnConversation() async throws {
        let fixture = try Self.harness("""
        \(Self.initialized)
        \(Self.speaks)
        wait_for "$folder/never"
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("carry on", sessionID: fixture.session.id, store: fixture.store)

        try #require(await waitUntil {
            fixture.store.transcript(of: fixture.session.id)
                .contains { $0.role == .assistant && $0.text == "Working" }
        })

        fixture.runner.stop(fixture.session.id)

        #expect(await waitUntil { !fixture.runner.state(fixture.session.id).isBusy })
        #expect(fixture.store.session(fixture.session.id)?.claudeSessionID == "claude-2")
    }

    @MainActor @Test func aFailedTurnKeepsTheConversationItWasResuming() async throws {
        let fixture = try Self.harness("""
        \(Self.initialized)
        printf '%s\\n' 'the CLI fell over' >&2
        exit 1
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("carry on", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { !fixture.runner.state(fixture.session.id).isBusy })
        guard case .failed = fixture.runner.state(fixture.session.id) else {
            Issue.record("expected the turn to fail")
            return
        }
        #expect(fixture.store.session(fixture.session.id)?.claudeSessionID == "claude-1")
    }

    @MainActor @Test func aResumedTurnThatFinishesKeepsItsOwnConversation() async throws {
        let fixture = try Self.harness("""
        \(Self.initialized)
        \(Self.speaks)
        printf '%s\\n' '{"type":"result","is_error":false,"result":"Working"}'
        """)
        defer { fixture.tearDown() }

        fixture.runner.send("carry on", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle })
        #expect(fixture.store.session(fixture.session.id)?.claudeSessionID == "claude-2")
    }
}
