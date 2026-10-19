import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): the station interface is the
// one door a front end other than the GUI uses into the core. Every answer is a plain
// Codable value in the phone remote's vocabulary, and every scenario runs once for each
// implementation of the interface, reading its answers the way a terminal would.
@MainActor
struct StationCommandsTests {

    // A store seeded on disk the way a previous run would have left it: two projects,
    // three sessions, written out and read back by a façade started on that index.
    @Test(arguments: StationImplementation.allCases)
    func listsEveryProjectWithItsSessionsNewestFirst(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-commands")
        let index = scratch.path("projects.json")
        do {
            let seed = ProjectStore(storeURL: index)
            let alpha = try project(named: "alpha", in: seed, under: scratch)
            let beta = try project(named: "beta", in: seed, under: scratch)
            let fixBug = try seed.insertSession(in: alpha.id, seed: .init(agent: .claudeCode)).get()
            seed.renameSession(fixBug.id, to: "Fix the login bug")
            reply(at: 1_000, in: fixBug.id, of: seed)
            let addTests = try seed.insertSession(in: alpha.id, seed: .init(agent: .codex)).get()
            seed.renameSession(addTests.id, to: "Add tests")
            reply(at: 2_000, in: addTests.id, of: seed)
            let docs = try seed.insertSession(in: beta.id, seed: .init(agent: .copilot)).get()
            seed.renameSession(docs.id, to: "Write the docs")
            reply(at: 3_000, in: docs.id, of: seed)
            #expect(seed.save())
        }

        let host = RecordingHost()
        let station = StationCommands.start(host: host, storeURL: index)
        let commands = kind.connect(to: station)
        let directory = try await commands.listDirectory()

        #expect(directory.projects.map(\.name) == ["beta", "alpha"])
        #expect(directory.projects.map { $0.sessions.map(\.title) }
                == [["Write the docs"], ["Add tests", "Fix the login bug"]])
        #expect(directory.projects.map { $0.sessions.map(\.agent) }
                == [["Copilot"], ["Codex", "Claude Code"]])
        #expect(directory.projects.flatMap(\.sessions).map(\.state) == ["IDLE", "IDLE", "IDLE"])
        #expect(directory.projects.flatMap(\.sessions).allSatisfy { $0.failure == nil })
        // Listing is a read: nothing is said to the person.
        #expect(host.events.isEmpty)
    }

    // The answer has to survive being written out and read back, since the façade may
    // later sit on the far side of a socket.
    @Test(arguments: StationImplementation.allCases)
    func theDirectoryRoundTripsThroughJSON(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-commands")
        let index = scratch.path("projects.json")
        do {
            let seed = ProjectStore(storeURL: index)
            let alpha = try project(named: "alpha", in: seed, under: scratch)
            let session = try seed.insertSession(in: alpha.id).get()
            seed.renameSession(session.id, to: "Only session")
            #expect(seed.save())
        }

        let directory = try await kind.connect(to: StationCommands.start(host: RecordingHost(), storeURL: index))
            .listDirectory()
        let data = try JSONEncoder().encode(directory)
        let decoded = try JSONDecoder().decode(RemoteDirectory.self, from: data)

        #expect(decoded == directory)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "directory")
    }

    // A list left open follows a turn: the row reads RUNNING while the fake agent works
    // and asks for the person once it has answered, at the moment the host hears the
    // turn end.
    @Test(arguments: StationImplementation.allCases)
    func anOpenListFollowsATurnAsItRunsAndEnds(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        wait_for "$folder/release"
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
        """, host: host)
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        let states = StateLog()
        let reader = Task { @MainActor in
            for await directory in commands.directoryUpdates() {
                states.seen.append(directory.projects.first?.sessions.first?.state ?? "")
            }
        }
        defer { reader.cancel() }

        #expect(await waitUntil { states.seen == ["IDLE"] })
        fixture.runner.send("hello", sessionID: fixture.session.id, store: fixture.store)
        #expect(await waitUntil { states.seen.last == "RUNNING" })
        #expect(host.endings.isEmpty)

        try Data().write(to: fixture.scratch.path("release"))

        #expect(await waitUntil { states.seen.last == "NEEDS YOU" })
        #expect(host.endings.map(\.sessionID) == [fixture.session.id])
        // Each list is only sent when it differs from the one before.
        #expect(states.seen == ["IDLE", "RUNNING", "NEEDS YOU"])
    }

    // A failed turn says why on its row, so a terminal can tell it from a finished one.
    @Test(arguments: StationImplementation.allCases)
    func aFailedTurnCarriesItsReasonOnTheRow(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        echo "the model is unavailable" >&2
        exit 3
        """, host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let commands = kind.connect(to: station)

        fixture.runner.send("hello", sessionID: fixture.session.id, store: fixture.store)

        #expect(await eventually {
            try await commands.listDirectory().projects.first?.sessions.first?.failure != nil
        })
        let row = try #require(try await commands.listDirectory().projects.first?.sessions.first)
        #expect(row.failure?.contains("the model is unavailable") == true)
        #expect(row.state == "NEEDS YOU")
    }

    // The tick that keeps a live list fresh does not leave a watcher behind each time it
    // runs, so a list left idle for many ticks rebuilds once for the next change, not once
    // for every tick that went by.
    @Test(arguments: StationImplementation.allCases)
    func anIdleListRebuildsOnceForTheNextChange(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(5))
        let commands = kind.connect(to: station)
        let titles = StateLog()
        let reader = Task { @MainActor in
            for await directory in commands.directoryUpdates() {
                titles.seen.append(directory.projects.first?.sessions.first?.title ?? "")
            }
        }
        defer { reader.cancel() }
        #expect(await waitUntil { titles.seen.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(station.changeRebuilds == 0)

        fixture.store.renameSession(fixture.session.id, to: "Renamed")

        #expect(await waitUntil { titles.seen.last == "Renamed" })
        try await Task.sleep(for: .milliseconds(100))
        #expect(station.changeRebuilds == 1)
    }

    // The same holds for an open session: idle ticks leave no watchers behind, so one
    // change rebuilds it once.
    @Test(arguments: StationImplementation.allCases)
    func anIdleOpenSessionRebuildsOnceForTheNextChange(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(5))
        let commands = kind.connect(to: station)
        let opened = try #require(try await commands.openSession(fixture.session.id.uuidString))
        let log = EventLog()
        let reader = Task { @MainActor in
            for await event in opened.events { log.events.append(event) }
        }
        defer { reader.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(station.changeRebuilds == 0)

        fixture.store.append(ChatMessage(role: .assistant, text: "Hello"), to: fixture.session.id)

        #expect(await waitUntil { !log.changes.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(station.changeRebuilds == 1)
        #expect(log.events.count == 1)
    }

    // MARK: - Open session

    // Opening a session hands back its whole history at once, in the phone's snapshot
    // shape.
    @Test(arguments: StationImplementation.allCases)
    func openingASessionHandsBackItsHistory(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.renameSession(fixture.session.id, to: "Fix the login bug")
        fixture.store.append(ChatMessage(role: .user, text: "Why does login fail?"), to: fixture.session.id)
        fixture.store.append(ChatMessage(role: .assistant, text: "The token expires early."),
                             to: fixture.session.id)
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let commands = kind.connect(to: station)

        let opened = try #require(try await commands.openSession(fixture.session.id.uuidString))

        #expect(opened.snapshot.sessionID == fixture.session.id.uuidString)
        #expect(opened.snapshot.header.title == "Fix the login bug")
        #expect(opened.snapshot.header.state == "IDLE")
        #expect(opened.snapshot.header.hasEarlierMessages == false)
        #expect(opened.snapshot.messages.map(\.role) == ["user", "assistant"])
        #expect(opened.snapshot.messages.map(\.text) == ["Why does login fail?", "The token expires early."])
        #expect(try await commands.openSession(UUID().uuidString) == nil)
        #expect(try await commands.openSession("not a session") == nil)
    }

    // A conversation brought in from an agent's own history is written to disk and not
    // held in memory, as a session from an earlier run is. Opening it reads it from there.
    @Test(arguments: StationImplementation.allCases)
    func openingAnImportedSessionReadsItsHistoryFromDisk(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let candidate = ExternalSessionCandidate(
            sessionID: "claude-imported", file: URL(fileURLWithPath: "/dev/null"),
            cwd: fixture.projectURL.path, title: "Imported", firstPrompt: "Why does login fail?",
            startedAt: Date(timeIntervalSince1970: 1_000), lastActivity: Date(timeIntervalSince1970: 2_000),
            gitBranch: "main", bytes: 10)
        let imported = try await fixture.store.importSession(
            ProjectStore.SessionImport(candidate: candidate, messages: [
                ChatMessage(role: .user, text: "Why does login fail?"),
                ChatMessage(role: .assistant, text: "The token expires early."),
            ]), into: fixture.session.projectID).get()
        #expect(!fixture.store.isTranscriptLoaded(imported.id))
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let commands = kind.connect(to: station)

        let opened = try #require(try await commands.openSession(imported.id.uuidString))

        #expect(opened.snapshot.messages.map(\.text) == ["Why does login fail?", "The token expires early."])
    }

    // A turn streams into an open session as changes: the prompt and the answer arrive
    // whole, then the answer grows by patches (a tool finishing, more text), and the
    // changes laid over the snapshot rebuild exactly what a fresh snapshot shows.
    @Test(arguments: StationImplementation.allCases)
    func anOpenSessionStreamsATurnAsFullAndPatchChanges(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the file."}]}}'
        wait_for "$folder/more"
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Still reading."}]}}'
        wait_for "$folder/tool"
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/Package.swift"}}]}}'
        wait_for "$folder/result"
        printf '%s\\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
        wait_for "$folder/answer"
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"It builds."}]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"It builds."}'
        """, host: host)
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        let opened = try #require(try await commands.openSession(fixture.session.id.uuidString))
        await commands.show(fixture.session.id.uuidString)
        #expect(opened.snapshot.messages.isEmpty)
        let log = EventLog()
        log.mirror = RemoteTranscript(opened.snapshot)
        let reader = Task { @MainActor in
            for await event in opened.events {
                log.events.append(event)
                log.mirror?.apply(event)
            }
        }
        defer { reader.cancel() }

        fixture.runner.send("Does it build?", sessionID: fixture.session.id, store: fixture.store)
        #expect(await waitUntil {
            log.mirror?.messages.map(\.text) == ["Does it build?", "Reading the file."]
        })
        #expect(log.mirror?.header.state == "RUNNING")
        #expect(log.changes.allSatisfy { $0.kind == "full" })
        #expect(Set(log.changes.compactMap(\.role)) == ["user", "assistant"])
        let answerID = try #require(log.mirror?.messages.last?.id)

        // More text in the same prose block grows it by a patch.
        log.events.removeAll()
        try Data().write(to: fixture.scratch.path("more"))
        #expect(await waitUntil { log.mirror?.messages.last?.text.hasSuffix("Still reading.") == true })
        #expect(log.changes.map(\.kind) == ["patch"])
        #expect(log.changes.first?.id == answerID)
        #expect(log.changes.first?.textAppend?.hasSuffix("Still reading.") == true)

        // A new tool reshapes the message, so it goes whole.
        log.events.removeAll()
        try Data().write(to: fixture.scratch.path("tool"))
        #expect(await waitUntil { log.mirror?.messages.last?.tools.map(\.name) == ["Read"] })
        #expect(log.changes.map(\.kind) == ["full"])
        #expect(log.mirror?.messages.last?.tools.first?.isRunning == true)

        // The tool finishing patches only that tool.
        log.events.removeAll()
        try Data().write(to: fixture.scratch.path("result"))
        #expect(await waitUntil { log.mirror?.messages.last?.tools.first?.result == "ok" })
        let toolChange = try #require(log.changes.last { $0.tools != nil })
        #expect(toolChange.kind == "patch")
        #expect(toolChange.id == answerID)
        #expect(toolChange.textAppend == nil)
        #expect(toolChange.tools?.map(\.name) == ["Read"])

        try Data().write(to: fixture.scratch.path("answer"))
        #expect(await waitUntil { log.mirror?.header.isBusy == false })
        // A session a client shows is being read, as one on a phone is, so the turn
        // ending leaves it IDLE rather than asking for the person. The host still hears
        // it end.
        #expect(log.mirror?.header.state == "IDLE")
        #expect(log.mirror?.messages.last?.text.hasSuffix("It builds.") == true)
        #expect(host.endings.map(\.sessionID) == [fixture.session.id])

        let fresh = try #require(try await commands.openSession(fixture.session.id.uuidString))
        #expect(log.mirror?.messages == fresh.snapshot.messages)
        #expect(log.mirror?.header == fresh.snapshot.header)
    }

    // Resync sends a fresh snapshot down the same stream, in order with the changes, and
    // closing the session ends the stream.
    @Test(arguments: StationImplementation.allCases)
    func resyncSendsAFreshSnapshotAndClosingEndsTheStream(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        fixture.store.append(ChatMessage(role: .assistant, text: "Hello"), to: fixture.session.id)
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        let id = fixture.session.id.uuidString
        let opened = try #require(try await commands.openSession(id))
        let log = EventLog()
        let reader = Task { @MainActor in
            for await event in opened.events { log.events.append(event) }
            log.ended = true
        }
        defer { reader.cancel() }

        await commands.resync(id)
        #expect(await waitUntil { !log.events.isEmpty })
        guard case .snapshot(let snapshot) = log.events.first else {
            Issue.record("expected a snapshot, got \(log.events)")
            return
        }
        #expect(snapshot.messages.map(\.text) == ["Hello"])

        await commands.closeSession(id)
        #expect(await waitUntil { log.ended })
    }

    // Every event survives being written out and read back, the way a socket would
    // carry it.
    @Test(arguments: StationImplementation.allCases)
    func sessionEventsRoundTripThroughJSON(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let call = ToolUse(id: "t1", name: "Bash", input: #"{"command":"swift build"}"#, result: nil)
        fixture.store.append(ChatMessage(role: .assistant, text: "Done", tools: [call]),
                             to: fixture.session.id)
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let commands = kind.connect(to: station)
        let snapshot = try #require(try await commands.openSession(fixture.session.id.uuidString)).snapshot
        let message = try #require(snapshot.messages.first)
        let events: [StationSessionEvent] = [
            .snapshot(snapshot),
            .update(RemoteUpdate(header: snapshot.header, order: snapshot.messages.map(\.id),
                                 changed: [.full(message),
                                           .patch(id: message.id, textAppend: "!", tools: message.tools)],
                                 permissionCleared: true)),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(events)
        let decoded = try decoder.decode([StationSessionEvent].self, from: data)

        #expect(decoded == events)
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.map { $0["type"] as? String } == ["snapshot", "update"])
    }

    // MARK: - Send prompt and stop turn

    // A prompt sent through the façade reaches the agent and its reply streams into the
    // open session. The host hears the turn end at the moment it does in the GUI: the
    // sound, then the ending, once the reply is in.
    @Test(arguments: StationImplementation.allCases)
    func aSentPromptReachesTheAgentAndItsReplyStreamsIn(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        case "$input" in *"Does it build?"*) ;; *) exit 9 ;; esac
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Checking."}]}}'
        wait_for "$folder/answer"
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"It builds."}]}}'
        """, host: host)
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        let id = fixture.session.id.uuidString
        let opened = try #require(try await commands.openSession(id))
        let log = EventLog()
        log.mirror = RemoteTranscript(opened.snapshot)
        let reader = Task { @MainActor in
            for await event in opened.events { log.mirror?.apply(event) }
        }
        defer { reader.cancel() }

        try await commands.sendPrompt(id, prompt: "  Does it build?\n")

        #expect(await waitUntil {
            log.mirror?.messages.map(\.text) == ["Does it build?", "Checking."]
        })
        #expect(log.mirror?.header.isBusy == true)
        #expect(host.events.isEmpty)

        try Data().write(to: fixture.scratch.path("answer"))

        #expect(await waitUntil { log.mirror?.header.isBusy == false })
        #expect(log.mirror?.messages.last?.text.hasSuffix("It builds.") == true)
        #expect(host.events == [.sound, .turnEnded(fixture.session.id, failure: nil)])
    }

    // A prompt sent while a turn runs waits in the runner's queue, and the open session
    // shows it there. It runs once the turn is over, and the host hears the session end
    // only once, after the queue has drained, as the GUI does.
    @Test(arguments: StationImplementation.allCases)
    func aPromptSentDuringATurnIsQueuedAndRunsAfterIt(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        case "$input" in
          *"First"*)
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"On the first."}]}}'
            wait_for "$folder/first" ;;
          *"Second"*)
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"On the second."}]}}'
            wait_for "$folder/second" ;;
        esac
        """, host: host)
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        let id = fixture.session.id.uuidString
        let opened = try #require(try await commands.openSession(id))
        let log = EventLog()
        log.mirror = RemoteTranscript(opened.snapshot)
        let reader = Task { @MainActor in
            for await event in opened.events { log.mirror?.apply(event) }
        }
        defer { reader.cancel() }

        try await commands.sendPrompt(id, prompt: "First")
        #expect(await waitUntil { log.mirror?.messages.last?.text == "On the first." })

        try await commands.sendPrompt(id, prompt: "Second")
        #expect(await waitUntil { log.mirror?.queued.map(\.text) == ["Second"] })
        #expect(log.mirror?.messages.map(\.text) == ["First", "On the first."])

        try Data().write(to: fixture.scratch.path("first"))
        #expect(await waitUntil { log.mirror?.messages.last?.text == "On the second." })
        #expect(log.mirror?.queued.isEmpty == true)
        #expect(log.mirror?.header.isBusy == true)
        #expect(host.endings.isEmpty)

        try Data().write(to: fixture.scratch.path("second"))
        #expect(await waitUntil { log.mirror?.header.isBusy == false })
        #expect(log.mirror?.messages.map(\.text)
                == ["First", "On the first.", "Second", "On the second."])
        #expect(host.events == [.sound, .turnEnded(fixture.session.id, failure: nil)])
    }

    // Stopping ends the running turn and the session says it was stopped. What streamed
    // in stays, a prompt queued behind the turn waits to be sent by hand, as it does in
    // the GUI, and a stop is the person's own doing, so the host hears nothing.
    @Test(arguments: StationImplementation.allCases)
    func stoppingATurnEndsItAndLeavesTheQueueWaiting(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it."}]}}'
        while :; do sleep 0.1; done
        """, host: host)
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner,
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)
        let id = fixture.session.id.uuidString
        let opened = try #require(try await commands.openSession(id))
        await commands.show(id)
        let log = EventLog()
        log.mirror = RemoteTranscript(opened.snapshot)
        let reader = Task { @MainActor in
            for await event in opened.events { log.mirror?.apply(event) }
        }
        defer { reader.cancel() }

        try await commands.sendPrompt(id, prompt: "Refactor it")
        #expect(await waitUntil { log.mirror?.messages.last?.text == "Working on it." })
        try await commands.sendPrompt(id, prompt: "Then test it")
        #expect(await waitUntil { log.mirror?.queued.map(\.text) == ["Then test it"] })

        try await commands.stopTurn(id)

        #expect(await waitUntil { log.mirror?.header.isBusy == false })
        #expect(log.mirror?.header.state == "IDLE")
        #expect(log.mirror?.messages.map(\.text) == [
            "Refactor it", "Working on it.", "Stopped. The turn ended before it finished.",
        ])
        #expect(log.mirror?.queued.map(\.text) == ["Then test it"])
        #expect(host.events.isEmpty)
    }

    // A command the façade cannot carry out says why, in words a front end shows as they
    // are, and the refusal survives a trip through JSON.
    @Test(arguments: StationImplementation.allCases)
    func sendingAndStoppingRefuseWhatTheyCannotDo(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let commands = kind.connect(to: station)
        let id = fixture.session.id.uuidString

        await #expect(throws: StationRefusal("Write a prompt first.")) {
            try await commands.sendPrompt(id, prompt: " \n ")
        }
        await #expect(throws: StationRefusal("That prompt is too long.")) {
            try await commands.sendPrompt(id, prompt: String(repeating: "a", count: 100_001))
        }
        await #expect(throws: StationRefusal("That session is no longer available.")) {
            try await commands.sendPrompt(UUID().uuidString, prompt: "hello")
        }
        await #expect(throws: StationRefusal("That session is no longer available.")) {
            try await commands.stopTurn("not a session")
        }
        // Stopping a session with nothing running leaves it as it is.
        try await commands.stopTurn(id)
        #expect(fixture.store.session(fixture.session.id)?.messages.isEmpty == true)

        let refusal = StationRefusal("Write a prompt first.")
        let decoded = try JSONDecoder().decode(StationRefusal.self,
                                               from: JSONEncoder().encode(refusal))
        #expect(decoded == refusal)
    }

    // The arrows in an empty composer walk back through the prompts the session sent,
    // newest first, through the core's composer store, as they do in the GUI. Text being
    // written keeps the arrows for itself, and walking forward past the newest prompt
    // empties the composer again.
    @Test(arguments: StationImplementation.allCases)
    func earlierPromptsAreRecalledNewestFirst(_ kind: StationImplementation) async throws {
        let fixture = try RunnerHarness(agent: .claudeCode, script: "exit 0", host: RecordingHost())
        defer { fixture.tearDown() }
        for text in ["First question", "Second question", "Second question", "Third question"] {
            fixture.store.append(ChatMessage(role: .user, text: text), to: fixture.session.id)
            fixture.store.append(ChatMessage(role: .assistant, text: "Answer"), to: fixture.session.id)
        }
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let commands = kind.connect(to: station)
        let id = fixture.session.id.uuidString

        #expect(try await commands.recallPrompt(id, .earlier, draft: "half written") == nil)
        #expect(try await commands.recallPrompt(id, .later, draft: "") == nil)

        #expect(try await commands.recallPrompt(id, .earlier, draft: "") == "Third question")
        #expect(try await commands.recallPrompt(id, .earlier, draft: "Third question") == "Second question")
        #expect(try await commands.recallPrompt(id, .earlier, draft: "Second question") == "First question")
        #expect(try await commands.recallPrompt(id, .earlier, draft: "First question") == nil)
        #expect(try await commands.recallPrompt(id, .later, draft: "First question") == "Second question")
        // An edit to a recalled prompt ends the walk: the arrows belong to the text again.
        #expect(try await commands.recallPrompt(id, .later, draft: "Second question, edited") == nil)

        #expect(try await commands.recallPrompt(id, .earlier, draft: "") == "Third question")
        #expect(try await commands.recallPrompt(id, .later, draft: "Third question") == "")
        #expect(try await commands.recallPrompt(UUID().uuidString, .earlier, draft: "") == nil)
    }

    // A session the GUI started, with an agent conversation behind it, carries on from
    // the terminal: the next prompt resumes that conversation rather than starting anew.
    @Test(arguments: StationImplementation.allCases)
    func aSessionStartedInTheGUIIsResumedFromTheTerminal(_ kind: StationImplementation) async throws {
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        printf '%s\\n' "$@" > "$folder/arguments"
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-gui"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Carrying on."}]}}'
        """, host: host)
        defer { fixture.tearDown() }
        let id = fixture.session.id
        fixture.store.append(ChatMessage(role: .user, text: "Started in the app"), to: id)
        fixture.store.append(ChatMessage(role: .assistant, text: "Hello from the app"), to: id)
        fixture.store.setAgentSessionID("claude-gui", agent: .claudeCode, for: id)
        #expect(fixture.store.save())

        let reopened = ProjectStore(storeURL: fixture.scratch.path("projects.json"))
        let station = StationCommands(store: reopened, runner: fixture.runner)
        let commands = kind.connect(to: station)
        try await commands.sendPrompt(id.uuidString, prompt: "And from the terminal")

        #expect(await waitUntil { host.endings.count == 1 })
        let arguments = try String(contentsOf: fixture.scratch.path("arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let resume = try #require(arguments.firstIndex(of: "--resume"))
        #expect(arguments[resume + 1] == "claude-gui")
        #expect(reopened.transcript(of: id).map(\.text) == [
            "Started in the app", "Hello from the app", "And from the terminal", "Carrying on.",
        ])
    }

    // A session limited to some MCP servers, as a troubleshooting session from the GUI
    // is, runs from the terminal too: the agent is handed only the allowed servers from
    // the shared MCP config, without the app's own environment tags.
    @Test(arguments: StationImplementation.allCases)
    func aSessionLimitedToSomeMCPServersRunsWithOnlyThose(_ kind: StationImplementation) async throws {
        let settings = ScratchDirectory(prefix: "station-mcp")
        let config = settings.path("config.json")
        try Data("""
        {"mcpServers": {
          "grafana-dev": {"command": "grafana-mcp", "args": ["--dev"], "environment": "dev"},
          "grafana-prd": {"command": "grafana-mcp", "args": ["--prd"], "environment": "prd"},
          "notes": {"url": "https://example.com/mcp", "type": "http"}
        }}
        """.utf8).write(to: config)
        let host = RecordingHost()
        let fixture = try RunnerHarness(agent: .claudeCode, script: """
        while [ "$#" -gt 0 ]; do
          [ "$1" = "--mcp-config" ] && cp "$2" "$folder/handed.json"
          shift
        done
        IFS= read -r input
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-1"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}'
        """, mcpConfiguration: StationCommands.mcpConfiguration(at: config), host: host)
        defer { fixture.tearDown() }
        fixture.store.setSettings(SessionSettings(mcpServersEnabled: true,
                                                  allowedMCPServerNames: ["grafana-dev", "notes"]),
                                  for: fixture.session.id)
        let station = StationCommands(store: fixture.store, runner: fixture.runner)
        let commands = kind.connect(to: station)

        try await commands.sendPrompt(fixture.session.id.uuidString, prompt: "Check the dashboards")

        #expect(await waitUntil { host.endings.count == 1 })
        #expect(host.endings.first?.failure == nil)
        let handed = try Data(contentsOf: fixture.scratch.path("handed.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: handed) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: [String: Any]])
        #expect(Set(servers.keys) == ["grafana-dev", "notes"])
        #expect(servers["grafana-dev"]?["command"] as? String == "grafana-mcp")
        #expect(servers["grafana-dev"]?["args"] as? [String] == ["--dev"])
        #expect(servers["grafana-dev"]?["environment"] == nil)
        #expect(servers["notes"]?["url"] as? String == "https://example.com/mcp")
    }

    // A session's activity is the time of its last message, so a reply at a known moment
    // fixes where it sorts.
    private func reply(at seconds: TimeInterval, in sessionID: UUID, of store: ProjectStore) {
        store.append(ChatMessage(role: .assistant, text: "Done",
                                 date: Date(timeIntervalSince1970: seconds)), to: sessionID)
    }

    private func project(named name: String, in store: ProjectStore,
                         under scratch: ScratchDirectory) throws -> Project {
        let folder = scratch.path(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(store.addProject(at: folder))
    }
}

@MainActor
private final class StateLog {
    var seen: [String] = []
}
