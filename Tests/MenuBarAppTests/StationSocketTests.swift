import Darwin
import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift) for what only a socket has: the
// handshake, who may connect, a host that goes away and comes back, the daemon's life and
// how a front end finds or starts a host. Every scenario talks to a real socket server
// started in the test on a scratch store.
@MainActor
struct StationSocketTests {

    // Builds that disagree are told so on connect, with both versions named, rather than
    // left to misread each other.
    @Test func aClientOfAnotherVersionIsRefusedWithBothVersionsNamed() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = ScratchDirectory(prefix: "station-socket")
        let host = StationWire.Version(protocolVersion: 1, build: "1.4.0 (140)")
        let server = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner),
                                         version: host)
        let endpoint = try server.start(at: scratch.path("station.sock").path)
        defer { server.stop() }
        let client = StationSocketClient(path: endpoint,
                                         version: StationWire.Version(protocolVersion: 2, build: "1.5.0 (151)"))

        let refusal = await refusal { try await client.listDirectory() }

        #expect(refusal?.message.contains("build 1.5.0 (151), protocol 2") == true)
        #expect(refusal?.message.contains("build 1.4.0 (140), protocol 1") == true)
        #expect(server.clientCount == 0)
        // Final: asking again does not try again.
        #expect(await self.refusal { try await client.listDirectory() } == refusal)
    }

    // Only this user's processes may drive the station. The check is the kernel's word on
    // the peer's uid, stood in for here by a peer of another user.
    @Test func aPeerOfAnotherUserIsRefused() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = ScratchDirectory(prefix: "station-socket")
        let stranger = getuid() + 1
        let server = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner),
                                         peerUID: { _ in stranger })
        let endpoint = try server.start(at: scratch.path("station.sock").path)
        defer { server.stop() }

        let refusal = await refusal { try await StationSocketClient(path: endpoint).listDirectory() }

        #expect(refusal?.message == "This station belongs to another user.")
        #expect(server.clientCount == 0)
    }

    // A client need not wait for the welcome: a hello and the first requests written in
    // one go are each answered, in order.
    @Test func requestsSentWithTheHelloAreAnswered() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = ScratchDirectory(prefix: "station-socket")
        let server = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner))
        let endpoint = try server.start(at: scratch.path("station.sock").path)
        defer { server.stop() }
        let fd = try #require(UnixSocket.connect(to: endpoint))
        let socket = LineSocket(fd: fd)
        defer { socket.close() }
        let lines = LineLog()
        socket.start(onLine: { lines.seen.append(String(decoding: $0, as: UTF8.self)) }, onClose: {})
        let hello = String(decoding: StationWire.encode(StationWire.Hello(hello: .current))!, as: UTF8.self)
        socket.send(Data((hello + "\n"
                          + #"{"id":1,"request":{"sessionOptions":{}}}"# + "\n"
                          + #"{"id":2,"request":{"listDirectory":{}}}"#).utf8))

        #expect(await waitUntil { lines.seen.count == 3 })
        #expect(lines.seen.first?.contains("welcome") == true)
        #expect(lines.seen.dropFirst().first?.contains(#""id":1"#) == true)
        #expect(lines.seen.last?.contains(#""type":"directory""#) == true)
    }

    // A command that takes its time holds up nothing else the client asks for: a stop,
    // a permission answer or a list is answered while it is still under way.
    @Test func aSlowCommandDoesNotHoldUpTheClientsOtherCommands() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = ScratchDirectory(prefix: "station-socket")
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let gate = Gate()
        station.diagnosis = DiagnosisSupport(environments: { [] }, servers: { [] },
                                             skills: { _ in await gate.wait(); return ["slow"] },
                                             enabledServers: { _, _ in [] })
        let server = StationSocketServer(station: station)
        let endpoint = try server.start(at: scratch.path("station.sock").path)
        defer { server.stop() }
        let client = StationSocketClient(path: endpoint)
        defer { client.close() }
        try await client.connect()

        let slow = Task { @MainActor in try await client.diagnosisOptions(sessionID: nil, agent: .claudeCode) }
        #expect(await waitUntil { gate.waiting })
        let answered = LineLog()
        Task { @MainActor in
            _ = try? await client.listDirectory()
            answered.seen.append("list")
        }
        Task { @MainActor in
            _ = try? await client.stopTurn(fixture.session.id.uuidString)
            answered.seen.append("stop")
        }

        #expect(await waitUntil(timeout: .seconds(5)) { answered.seen.count == 2 }, "\(answered.seen)")
        #expect(gate.waiting)
        gate.open()
        #expect(try await slow.value.skills == ["slow"])
    }

    // The host that comes back refuses the client (another build took the station). The
    // streams it handed out end, since nothing will feed them again, and asking says why.
    @Test func aRefusedReconnectEndsTheClientsStreams() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = ScratchDirectory(prefix: "station-socket")
        let preferred = scratch.path("station.sock").path
        let server = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner))
        let path = try server.start(at: preferred)
        let client = StationSocketClient(endpoint: { path }, retryInterval: .milliseconds(20))
        defer { client.close() }
        let ended = LineLog()
        let lister = Task { @MainActor in
            for await _ in client.directoryUpdates() { ended.seen.append("list") }
            ended.seen.append("ended")
        }
        defer { lister.cancel() }
        let listener = Task { @MainActor in
            for await _ in client.hostEvents() {}
            ended.seen.append("events ended")
        }
        defer { listener.cancel() }
        #expect(await waitUntil { ended.seen.contains("list") })

        server.stop()
        let newer = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner),
                                        version: StationWire.Version(protocolVersion: 99, build: "9.9.9 (999)"))
        try newer.start(at: preferred)
        defer { newer.stop() }

        #expect(await waitUntil { ended.seen.contains("ended") && ended.seen.contains("events ended") },
                "\(ended.seen)")
        let refusal = await refusal { try await client.listDirectory() }
        #expect(refusal?.message.contains("9.9.9 (999)") == true, "\(String(describing: refusal))")
    }

    // The socket is this user's alone on disk too.
    @Test func theSocketFileIsOnlyForThisUser() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = ScratchDirectory(prefix: "station-socket")
        let server = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner))
        let endpoint = try server.start(at: scratch.path("station.sock").path)
        defer { server.stop() }

        var info = stat()
        #expect(stat(endpoint, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == getuid())
    }

    // A station folder deep enough to pass `sun_path` still gets a socket, at a short
    // path of its own in the temporary folder, and clients reach it there.
    @Test func aHostInAFolderTooDeepForASocketServesFromAShortPath() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = ScratchDirectory(prefix: "station-socket")
        let deep = scratch.path(String(repeating: "deep-folder/", count: 12) + "station.sock").path
        #expect(deep.utf8.count > 104)
        let server = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner))
        let endpoint = try server.start(at: deep)
        defer { server.stop() }

        #expect(endpoint.utf8.count < 104)
        let directory = try await StationSocketClient(path: endpoint).listDirectory()
        #expect(directory.projects.count == 1)
    }

    // A host that stops while a client is attached refuses what was waiting on it. When
    // a host serves the station again, the client finds it on its own, subscribes to the
    // list again and carries on each open session from a fresh snapshot.
    @Test func aClientReconnectsAndResubscribesWhenTheHostComesBack() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let scratch = ScratchDirectory(prefix: "station-socket")
        let path = scratch.path("station.sock").path
        let id = fixture.session.id.uuidString
        fixture.store.append(ChatMessage(role: .assistant, text: "Before"), to: fixture.session.id)
        let first = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner,
                                                                 refreshInterval: .milliseconds(50)))
        let endpoint = try first.start(at: path)
        let client = StationSocketClient(path: endpoint)
        let titles = TitleLog()
        let lister = Task { @MainActor in
            for await directory in client.directoryUpdates() {
                titles.seen.append(directory.projects.first?.sessions.first?.title ?? "")
            }
        }
        defer { lister.cancel() }
        let opened = try #require(try await client.openSession(id))
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
        #expect(await waitUntil { !titles.seen.isEmpty })

        first.stop()

        #expect(await eventually { await self.refusal { try await client.listDirectory() } == .hostGone })
        fixture.store.renameSession(fixture.session.id, to: "Renamed while away")
        let second = StationSocketServer(station: StationCommands(store: fixture.store, runner: fixture.runner,
                                                                  refreshInterval: .milliseconds(50)))
        #expect(try second.start(at: path) == endpoint)
        defer { second.stop() }

        #expect(await waitUntil { titles.seen.last == "Renamed while away" })
        #expect(await waitUntil {
            if case .snapshot = log.events.last { return true }
            return false
        })
        fixture.store.append(ChatMessage(role: .assistant, text: "After"), to: fixture.session.id)
        #expect(await waitUntil { log.mirror?.messages.map(\.text) == ["Before", "After"] })
        #expect(log.ended == false)
        #expect(second.clientCount == 1)
    }

    // The daemon lives while it has work: it stays while a turn runs with nobody
    // attached, and once nothing is busy and nobody is attached for its grace, it saves,
    // hands the station back and exits.
    @Test func theDaemonExitsOnceNothingIsBusyAndNobodyIsAttachedForItsGrace() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let exits = ExitLog()
        let daemon = try StationDaemon(station: StationCommands(store: fixture.store, runner: fixture.runner),
                                       lock: lock, socketPath: StationSocketPath.beside(lockFile),
                                       idleGrace: .milliseconds(300), onExit: { exits.count += 1 })
        defer { daemon.shutdown() }
        // The lock says where the daemon listens.
        #expect(StationLock.holder(at: lockFile)?.kind == .daemon)
        #expect(StationLock.holder(at: lockFile)?.endpoint == daemon.server.endpoint)
        let client = StationSocketClient(endpoint: { StationLock.holder(at: lockFile)?.endpoint })
        try await client.sendPrompt(fixture.session.id.uuidString, prompt: "hello")
        #expect(await waitUntil { fixture.runner.isBusy(fixture.session.id, store: fixture.store) })

        await client.disconnect()
        try await Task.sleep(for: .milliseconds(900))
        #expect(exits.count == 0)

        try Data().write(to: fixture.scratch.path("release"))

        #expect(await waitUntil { exits.count == 1 })
        #expect(StationLock.holder(at: lockFile) == nil)
        let next = try #require(StationLock.claim(.gui, at: lockFile).lock)
        next.release()
    }

    // An attached client keeps the daemon up however long it stays idle.
    @Test func theDaemonStaysWhileAClientIsAttached() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let exits = ExitLog()
        let daemon = try StationDaemon(station: StationCommands(store: fixture.store, runner: fixture.runner),
                                       lock: lock, socketPath: StationSocketPath.beside(lockFile),
                                       idleGrace: .milliseconds(200), onExit: { exits.count += 1 })
        defer { daemon.shutdown() }
        let client = StationSocketClient(endpoint: { StationLock.holder(at: lockFile)?.endpoint })
        try await client.connect()

        try await Task.sleep(for: .milliseconds(800))
        #expect(exits.count == 0)

        await client.disconnect()

        #expect(await waitUntil { exits.count == 1 })
    }

    // A front end with no host starts one and attaches. Quitting it leaves the turn it
    // started running, and the next front end attaches to the same host and finds it.
    @Test func aFrontEndWithNoHostStartsOneAndTheNextAttachesToIt() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: Self.waitsForRelease, host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let exits = ExitLog()
        var started: [StationDaemon] = []
        defer { started.forEach { $0.shutdown() } }
        let startHost: @MainActor () throws -> Void = {
            guard let lock = StationLock.claim(.daemon, at: lockFile).lock else { return }
            started.append(try StationDaemon(station: StationCommands(store: fixture.store, runner: fixture.runner),
                                             lock: lock, socketPath: StationSocketPath.beside(lockFile),
                                             onExit: { exits.count += 1 }))
        }
        let id = fixture.session.id.uuidString

        let first = try await StationDiscovery.attach(lockFile: lockFile, startHost: startHost)
        #expect(started.count == 1)
        try await first.sendPrompt(id, prompt: "hello")
        await first.disconnect()

        let second = try await StationDiscovery.attach(lockFile: lockFile, startHost: startHost)

        #expect(started.count == 1)
        #expect(await eventually {
            try await second.listDirectory().projects.first?.sessions.first?.state == "RUNNING"
        })
        try Data().write(to: fixture.scratch.path("release"))
        #expect(await eventually {
            try await second.listDirectory().projects.first?.sessions.first?.state == "NEEDS YOU"
        })
        #expect(exits.count == 0)
    }

    // A holder that serves no socket (a GUI from before hosts served one) is named, not
    // waited on for ever.
    @Test func aHolderWithNoEndpointIsNamed() async throws {
        let scratch = ScratchDirectory(prefix: "station-socket")
        let lockFile = scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.gui, at: lockFile).lock)
        defer { lock.release() }

        let refusal = await refusal {
            try await StationDiscovery.attach(lockFile: lockFile, startHost: {}, waitingUpTo: .milliseconds(200))
        }

        #expect(refusal?.message.contains(lock.holder.name) == true)
    }

    // A host that takes the connection but never answers the handshake (the GUI busy
    // handing over as it quits, its connect queued in the listen backlog). The client
    // says so within the handshake timeout, names the holder after the longer limit, and
    // attaches by itself once a real host takes over the lock.
    @Test func aHostThatNeverAnswersIsReportedAndTheClientAttachesToTheNext() async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let lockFile = fixture.scratch.path("station.lock")
        let stuck = try #require(StationLock.claim(.gui, at: lockFile).lock)
        // Listens, so a connect succeeds, but never accepts, so nothing is ever read.
        let silentPath = StationSocketPath.usable(fixture.scratch.path("silent.sock").path)
        let silent = try UnixSocket.listen(at: silentPath)
        defer { Darwin.close(silent) }
        stuck.advertise(silentPath)
        let patience = StationSocketClient.Patience(handshake: .milliseconds(200),
                                                    namingHolder: .milliseconds(800))

        let client = try await StationDiscovery.attach(lockFile: lockFile, startHost: {},
                                                       waitingUpTo: .seconds(5), patience: patience)
        defer { client.close() }
        let seen = LinkLog()
        let watcher = Task { @MainActor in
            for await link in client.linkUpdates() { seen.links.append(link) }
        }
        defer { watcher.cancel() }

        #expect(await waitUntil { seen.links.last == .notAnswering(holder: nil) }, "\(seen.links)")
        #expect(await refusal { try await client.listDirectory() } == .notAnswering)
        #expect(await waitUntil { seen.links.last == .notAnswering(holder: stuck.holder) }, "\(seen.links)")
        let named = try #require(seen.links.last?.message)
        #expect(named.contains("pid \(stuck.holder.pid)") && named.contains("kill \(stuck.holder.pid)"), "\(named)")

        // The stuck host lets go and a daemon takes the station on another socket.
        stuck.release()
        let lock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let daemon = try StationDaemon(station: StationCommands(store: fixture.store, runner: fixture.runner),
                                       lock: lock, socketPath: StationSocketPath.beside(lockFile),
                                       onExit: {})
        defer { daemon.shutdown() }

        #expect(await waitUntil { seen.links.last == .answering }, "\(seen.links)")
        #expect(await eventually { try await client.listDirectory().projects.isEmpty == false })
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
private final class TitleLog {
    var seen: [String] = []
}

@MainActor
private final class ExitLog {
    var count = 0
}

@MainActor
private final class LineLog {
    var seen: [String] = []
}

@MainActor
private final class LinkLog {
    var links: [StationLink] = []
}

// Holds whoever waits on it until the test opens it.
@MainActor
private final class Gate {
    private(set) var waiting = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        waiting = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiting = false
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
