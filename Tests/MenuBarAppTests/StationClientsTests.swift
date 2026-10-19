import Foundation
import Testing
@testable import CodeStationCore

// More than one front end on one station: two terminals, or a terminal beside the GUI.
// Each client follows sessions of its own and says what it shows, and nothing one client
// does takes a session away from another.
@MainActor
struct StationClientsTests {

    // Two clients follow the same session. When one closes it, the other keeps receiving
    // what moves in it, and the transcript stays in memory for it.
    @Test(arguments: StationImplementation.allCases)
    func closingASessionInOneClientLeavesItOpenInAnother(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.append(ChatMessage(role: .assistant, text: "Hello"), to: fixture.session.id)
        let host = StationCommands(store: fixture.store, runner: fixture.runner,
                                   refreshInterval: .milliseconds(50))
        let first = kind.connect(to: host)
        let second = kind.connect(to: host)
        let id = fixture.session.id.uuidString

        let staying = try #require(try await first.openSession(id))
        let leaving = try #require(try await second.openSession(id))
        let log = EventLog()
        log.mirror = RemoteTranscript(staying.snapshot)
        let reader = Task { @MainActor in
            for await event in staying.events { log.mirror?.apply(event) }
            log.ended = true
        }
        defer { reader.cancel() }
        let closed = EventLog()
        let other = Task { @MainActor in
            for await _ in leaving.events {}
            closed.ended = true
        }
        defer { other.cancel() }

        await second.closeSession(id)

        #expect(await waitUntil { closed.ended })
        #expect(fixture.store.isTranscriptLoaded(fixture.session.id))
        fixture.store.append(ChatMessage(role: .assistant, text: "Still here"), to: fixture.session.id)
        #expect(await waitUntil { log.mirror?.messages.map(\.text) == ["Hello", "Still here"] })
        #expect(log.ended == false)
    }

    // A client that goes away lets go of what it had open and can open nothing more;
    // the others carry on.
    @Test(arguments: StationImplementation.allCases)
    func aClientThatDisconnectsLetsGoOfItsSessions(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let host = StationCommands(store: fixture.store, runner: fixture.runner,
                                   refreshInterval: .milliseconds(50))
        let staying = kind.connect(to: host)
        let leaving = kind.connect(to: host)
        let id = fixture.session.id.uuidString
        let opened = try #require(try await leaving.openSession(id))
        let log = EventLog()
        let reader = Task { @MainActor in
            for await _ in opened.events {}
            log.ended = true
        }
        defer { reader.cancel() }

        await leaving.disconnect()

        #expect(await waitUntil { log.ended })
        #expect(try await leaving.openSession(id) == nil)
        #expect(try await staying.openSession(id) != nil)
    }

    // A finished turn counts as read while any front end shows the session. Following a
    // session without showing it is not reading it.
    @Test(arguments: StationImplementation.allCases)
    func aTurnEndingIsReadWhileAnyClientShowsTheSession(_ kind: StationImplementation) async throws {
        let recorder = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.answer, host: recorder)
        defer { fixture.tearDown() }
        let host = StationCommands(store: fixture.store, runner: fixture.runner,
                                   refreshInterval: .milliseconds(50))
        let showing = kind.connect(to: host)
        let following = kind.connect(to: host)
        let id = fixture.session.id.uuidString
        _ = try #require(try await showing.openSession(id))
        _ = try #require(try await following.openSession(id))
        await showing.show(id)

        try await following.sendPrompt(id, prompt: "hello")

        #expect(await waitUntil { recorder.endings.count == 1 })
        #expect(try await Self.row(of: following)?.state == "IDLE")
    }

    // With no front end showing the session, a finished turn stays unread, and so does
    // one that ends after the only client showing it moved away or went.
    @Test(arguments: StationImplementation.allCases)
    func aTurnEndingIsUnreadWhenNoClientShowsTheSession(_ kind: StationImplementation) async throws {
        let recorder = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.answer, host: recorder)
        defer { fixture.tearDown() }
        let host = StationCommands(store: fixture.store, runner: fixture.runner,
                                   refreshInterval: .milliseconds(50))
        let first = kind.connect(to: host)
        let second = kind.connect(to: host)
        let id = fixture.session.id.uuidString
        _ = try #require(try await first.openSession(id))
        await first.show(id)
        await first.show(nil)
        await second.show(id)
        await second.disconnect()

        try await first.sendPrompt(id, prompt: "hello")

        #expect(await waitUntil { recorder.endings.count == 1 })
        #expect(try await Self.row(of: first)?.state == "NEEDS YOU")
        // Showing it now is what reads it.
        await first.show(id)
        #expect(try await Self.row(of: first)?.state == "IDLE")
    }

    private static let answer = """
    IFS= read -r input
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
    """

    private static func row(of station: any StationInterface) async throws -> RemoteSessionRow? {
        try await station.listDirectory().projects.first?.sessions.first
    }
}
