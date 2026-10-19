import Foundation
import Testing
@testable import CodeStationCore

// The runner reaches the OS only through the host it is handed at startup. A recording
// host shows when it is told that a turn ended or that a session needs input, driven by
// the fake agent CLIs, so a host without AppKit hears about the same moments the GUI does.
@MainActor
struct HostServicesTests {

    @Test func aFinishedTurnPlaysTheSoundAndIsReportedAgainstItsSession() async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
        """, host: host)
        defer { fixture.tearDown() }

        fixture.runner.send("hello", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { fixture.runner.state(fixture.session.id) == .idle
            && !host.events.isEmpty })
        #expect(host.events == [.sound, .turnEnded(fixture.session.id, failure: nil)])
    }

    @Test func aFailedTurnCarriesItsReason() async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        echo "the model is unavailable" >&2
        exit 3
        """, host: host)
        defer { fixture.tearDown() }

        fixture.runner.send("hello", sessionID: fixture.session.id, store: fixture.store)

        #expect(await waitUntil { host.endings.count == 1 })
        #expect(host.endings.first?.sessionID == fixture.session.id)
        #expect(host.endings.first?.failure?.contains("the model is unavailable") == true)
        #expect(host.events.first == .sound)
    }

    // A permission request is said the moment it arrives, while the turn is parked on it.
    // Answering takes the notice back, and only the turn's end is heard.
    @Test func aPermissionRequestNeedsInputUntilItIsAnswered() async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/p/hello.txt","content":"hi"},"tool_use_id":"toolu_1"}}'
        IFS= read -r answer
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
        """, host: host)
        defer { fixture.tearDown() }
        let id = fixture.session.id

        fixture.runner.send("hello", sessionID: id, store: fixture.store)

        #expect(await waitUntil { fixture.runner.question(id) != nil })
        #expect(host.events == [.needsInput(id, requestID: "r1")])

        let request = try #require(fixture.runner.question(id))
        fixture.runner.answer(request, with: .allowOnce, sessionID: id, store: fixture.store)

        #expect(await waitUntil { !host.endings.isEmpty })
        #expect(host.events == [.needsInput(id, requestID: "r1"), .clear(id),
                                .sound, .turnEnded(id, failure: nil)])
    }

    // Stopping a turn is the person's own doing, so it is neither heard nor reported.
    @Test func aStoppedTurnIsNotReported() async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        touch started
        while :; do sleep 0.1; done
        """, host: host)
        defer { fixture.tearDown() }
        let id = fixture.session.id

        fixture.runner.send("hello", sessionID: id, store: fixture.store)
        #expect(await waitUntil {
            FileManager.default.fileExists(atPath: fixture.projectURL.appendingPathComponent("started").path)
        })
        fixture.runner.stop(id)

        #expect(await waitUntil { !fixture.runner.state(id).isBusy })
        #expect(host.events.isEmpty)
    }
}

// Every call the core makes on its host, in order. Calls the runner never makes (copying,
// opening, choosing) are recorded too, so a test can show they stay out of a turn.
@MainActor
final class RecordingHost: HostServices {
    enum Event: Equatable {
        case turnEnded(UUID, failure: String?)
        case needsInput(UUID, requestID: String)
        case waitWentStale(UUID)
        case clear(UUID)
        case sound
        case copy(ClipboardContent)
        case open(URL, bundleID: String)
        case openLink(URL)
        case chooseDirectory
    }

    var events: [Event] = []
    var directory: URL?

    var endings: [(sessionID: UUID, failure: String?)] {
        events.compactMap {
            if case .turnEnded(let id, let failure) = $0 { (id, failure) } else { nil }
        }
    }

    func turnEnded(sessionID: UUID, sessionTitle: String, failure: String?) {
        events.append(.turnEnded(sessionID, failure: failure))
    }
    func needsInput(sessionID: UUID, sessionTitle: String, request: PermissionRequest) {
        events.append(.needsInput(sessionID, requestID: request.id))
    }
    func waitWentStale(sessionID: UUID, sessionTitle: String, tasks: [AgentBackgroundTask]) {
        events.append(.waitWentStale(sessionID))
    }
    func clear(sessionID: UUID) { events.append(.clear(sessionID)) }
    func playSessionSound() { events.append(.sound) }
    func copy(_ content: ClipboardContent) { events.append(.copy(content)) }
    func openInApps() -> [OpenInApp] { [] }
    func open(_ path: URL, in app: OpenInApp) {
        events.append(.open(path, bundleID: app.bundleID))
    }
    func openLink(_ url: URL) { events.append(.openLink(url)) }
    func chooseDirectory(prompt: String, message: String,
                         startingAt directory: URL?) async throws -> URL? {
        events.append(.chooseDirectory)
        return self.directory
    }
}
