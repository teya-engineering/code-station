import Darwin
import Foundation

// `code-station daemon`: a station host with no window. It holds the station lock,
// serves the station on its socket and records the socket in the lock, so front ends find
// it. It ends cleanly when told to (SIGTERM, SIGINT), and on its own once it has had no
// clients and nothing busy for its grace period.
@MainActor
public final class StationDaemon {
    public static let defaultIdleGrace: Duration = .seconds(600)

    public let station: StationCommands
    public let server: StationSocketServer
    // The work the station does unasked (schedules, sweeps), started here and stopped
    // before the quit sweep.
    public let upkeep: StationUpkeep?
    private let lock: StationLock
    private let onExit: @MainActor () -> Void
    private var idleWatch: Task<Void, Never>?
    private var finished = false

    // Starts serving at once. `onExit` runs after `shutdown`, whatever called it; the
    // daemon's main exits the process there.
    public init(station: StationCommands, upkeep: StationUpkeep? = nil,
                lock: StationLock, socketPath: String,
                idleGrace: Duration = StationDaemon.defaultIdleGrace,
                version: StationWire.Version = .current,
                onExit: @escaping @MainActor () -> Void) throws {
        self.station = station
        self.upkeep = upkeep
        self.lock = lock
        self.onExit = onExit
        server = StationSocketServer(station: station, version: version)
        let endpoint = try server.start(at: socketPath)
        lock.advertise(endpoint)
        upkeep?.start()
        watchForIdle(grace: idleGrace)
        // A GUI that opens asks the daemon to hand the station over (ADR-0003). Nothing
        // new starts here from then on, and once no turn runs the daemon lets go.
        station.onHandoverStarted = { [weak self] in self?.upkeep?.stop() }
        station.onHandoverAbandoned = { [weak self] in self?.upkeep?.start() }
        station.letGo = { [weak self] in self?.shutdown() }
    }

    // Nobody attached and nothing running: no turn, and no shortcut a client started,
    // such as a dev server, which exiting would stop.
    public var isIdle: Bool {
        server.clientCount == 0 && !station.isBusy && !station.shortcuts.isRunningAny
    }

    // Lets the clients go, runs the quit sweep and saves, then hands the station back.
    public func shutdown() {
        guard !finished else { return }
        finished = true
        idleWatch?.cancel()
        idleWatch = nil
        upkeep?.stop()
        server.stop()
        station.shutdown()
        lock.advertise(nil)
        lock.release()
        onExit()
    }

    private func watchForIdle(grace: Duration) {
        let tick = min(max(grace / 20, .milliseconds(10)), .seconds(5))
        idleWatch = Task { @MainActor [weak self] in
            var idleSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                guard let self else { return }
                if self.isIdle {
                    let since = idleSince ?? .now
                    idleSince = since
                    if ContinuousClock.now - since >= grace {
                        SessionLog.note("daemon idle for \(grace), exiting")
                        return self.shutdown()
                    }
                } else {
                    idleSince = nil
                }
                try? await Task.sleep(for: tick)
            }
        }
    }
}

extension StationDaemon {
    // Starts `code-station daemon` from `executable`, detached: in a session of its own,
    // so closing the terminal (or quitting the app) that started it does not take it down,
    // with nothing of its parent's open. It inherits the environment, so a station kept
    // elsewhere (`CODE_STATION_STORE`) comes along.
    public static func launch(executable: String) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let arguments = [executable, "daemon"].map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid = pid_t(0)
        let result = posix_spawn(&pid, executable, &actions, &attributes, arguments, environ)
        guard result == 0 else {
            throw LaunchFailure(description: "\(executable): \(String(cString: strerror(result)))")
        }
    }

    public struct LaunchFailure: Error, CustomStringConvertible {
        public let description: String
    }
}

// How a front end reaches the station: through the host recorded in the station lock, or,
// when nobody holds the station, by starting a host and waiting for it to record its
// socket. A host that takes the connection but does not answer it (one busy handing
// over) is not waited on here: the client comes back at once, says through its
// `linkUpdates()` that the station is not answering, and attaches by itself once a host
// answers.
public enum StationDiscovery {
    @MainActor
    public static func attach(lockFile: URL = StationLock.defaultFile,
                              startHost: @MainActor () throws -> Void,
                              waitingUpTo timeout: Duration = .seconds(15),
                              version: StationWire.Version = .current,
                              patience: StationSocketClient.Patience = .standard) async throws(StationRefusal) -> StationSocketClient {
        let deadline = ContinuousClock.now + timeout
        var started = false
        var lastHolder: StationLock.Holder?
        var lastFailure: StationRefusal?
        while true {
            if let holder = StationLock.holder(at: lockFile) {
                lastHolder = holder
                if holder.endpoint != nil {
                    let client = StationSocketClient(lockFile: lockFile, version: version, patience: patience)
                    do {
                        try await client.connect()
                        return client
                    } catch {
                        if client.isRefused { throw error }
                        // It keeps trying by itself, and the front end says why it waits.
                        if error == .notAnswering { return client }
                        client.close()
                        lastFailure = error
                    }
                }
            } else if !started {
                started = true
                do {
                    try startHost()
                } catch {
                    throw StationRefusal("Could not start the station's background service: \(error)")
                }
            }
            guard ContinuousClock.now < deadline else {
                if let lastHolder, lastHolder.endpoint == nil {
                    throw StationRefusal("\(lastHolder.name) owns this station and does not take "
                                         + "terminal clients. Quit it, then try again.")
                }
                throw lastFailure ?? StationRefusal("The station's background service did not start.")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
