import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The station contract: every scenario in the station suites drives the station interface
// and runs once for each implementation listed here, so a new one (the socket client)
// joins by adding a case and is held to exactly the same behaviour.
//
// A scenario builds the host the way it needs it (a store seeded on disk, a runner on a
// fixture CLI) and asks the implementation under test for a client of that host.
enum StationImplementation: String, CaseIterable, Sendable, CustomTestStringConvertible {
    // The front end reaches the host's engine in its own process.
    case inProcess
    // The front end talks to the host's socket server, started for the test in a
    // temporary folder, as a terminal talks to a daemon or the GUI.
    case socket
    // The front end talks to the socket the GUI serves while it holds the station: the
    // same server, set up as the GUI sets it up.
    case guiHost

    var testDescription: String { rawValue }

    // A new client of the host, as a front end that has just connected sees it.
    @MainActor
    func connect(to host: StationCommands) -> any StationInterface {
        switch self {
        case .inProcess: host.connect()
        case .socket: SocketHosts.client(of: host)
        case .guiHost: SocketHosts.client(of: host, servedByTheGUI: true)
        }
    }
}

// One socket server per host under test, so two clients of one host meet on one server
// as two terminals do. The servers live as long as the test process: a scenario ends
// with its clients still attached, and the scratch store goes with the test.
@MainActor
enum SocketHosts {
    private static var servers: [ObjectIdentifier: (host: StationCommands, server: StationSocketServer)] = [:]
    private static var guiHosts: [ObjectIdentifier: GUIStationHost] = [:]

    static func client(of host: StationCommands, servedByTheGUI: Bool = false) -> StationSocketClient {
        let server = servedByTheGUI ? guiServer(for: host) : server(for: host)
        return StationSocketClient(path: server.endpoint ?? "")
    }

    static func server(for host: StationCommands) -> StationSocketServer {
        if let running = servers[ObjectIdentifier(host)] { return running.server }
        let server = StationSocketServer(station: host)
        do {
            _ = try server.start(at: scratchSocket())
        } catch {
            Issue.record("the socket server did not start: \(error)")
        }
        servers[ObjectIdentifier(host)] = (host, server)
        return server
    }

    // The GUI's host on the scenario's engine. A scenario builds its engine as a host
    // with no window, which reads as the GUI in the background: what a scenario reads is
    // then down to its clients, as with every other implementation. (What the GUI's own
    // selection reads while it is active is in GUIStationHostTests.)
    static func guiServer(for host: StationCommands) -> StationSocketServer {
        if let running = guiHosts[ObjectIdentifier(host)] { return running.server }
        let gui = GUIStationHost(station: host)
        do {
            try gui.serve(at: scratchSocket(), advertisingIn: nil)
        } catch {
            Issue.record("the GUI's socket server did not start: \(error)")
        }
        guiHosts[ObjectIdentifier(host)] = gui
        return gui.server
    }

    private static func scratchSocket() -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("station-socket-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("station.sock").path
    }
}

// What a reader of an open session has been sent, and its copy of the session built from
// those events.
@MainActor
final class EventLog {
    var events: [StationSessionEvent] = []
    var mirror: RemoteTranscript?
    var ended = false

    var changes: [RemoteChange] {
        events.flatMap { event -> [RemoteChange] in
            if case .update(let update) = event { return update.changed ?? [] }
            return []
        }
    }
}

// `waitUntil` for a condition that asks the station, which a client does with `await`.
func eventually(timeout: Duration = .seconds(30),
                isolation: isolated (any Actor)? = #isolation,
                _ condition: () async throws -> Bool) async -> Bool {
    let deadline = SuspendingClock.now + timeout
    while SuspendingClock.now < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return (try? await condition()) == true
}
