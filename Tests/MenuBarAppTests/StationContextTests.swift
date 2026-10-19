import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): Compact and Clear, as the
// GUI's context actions offer them. The header says which of the two the session can do
// now, compacting hands Claude Code its own `/compact` as a turn, and clearing drops the
// conversation so the next turn starts a fresh one. Either is refused when there is
// nothing to act on.
@MainActor
struct StationContextTests {

    private static let script = """
    IFS= read -r input
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
    case "$input" in
    *'/compact'*) printf '%s\\n' '{"type":"system","subtype":"compact_boundary","compact_metadata":{"pre_tokens":90000,"post_tokens":12000}}' ;;
    *) printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello."}]}}' ;;
    esac
    """

    // Before the first turn there is no conversation, so neither action is offered and
    // both are refused.
    @Test(arguments: StationImplementation.allCases)
    func aSessionWithNoConversationHasNothingToCompactOrClear(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.script, host: RecordingHost())
        defer { fixture.tearDown() }
        let session = try await Followed(fixture, kind)

        #expect(session.log.mirror?.header.canCompact == false)
        #expect(session.log.mirror?.header.canClear == false)
        await #expect(throws: StationRefusal.self) { try await session.commands.compactContext(session.id) }
        await #expect(throws: StationRefusal.self) { try await session.commands.clearContext(session.id) }
    }

    // After a turn both are offered. Compacting runs Claude Code's own command as a turn
    // and says how far the conversation shrank.
    @Test(arguments: StationImplementation.allCases)
    func compactingRunsTheAgentsCompactCommand(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.script, host: RecordingHost())
        defer { fixture.tearDown() }
        let session = try await Followed(fixture, kind)
        try await session.commands.sendPrompt(session.id, prompt: "Hi")
        #expect(await waitUntil { session.log.mirror?.header.canCompact == true })
        #expect(session.log.mirror?.header.canClear == true)

        try await session.commands.compactContext(session.id)

        #expect(await waitUntil {
            session.log.mirror?.messages.contains { $0.text.hasPrefix("Context compacted, from") } == true
                && session.log.mirror?.header.isBusy == false
        }, "\(session.log.mirror?.messages.map(\.text) ?? [])")
        // The conversation carries on from the summary, so it can be compacted again.
        #expect(await waitUntil { session.log.mirror?.header.canCompact == true })
    }

    // Clearing drops the conversation and says so in the transcript; there is then
    // nothing left to clear or compact.
    @Test(arguments: StationImplementation.allCases)
    func clearingStartsTheNextTurnOnAFreshConversation(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.script, host: RecordingHost())
        defer { fixture.tearDown() }
        let session = try await Followed(fixture, kind)
        try await session.commands.sendPrompt(session.id, prompt: "Hi")
        #expect(await waitUntil { session.log.mirror?.header.canClear == true })

        try await session.commands.clearContext(session.id)

        #expect(await waitUntil {
            session.log.mirror?.messages.last?.text == "Context cleared. The next turn starts a fresh conversation."
        })
        #expect(await waitUntil { session.log.mirror?.header.canClear == false })
        #expect(session.log.mirror?.header.canCompact == false)
        #expect(fixture.store.session(fixture.session.id)?.hasAgentConversation == false)
        await #expect(throws: StationRefusal.self) { try await session.commands.clearContext(session.id) }
    }

    // Compacting is Claude Code's alone: Codex has no manual command for it. Clearing is
    // offered to either.
    @Test(arguments: StationImplementation.allCases)
    func onlyClaudeCodeCompacts(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .codex, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.setAgentSessionID("codex-1", agent: .codex, for: fixture.session.id)
        let session = try await Followed(fixture, kind)

        #expect(session.log.mirror?.header.canCompact == false)
        #expect(session.log.mirror?.header.canClear == true)
        await #expect(throws: StationRefusal.self) { try await session.commands.compactContext(session.id) }
    }
}

// A session opened through a client of a station on the fixture's store and runner, with
// a reader's copy kept up to date from its events.
@MainActor
final class Followed {
    let commands: any StationInterface
    let id: String
    let log = EventLog()
    private var reader: Task<Void, Never>?

    // `station` is a host the scenario set up itself, in place of a plain one.
    init(_ fixture: RunnerHarness, _ kind: StationImplementation, sessionID: UUID? = nil,
         station: StationCommands? = nil) async throws {
        commands = kind.connect(to: station ?? StationCommands(store: fixture.store, runner: fixture.runner,
                                                               refreshInterval: .milliseconds(50)))
        id = (sessionID ?? fixture.session.id).uuidString
        let opened = try #require(try await commands.openSession(id))
        log.mirror = RemoteTranscript(opened.snapshot)
        let log = log
        reader = Task { @MainActor in
            for await event in opened.events { log.mirror?.apply(event) }
        }
    }

    deinit { reader?.cancel() }
}
