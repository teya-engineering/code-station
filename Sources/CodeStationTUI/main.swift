import CodeStationCore
import Darwin
import Foundation
import TerminalKit
import TerminalServices
import TerminalTranscript

// `code-station <subcommand>`: `tui`, the terminal front end, and `daemon`, the headless
// station host it attaches to (ADR-0002, ADR-0003).

private let usage = """
usage: code-station tui
       code-station daemon

  tui     Browse Code Station's projects and sessions, and read their transcripts. It
          attaches to whichever host holds the station, and starts the background
          service when nobody does.
  daemon  Run the background service: hold the station and serve it to terminals. It
          exits once nothing has run and nobody has been attached for ten minutes.

Environment:
  CODE_STATION_STORE      Use this project index instead of the app's. The station lock
                          and socket are kept in the same folder, so a scratch copy never
                          touches the app.
  CODE_STATION_IDLE_EXIT  Seconds the background service waits idle before it exits
                          (600 by default).
  NO_COLOR                Draw without colour.
  COLORTERM, TERM         How many colours to draw with: truecolor or 24bit, a 256color
                          TERM, or the basic 16. TERM=dumb draws without colour.
"""

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("code-station: \(message)\n".utf8))
    exit(code)
}

// The index the GUI uses lives in Application Support beside the station lock. A store
// pointed somewhere else takes its lock along, so a scratch copy is a station of its own.
private func storeAndLock() -> (store: URL?, lock: URL) {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["CODE_STATION_STORE"], !path.isEmpty else {
        return (nil, StationLock.defaultFile)
    }
    let store = URL(fileURLWithPath: path)
    return (store, store.deletingLastPathComponent().appendingPathComponent("station.lock"))
}

// As many colours as the terminal says it has (see TranscriptTheme.ColourDepth).
private func transcriptTheme() -> TranscriptTheme {
    TranscriptTheme(environment: ProcessInfo.processInfo.environment)
}

// MARK: - tui

@MainActor private enum Running {
    static var app: TUIApp?
}

@MainActor
private func runTUI() -> Never {
    // Read the app's preferences even when started from outside its bundle.
    Preferences.followStation()
    let (_, lockFile) = storeAndLock()

    guard Terminal.isInteractive else {
        fail("the TUI needs a terminal on standard input and output.", code: 2)
    }

    // Writing to a host that has just gone must fail as an error, not kill the TUI.
    signal(SIGPIPE, SIG_IGN)

    // The TUI is always a client: of whichever host holds the station, or of a daemon it
    // starts. Settled before the terminal is touched, so a refusal prints on a normal
    // screen.
    Task { @MainActor in
        let station: StationSocketClient
        do {
            station = try await StationDiscovery.attach(lockFile: lockFile, startHost: startDaemon)
        } catch {
            fail((error as? StationRefusal)?.message ?? "\(error)", code: 3)
        }
        SessionLog.note("terminal attached")

        let terminal = Terminal()
        let host = TerminalHost(output: { [weak terminal] in terminal?.write($0) })
        // Quitting lets go of the host and leaves its sessions running.
        let app = TUIApp(terminal: terminal, commands: station, theme: transcriptTheme(),
                         shutdown: { station.close() })
        app.host = host
        app.handoff = TerminalHandoffRunner(terminal: terminal)
        host.askForPath = { [weak app] prompt, message, start in
            await app?.askForPath(prompt: prompt, message: message, startingAt: start)
        }
        app.start()
        // The app outlives this task: it runs until it quits the process.
        Running.app = app
    }
    // One loop serves the main queue (main-actor work, the terminal's sources) and the
    // core's Foundation timers, as AppKit's loop does for the GUI.
    while true { RunLoop.main.run() }
}

// Starts `code-station daemon` from this same binary, detached (see
// `StationDaemon.launch`). The station folder comes along in the environment.
@MainActor
private func startDaemon() throws {
    let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath().path
    try StationDaemon.launch(executable: executable)
}

// MARK: - daemon

@MainActor
private func runDaemon() -> Never {
    Preferences.followStation()
    let (store, lockFile) = storeAndLock()

    let lock: StationLock
    switch StationLock.claim(.daemon, at: lockFile) {
    case .claimed(let claimed):
        lock = claimed
    case .refused(let holder?):
        fail("\(holder.name) already owns this station.", code: 3)
    case .refused(nil):
        fail("another Code Station is starting, or \(lockFile.path) could not be opened.", code: 3)
    }

    signal(SIGPIPE, SIG_IGN)
    SessionLog.note("daemon launched")
    StationUpkeep.launchHousekeeping()

    let environment = ProcessInfo.processInfo.environment
    let grace = environment["CODE_STATION_IDLE_EXIT"].flatMap(Double.init).map { Duration.seconds($0) }
        ?? StationDaemon.defaultIdleGrace
    // Nobody sits in front of a daemon, so what a turn would tell the person goes only to
    // its clients, which hear it as host events and tell their own person.
    let station = StationCommands.start(host: SilentHost(), storeURL: store)
    let daemon: StationDaemon
    do {
        daemon = try StationDaemon(station: station, upkeep: StationUpkeep(station: station),
                                   lock: lock, socketPath: StationSocketPath.beside(lockFile),
                                   idleGrace: grace, onExit: {
                                       SessionLog.note("daemon stopped")
                                       SessionLog.flush()
                                       exit(0)
                                   })
    } catch {
        station.shutdown()
        lock.release()
        fail("could not serve the station: \(error)", code: 1)
    }

    // launchd and `kill` stop a service with SIGTERM, a terminal with SIGINT. Either one
    // stops it cleanly: the quit sweep, a save, then the lock goes back.
    let stops = [SIGTERM, SIGINT].map { name -> DispatchSourceSignal in
        signal(name, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: name, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { daemon.shutdown() } }
        source.resume()
        return source
    }
    while true {
        withExtendedLifetime(stops) { RunLoop.main.run() }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "tui":
    MainActor.assumeIsolated { runTUI() }
case "daemon":
    MainActor.assumeIsolated { runDaemon() }
case "-h", "--help", "help":
    print(usage)
case nil:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
case let other?:
    fail("unknown command '\(other)'.\n\n\(usage)", code: 64)
}
