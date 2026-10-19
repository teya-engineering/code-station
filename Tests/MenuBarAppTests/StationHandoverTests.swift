import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// Part of the station contract (see StationContract.swift): handing the station from one
// host to another (ADR-0003). The host handing over tells its clients, refuses new turns,
// lists the turns still running until they end, and only then lets go; its clients find
// the next host on their own and carry on where they were.
@MainActor
struct StationHandoverTests {

    // Once a handover starts, nothing new runs on the host that is leaving: a prompt, a
    // new session or a scheduled run is refused, saying where the station is going. Every
    // client hears that the handover started.
    @Test(arguments: StationImplementation.allCases)
    func newTurnsAreRefusedDuringAHandover(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        station.letGo = {}
        let client = kind.connect(to: station)
        let heard = HostEventLog()
        let listener = Task { @MainActor in
            for await event in client.hostEvents() { heard.events.append(event) }
        }
        defer { listener.cancel() }
        #expect(await waitUntil { station.hostEventListeners == 1 })

        let status = try await station.connect().handOver(to: "the Code Station app")

        #expect(status.running.isEmpty)
        #expect(await waitUntil { heard.events == [.handoverStarting(successor: "the Code Station app")] },
                "\(heard.events)")
        let id = fixture.session.id.uuidString
        let refused = await refusal { try await client.sendPrompt(id, prompt: "hello") }
        #expect(refused?.message == "The station is moving to the Code Station app. Try again in a moment.")
        let project = try #require(fixture.store.projects.first)
        let created = await refusal {
            try await client.createSession(RemoteNewSession(projectID: project.id.uuidString, agent: .claudeCode,
                                                            model: nil, worktree: false))
        }
        #expect(created == refused)
        #expect(!fixture.runner.isBusy(fixture.session.id, store: fixture.store))
    }

    // A turn already running is neither moved nor cut off: the handover lists it, the
    // host will not let go while it runs, and lets go once it has ended.
    @Test(arguments: StationImplementation.allCases)
    func theHostLetsGoOnlyOnceRunningTurnsHaveEnded(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.renameSession(fixture.session.id, to: "Fix login")
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        var letGo = 0
        station.letGo = { letGo += 1 }
        let next = kind.connect(to: station)
        let id = fixture.session.id.uuidString
        try await next.sendPrompt(id, prompt: "hello")
        #expect(await waitUntil { fixture.runner.isBusy(fixture.session.id, store: fixture.store) })

        let status = try await next.handOver(to: "the Code Station app")

        #expect(status.running == [RemoteRunningTurn(sessionID: id, title: "Fix login", project: "project")])
        #expect(await refusal { try await next.releaseStation() }?.message == "A turn is still running.")
        #expect(letGo == 0)
        try Data().write(to: fixture.scratch.path("release"))
        #expect(await eventually { try await next.handOver(to: "the Code Station app").running.isEmpty })
        try await next.releaseStation()
        #expect(await waitUntil { letGo == 1 })
    }

    // The side taking over goes away before the host lets go (its window closed, or it
    // crashed). The handover is given up: new turns run again, the host starts its own
    // work again, and its clients no longer hear that the station is moving.
    @Test(arguments: StationImplementation.allCases)
    func aHandoverIsGivenUpWhenTheSideTakingOverGoesAway(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        var letGo = 0, started = 0, abandoned = 0
        station.letGo = { letGo += 1 }
        station.onHandoverStarted = { started += 1 }
        station.onHandoverAbandoned = { abandoned += 1 }
        let terminal = kind.connect(to: station)
        let taking = kind.connect(to: station)
        _ = try await taking.handOver(to: "the Code Station app")
        #expect(started == 1)
        #expect(try await terminal.listDirectory().handingOverTo == "the Code Station app")

        if let socket = taking as? StationSocketClient { socket.close() } else { await taking.disconnect() }

        #expect(await waitUntil { station.successor == nil })
        #expect(abandoned == 1)
        #expect(letGo == 0)
        #expect(try await terminal.listDirectory().handingOverTo == nil)
        try await terminal.sendPrompt(fixture.session.id.uuidString, prompt: "hello")
        #expect(fixture.store.transcript(of: fixture.session.id).contains { $0.role == .user && $0.text == "hello" })
    }

    // The daemon stops its schedules when a handover starts, and starts them again when
    // the GUI that asked goes away before taking the station.
    @Test func theDaemonCarriesOnWhenTheGUITakingOverGoesAway() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let station = StationCommands(store: fixture.store, runner: fixture.runner, refreshInterval: .milliseconds(50))
        let upkeep = StationUpkeep(station: station)
        let exits = Counter()
        let daemon = try StationDaemon(station: station, upkeep: upkeep, lock: lock,
                                       socketPath: StationSocketPath.beside(lockFile),
                                       onExit: { exits.count += 1 })
        defer { daemon.shutdown() }
        #expect(upkeep.isRunning)

        let gui = StationSocketClient(endpoint: { StationLock.holder(at: lockFile)?.endpoint })
        _ = try await gui.handOver(to: "the Code Station app")
        #expect(!upkeep.isRunning)
        gui.close()

        #expect(await waitUntil { upkeep.isRunning })
        #expect(exits.count == 0)
        #expect(StationLock.holder(at: lockFile)?.kind == .daemon)
    }

    // A daemon from another build refuses the updated GUI's handshake, so it cannot be
    // asked to hand over. It is told to stop instead (SIGTERM to the pid in the lock), and
    // the GUI claims the station once it has let go.
    @Test func aHostOfAnotherBuildIsStoppedAndTheStationClaimed() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let exits = Counter()
        let daemon = try StationDaemon(station: StationCommands(store: fixture.store, runner: fixture.runner),
                                       lock: lock, socketPath: StationSocketPath.beside(lockFile),
                                       version: StationWire.Version(protocolVersion: 1, build: "1.0.0 (100)"),
                                       onExit: { exits.count += 1 })
        defer { daemon.shutdown() }
        let gui = StationSocketClient(endpoint: { StationLock.holder(at: lockFile)?.endpoint })
        defer { gui.close() }
        let handover = StationHandover(station: gui, successor: "the Code Station app")
        await #expect(throws: StationRefusal.self) { try await handover.run() }
        #expect(gui.isRefused)

        var told: [pid_t] = []
        let claimed = await StationLock.stopHolder(at: lockFile, claiming: .gui, terminate: { pid in
            told.append(pid)
            daemon.shutdown()
        })

        #expect(told == [getpid()])
        #expect(exits.count == 1)
        let taken = try #require(claimed.lock)
        defer { taken.release() }
        #expect(StationLock.holder(at: lockFile)?.kind == .gui)
    }

    // A host with no way to hand over (the GUI while it runs) refuses to be asked.
    @Test func aHostThatDoesNotHandOverRefusesToBeAsked() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner)

        let refused = await refusal { try await station.connect().handOver(to: "the Code Station app") }

        #expect(refused != nil)
        #expect(station.successor == nil)
    }

    // The daemon hands the station to a GUI that has just opened, while a terminal is
    // attached. The daemon saves and lets go, the GUI claims the station and serves it,
    // and the terminal ends up on the GUI's socket with the same sessions: its live list,
    // its open session and its commands carry on there without it doing anything.
    @Test func aClientFollowsTheStationToTheHostItWasHandedTo() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let id = fixture.session.id
        fixture.store.append(ChatMessage(role: .assistant, text: "Before"), to: id)
        let lock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let exits = Counter()
        let daemon = try StationDaemon(station: StationCommands(store: fixture.store, runner: fixture.runner,
                                                                refreshInterval: .milliseconds(50)),
                                       lock: lock, socketPath: StationSocketPath.beside(lockFile),
                                       onExit: { exits.count += 1 })
        defer { daemon.shutdown() }

        let terminal = StationSocketClient(endpoint: { StationLock.holder(at: lockFile)?.endpoint })
        defer { terminal.close() }
        let titles = Titles()
        let lister = Task { @MainActor in
            for await directory in terminal.directoryUpdates() {
                titles.seen.append(directory.projects.first?.sessions.first?.title ?? "")
            }
        }
        defer { lister.cancel() }
        let heard = HostEventLog()
        let listener = Task { @MainActor in
            for await event in terminal.hostEvents() { heard.events.append(event) }
        }
        defer { listener.cancel() }
        let opened = try #require(try await terminal.openSession(id.uuidString))
        let log = EventLog()
        log.mirror = RemoteTranscript(opened.snapshot)
        let reader = Task { @MainActor in
            for await event in opened.events {
                log.events.append(event)
                log.mirror?.apply(event)
            }
            log.ended = true
        }
        defer { reader.cancel() }
        #expect(await waitUntil { !titles.seen.isEmpty && daemon.station.hostEventListeners == 1 })
        fixture.store.renameSession(id, to: "Renamed before the handover")

        // The GUI, finding the daemon in the lock, asks it to hand over and claims the
        // station once it is free.
        let gui = StationSocketClient(endpoint: { StationLock.holder(at: lockFile)?.endpoint })
        let handover = StationHandover(station: gui, successor: "the Code Station app")
        try await handover.run()
        let claimed = try #require(await StationLock.claimOnceReleased(.gui, at: lockFile).lock)
        gui.close()

        #expect(exits.count == 1)
        #expect(heard.events.contains(.handoverStarting(successor: "the Code Station app")))
        // The GUI opens the station from disk, as it does at launch, and serves it.
        let store = ProjectStore(storeURL: fixture.scratch.path("projects.json"))
        let runner = SessionRunner(paths: [.claudeCode: fixture.executable.path], host: RecordingHost())
        let host = GUIStationHost(store: store, runner: runner, refreshInterval: .milliseconds(50))
        try host.serve(at: StationSocketPath.beside(lockFile), advertisingIn: claimed)
        defer {
            host.stop()
            claimed.release()
        }

        #expect(await waitUntil { host.server.clientCount == 1 })
        #expect(await waitUntil { titles.seen.last == "Renamed before the handover" }, "\(titles.seen)")
        #expect(await waitUntil {
            if case .snapshot = log.events.last { return true }
            return false
        })
        store.append(ChatMessage(role: .assistant, text: "After"), to: id)
        #expect(await waitUntil { log.mirror?.messages.map(\.text) == ["Before", "After"] },
                "\(log.mirror?.messages.map(\.text) ?? [])")
        #expect(log.ended == false)
        // New turns run again, now on the GUI's runner.
        #expect(await eventually {
            (try? await terminal.sendPrompt(id.uuidString, prompt: "hello")) != nil
        })
        #expect(store.transcript(of: id).contains { $0.role == .user && $0.text == "hello" })
    }

    // Turns that do not end within the short wait are put to the person, named. Choosing
    // to stop them stops them, and the host lets go once they have gone.
    @Test(arguments: StationImplementation.allCases)
    func turnsStillRunningAfterAShortWaitAreAskedAboutAndCanBeStopped(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.renameSession(fixture.session.id, to: "Fix login")
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        var letGo = 0
        station.letGo = { letGo += 1 }
        let client = kind.connect(to: station)
        try await client.sendPrompt(fixture.session.id.uuidString, prompt: "hello")
        #expect(await waitUntil { fixture.runner.isBusy(fixture.session.id, store: fixture.store) })
        let handover = StationHandover(station: client, successor: "the background service",
                                       shortWait: .milliseconds(200), pace: .milliseconds(20))
        let running = Task { @MainActor in try await handover.run() }

        #expect(await waitUntil { handover.isAsking })
        #expect(handover.running.map(\.title) == ["Fix login"])
        #expect(letGo == 0)

        handover.stopTurns()

        try await running.value
        #expect(handover.phase == .released)
        #expect(await waitUntil { letGo == 1 })
        #expect(!fixture.runner.isBusy(fixture.session.id, store: fixture.store))
    }

    // A turn that starts after the person chose to stop the others (the GUI's own prompt
    // as it quits) is put to them again, rather than leaving the handover stopping with
    // nothing on screen.
    @Test func aTurnStartedAfterStoppingIsAskedAboutAgain() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        // In a folder of its own, since sessions sharing a folder cannot run together.
        try FileManager.default.createDirectory(at: fixture.scratch.path("other"), withIntermediateDirectories: true)
        let other = try #require(fixture.store.addProject(at: fixture.scratch.path("other")))
        let later = try fixture.store.insertSession(in: other.id, seed: .init(agent: .claudeCode)).get()
        fixture.store.renameSession(fixture.session.id, to: "Fix login")
        fixture.store.renameSession(later.id, to: "Typed while quitting")
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        var letGo = 0
        station.letGo = { letGo += 1 }
        try station.sendPrompt(fixture.session.id.uuidString, prompt: "hello")
        #expect(await waitUntil { fixture.runner.isBusy(fixture.session.id, store: fixture.store) })
        let handover = StationHandover(station: station.connect(), successor: "the background service",
                                       shortWait: .milliseconds(200), pace: .milliseconds(20))
        let running = Task { @MainActor in try await handover.run() }
        #expect(await waitUntil { handover.isAsking })

        handover.stopTurns()
        // Typed in the GUI, which does not go through the station.
        fixture.runner.send("one more", sessionID: later.id, store: fixture.store)

        #expect(await waitUntil { handover.isAsking && handover.running.map(\.title) == ["Typed while quitting"] },
                "\(handover.phase) \(handover.running.map(\.title))")
        #expect(letGo == 0)
        handover.stopTurns()
        try await running.value
        #expect(await waitUntil { letGo == 1 })
    }

    // Turns that end within the short wait are never asked about.
    @Test func turnsThatEndWithinTheShortWaitAreNotAskedAbout() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        station.letGo = {}
        try station.sendPrompt(fixture.session.id.uuidString, prompt: "hello")
        #expect(await waitUntil { fixture.runner.isBusy(fixture.session.id, store: fixture.store) })
        let handover = StationHandover(station: station.connect(), successor: "the background service",
                                       shortWait: .seconds(30), pace: .milliseconds(20))
        let running = Task { @MainActor in try await handover.run() }
        #expect(await waitUntil { handover.running.count == 1 })

        try Data().write(to: fixture.scratch.path("release"))

        try await running.value
        #expect(handover.phase == .released)
    }

    // A background service that takes the connection but never answers (a host stuck on
    // its main thread) is not taken for one that refused. The takeover says it is not
    // answering, offers to stop it or quit, and keeps trying: once a service answers, it
    // hands over and the app takes the station.
    @Test func aSilentServiceIsWaitedForAndTakenOverOnceOneAnswers() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let silentLock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let silentPath = StationSocketPath.usable(fixture.scratch.path("silent.sock").path)
        let silent = try UnixSocket.listen(at: silentPath)
        silentLock.advertise(silentPath)
        var claimed: StationLock?
        let takeover = StationTakeoverLaunch(lockFile: lockFile,
                                             patience: .init(handshake: .milliseconds(300),
                                                             namingHolder: .seconds(20)),
                                             onClaimed: { claimed = $0 })

        takeover.begin()

        #expect(await waitUntil { takeover.dialogs.current?.title == "The background service isn't answering" },
                "\(takeover.dialogs.current?.title ?? "no Dialog")")
        #expect(takeover.dialogs.current?.actions.map(\.label) == ["Stop it and take over", "Quit"])
        try await Task.sleep(for: .seconds(1))
        #expect(takeover.dialogs.current?.title == "The background service isn't answering")
        #expect(claimed == nil)

        // The silent service goes, and one that answers takes its place.
        close(silent)
        unlink(silentPath)
        silentLock.release()
        let daemonLock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let daemon = try StationDaemon(station: StationCommands.start(host: RecordingHost(),
                                                                      storeURL: fixture.scratch.path("projects.json")),
                                       lock: daemonLock, socketPath: StationSocketPath.beside(lockFile),
                                       onExit: {})

        #expect(await waitUntil { claimed != nil })
        #expect(takeover.dialogs.current == nil)
        if let claimed { claimed.release() } else { daemon.shutdown() }
    }

    private static let waitsForRelease = """
    IFS= read -r input
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
    wait_for "$folder/release"
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
    """

    private func refusal(_ command: () async throws -> some Any) async -> StationRefusal? {
        do {
            _ = try await command()
            return nil
        } catch {
            return error as? StationRefusal
        }
    }
}

@MainActor
private final class Counter {
    var count = 0
}

@MainActor
private final class Titles {
    var seen: [String] = []
}
