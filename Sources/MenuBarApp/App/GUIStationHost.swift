import CodeStationCore
import Foundation

// The GUI as a station host (ADR-0003). While it holds the station it serves the same
// socket the daemon does, from the store and runner its own windows use, so a terminal
// started beside it attaches as a client and the two see one station live. The GUI
// itself keeps using the engine directly.
//
// Its engine counts the GUI's selection as on screen (`showsSelection`), since the GUI
// has a screen of its own, unlike the daemon.
@MainActor
final class GUIStationHost {
    let station: StationCommands
    let server: StationSocketServer
    private var lock: StationLock?

    // `shortcuts` is the app's own store, so a terminal runs the same shortcuts the app
    // shows, and each sees the other's runs.
    convenience init(store: ProjectStore, runner: SessionRunner, shortcuts: ShortcutStore? = nil,
                     refreshInterval: Duration = .seconds(1), version: StationWire.Version = .current) {
        self.init(station: StationCommands(store: store, runner: runner, refreshInterval: refreshInterval,
                                           showsSelection: true, shortcuts: shortcuts),
                  version: version)
    }

    // Serves an engine already built. The contract suite uses it to hold the GUI's
    // server to the same scenarios as every other implementation.
    init(station: StationCommands, version: StationWire.Version = .current) {
        self.station = station
        server = StationSocketServer(station: station, version: version)
    }

    // Starts serving at `path` (or the short path standing in for it) and records the
    // endpoint in the lock, so front ends find it. Answers with the endpoint.
    @discardableResult
    func serve(at path: String, advertisingIn lock: StationLock?) throws -> String {
        let endpoint = try server.start(at: path)
        lock?.advertise(endpoint)
        self.lock = lock
        return endpoint
    }

    // Whether quitting must hand the station to a daemon (ADR-0003): a terminal is
    // attached, or a session is busy. Otherwise the app quits as it always has.
    var needsSuccessor: Bool {
        server.clientCount > 0 || station.isBusy
    }

    // Starts handing the station to a daemon as the app quits. `onStarted` runs once, as
    // new turns stop being taken; the app stops its own schedules there. `letGo` runs once
    // no turn is left: the app then quits as before (save, sweep, release the lock) and
    // starts the daemon, which claims the station. The handover answers with the turns
    // still running, for the app to ask about.
    func handOverForQuit(shortWait: Duration = .seconds(3),
                         onStarted: @escaping @MainActor () -> Void,
                         letGo: @escaping @MainActor () -> Void) -> StationHandover {
        station.onHandoverStarted = onStarted
        station.letGo = letGo
        return StationHandover(station: station.connect(), successor: StationLock.Kind.daemon.title,
                               shortWait: shortWait)
    }

    // Lets every client go and clears the endpoint from the lock. The lock itself stays
    // with the GUI, which hands it back on its own once everything is saved.
    func stop() {
        server.stop()
        lock?.advertise(nil)
        lock = nil
    }
}
