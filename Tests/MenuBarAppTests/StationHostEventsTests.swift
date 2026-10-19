import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): what the host would tell the
// person (a turn that ended, a question waiting, a wait gone stale, the session sound)
// reaches every client that listens, so a terminal rings or posts OSC 9 whichever host
// runs the session. The host keeps telling its own person as before.
@MainActor
struct StationHostEventsTests {

    // A turn ends on the host: a listening client hears the session sound and then the
    // turn ending, named after the session, and the host's own services still hear it.
    @Test(arguments: StationImplementation.allCases)
    func aClientHearsATurnEndOnTheHost(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"Done"}'
        """, host: host)
        defer { fixture.tearDown() }
        fixture.store.renameSession(fixture.session.id, to: "Fix login")
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let client = kind.connect(to: station)
        let heard = HostEventLog()
        let listener = Task { @MainActor in
            for await event in client.hostEvents() { heard.events.append(event) }
        }
        defer { listener.cancel() }
        #expect(await waitUntil { station.hostEventListeners == 1 })

        try await client.sendPrompt(fixture.session.id.uuidString, prompt: "hello")

        let id = fixture.session.id.uuidString
        #expect(await waitUntil { heard.events.count == 2 }, "\(heard.events)")
        #expect(heard.events == [.sessionSound,
                                 .turnEnded(sessionID: id, sessionTitle: "Fix login", failure: nil)])
        #expect(host.endings.map(\.sessionID) == [fixture.session.id])
    }

    // A tool waiting for permission is pushed with what a notification needs to say
    // about it: the request's id, the tool and the call it is about.
    @Test(arguments: StationImplementation.allCases)
    func aClientHearsAQuestionWaitingOnTheHost(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '\(Self.bashRequest)'
        IFS= read -r answer
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let client = kind.connect(to: station)
        let heard = HostEventLog()
        let listener = Task { @MainActor in
            for await event in client.hostEvents() { heard.events.append(event) }
        }
        defer { listener.cancel() }
        #expect(await waitUntil { station.hostEventListeners == 1 })

        try await client.sendPrompt(fixture.session.id.uuidString, prompt: "clean up")

        #expect(await waitUntil { heard.waiting != nil }, "\(heard.events)")
        let waiting = try #require(heard.waiting)
        #expect(waiting.sessionID == fixture.session.id.uuidString)
        #expect(waiting.request.id == "req-1")
        #expect(waiting.request.toolName == "Bash")
        #expect(waiting.request.subject == "rm -rf build")
    }

    // What a client hears is handed to its own services, as the host's runner would have
    // called them: a terminal answers with the bell and OSC 9.
    @Test func aHostEventIsDeliveredToTheClientsOwnServices() throws {
        let id = UUID()
        let host = RecordingHost()
        let events: [StationHostEvent] = [
            .sessionSound,
            .turnEnded(sessionID: id.uuidString, sessionTitle: "Fix login", failure: "Rate limited"),
            .waitWentStale(sessionID: id.uuidString, sessionTitle: "Fix login", tasks: []),
            .cleared(sessionID: id.uuidString),
        ]
        for event in events {
            let travelled = try JSONDecoder().decode(StationHostEvent.self,
                                                     from: JSONEncoder().encode(event))
            travelled.deliver(to: host)
        }
        #expect(host.events == [.sound, .turnEnded(id, failure: "Rate limited"), .waitWentStale(id), .clear(id)])
    }

    static let bashRequest = #"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"}}}"#
}

@MainActor
final class HostEventLog {
    var events: [StationHostEvent] = []

    var waiting: (sessionID: String, request: RemotePermission)? {
        for event in events {
            if case .needsInput(let sessionID, _, let request) = event { return (sessionID, request) }
        }
        return nil
    }
}
