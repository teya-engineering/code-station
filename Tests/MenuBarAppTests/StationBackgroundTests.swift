import Foundation
import Testing
@testable import CodeStationCore

// Part of the station contract (see StationContract.swift): the work a host keeps doing
// with nobody asking, the same in the GUI and the daemon. Schedules start their runs,
// the old-session sweep and the orphaned-worktree monitor keep the station tidy, and a
// deletion an earlier run left half done is finished. A client sees the results through
// the station interface alone; the clock is the test's, so an hour passes at once.
@MainActor
struct StationBackgroundTests {

    // A task whose timer comes round while only a host with no window is up: the run
    // starts on its own, shows in the directory, and the timer counts it.
    @Test(arguments: StationImplementation.allCases)
    func aDueScheduleStartsARunWithNoGUI(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-background")
        let storeURL = scratch.path("projects.json")
        let store = ProjectStore(storeURL: storeURL)
        let start = Date()
        let task = try scheduledTask(in: store, under: scratch, at: start)
        let station = StationCommands(store: store, runner: StationNewSessionTests.runner())
        let clock = TestClock(start)
        let upkeep = StationUpkeep(station: station, preferences: Self.preferences(),
                                   now: { clock.now }, pace: .test)
        upkeep.start()
        defer { upkeep.stop() }
        let commands = kind.connect(to: station)

        try await Task.sleep(for: .milliseconds(100))
        #expect(try await runs(of: task, in: commands).isEmpty)

        clock.now = start.addingTimeInterval(61)

        #expect(await eventually { try await runs(of: task, in: commands).count == 1 })
        let saved = try #require(ProjectStore(storeURL: storeURL).project(task.id)?.task?.schedule)
        #expect(saved.completedRuns == 1)
    }

    // A timer that asks first does not start its run: the task shows as waiting in the
    // directory, for any front end to answer. Confirming through the station starts the
    // run and the task stops waiting.
    @Test(arguments: StationImplementation.allCases)
    func aRunNeedingConfirmationWaitsUntilAClientConfirmsIt(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-background")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let start = Date()
        let task = try scheduledTask(in: store, under: scratch, at: start, requiresConfirmation: true)
        let station = StationCommands(store: store, runner: StationNewSessionTests.runner())
        let clock = TestClock(start)
        let upkeep = StationUpkeep(station: station, preferences: Self.preferences(),
                                   now: { clock.now }, pace: .test)
        upkeep.start()
        defer { upkeep.stop() }
        let commands = kind.connect(to: station)

        #expect(try await schedule(of: task, in: commands)?.isWaiting == false)
        clock.now = start.addingTimeInterval(61)

        #expect(await eventually { try await schedule(of: task, in: commands)?.isWaiting == true })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await runs(of: task, in: commands).isEmpty)

        // The answer is given at the real time, which the host's clock is put back to, so
        // the next occurrence is not already due.
        clock.now = start
        let started = try await commands.confirmScheduledRun(task.id.uuidString, .run)

        let rows = try await runs(of: task, in: commands)
        #expect(rows.map(\.id) == [try #require(started)])
        #expect(try await schedule(of: task, in: commands)?.isWaiting == false)
    }

    // Skipping lets this occurrence pass and turning the timer off stops it; neither
    // starts a run. A task that is not waiting cannot be confirmed.
    @Test(arguments: StationImplementation.allCases)
    func aWaitingRunCanBeSkippedOrItsTimerTurnedOff(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-background")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let start = Date()
        let skipped = try scheduledTask(in: store, under: scratch, at: start, requiresConfirmation: true)
        let stopped = try scheduledTask(in: store, under: scratch, at: start, requiresConfirmation: true)
        let station = StationCommands(store: store, runner: StationNewSessionTests.runner())
        let clock = TestClock(start.addingTimeInterval(61))
        let upkeep = StationUpkeep(station: station, preferences: Self.preferences(),
                                   now: { clock.now }, pace: .test)
        let commands = kind.connect(to: station)
        // Nothing waits until the host has looked at the timers.
        await #expect(throws: StationRefusal.self) {
            try await commands.confirmScheduledRun(skipped.id.uuidString, .run)
        }
        upkeep.start()
        defer { upkeep.stop() }
        #expect(await eventually {
            let first = try await schedule(of: skipped, in: commands)
            let second = try await schedule(of: stopped, in: commands)
            return first?.isWaiting == true && second?.isWaiting == true
        })

        clock.now = start
        #expect(try await commands.confirmScheduledRun(skipped.id.uuidString, .skip) == nil)
        #expect(try await commands.confirmScheduledRun(stopped.id.uuidString, .turnOff) == nil)

        let afterSkip = try #require(try await schedule(of: skipped, in: commands))
        #expect(!afterSkip.isWaiting)
        #expect(afterSkip.isActive)
        let afterTurnOff = try #require(try await schedule(of: stopped, in: commands))
        #expect(!afterTurnOff.isActive)
        #expect(try await runs(of: skipped, in: commands).isEmpty)
        #expect(try await runs(of: stopped, in: commands).isEmpty)
        await #expect(throws: StationRefusal.self) {
            try await commands.confirmScheduledRun(UUID().uuidString, .run)
        }
    }

    // MARK: - Cleanup

    // Under a policy that deletes old sessions, a session untouched for longer than the
    // set number of days goes once its warning hour has passed, with no window open to
    // run the sweep. A recent one stays.
    @Test(arguments: StationImplementation.allCases)
    func theOldSessionSweepRunsWithNoGUI(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-background")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: try folder("project", in: scratch)))
        let old = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "Old work",
                                 date: Date().addingTimeInterval(-8 * 86_400)), to: old.id)
        let recent = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "New work", date: Date()), to: recent.id)
        let preferences = Self.preferences()
        Preferences.setOldSessionCleanupPolicy(.deleteAll, in: preferences)
        Preferences.setOldSessionDays(7, in: preferences)
        let station = StationCommands(store: store, runner: StationNewSessionTests.runner())
        let clock = TestClock(Date())
        let upkeep = StationUpkeep(station: station, preferences: preferences,
                                   now: { clock.now }, pace: .test)
        upkeep.start()
        defer { upkeep.stop() }
        let commands = kind.connect(to: station)

        // Each look moves the host's clock on by the warning hour.
        #expect(await eventually {
            clock.now = clock.now.addingTimeInterval(OldSessionSweep.gracePeriod)
            return try await sessions(of: project, in: commands) == [recent.id.uuidString]
        })
    }

    // A deletion an earlier run was stopped part way through is finished when a host
    // with no window starts: the checkout it left goes, and the deletion is no longer
    // pending on disk.
    @Test(arguments: StationImplementation.allCases)
    func aPendingDeletionIsFinishedWithNoGUI(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-background")
        let storeURL = scratch.path("projects.json")
        do {
            let seed = ProjectStore(storeURL: storeURL)
            let project = try #require(seed.addProject(at: try folder("project", in: scratch)))
            let session = seed.newSession(in: project.id, worktreePath: "/worktrees/left-behind",
                                          worktreeBranch: "code-station/left")
            _ = await SessionLifecycle.remove(session, from: seed, runner: SessionRunner(),
                                              worktrees: Self.removals { _ in false })
            #expect(seed.pendingSessionRemovals.count == 1)
            #expect(seed.save())
        }
        let removed = RemovedPaths()
        let station = StationCommands(store: ProjectStore(storeURL: storeURL),
                                      runner: StationNewSessionTests.runner())
        station.worktrees = Self.removals { removed.paths.append($0); return true }
        let upkeep = StationUpkeep(station: station, preferences: Self.preferences(), pace: .test)
        upkeep.start()
        defer { upkeep.stop() }
        let commands = kind.connect(to: station)

        #expect(await waitUntil { removed.paths == ["/worktrees/left-behind"] })
        #expect(await waitUntil { ProjectStore(storeURL: storeURL).pendingSessionRemovals.isEmpty })
        #expect(try await commands.listDirectory().projects.flatMap(\.sessions).isEmpty)
        #expect(upkeep.sessionCleanupError == nil)
    }

    // With automatic pruning on, a checkout the app made that no session owns is found
    // and removed an hour after it was first seen, with no window open.
    @Test(arguments: StationImplementation.allCases)
    func orphanedWorktreesArePrunedWithNoGUI(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-background")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: try folder("project", in: scratch)))
        let disk = OrphanDisk()
        let monitor = OrphanedWorktreeMonitor(
            discover: { _, _ in
                disk.present ? [GitWorktree.Orphaned(path: "/worktrees/stray", branch: "code-station/stray",
                                                     allocatedBytes: 1_024)] : []
            },
            remove: { @MainActor orphan in
                disk.removed.append(orphan.path)
                disk.present = false
                return .success(())
            })
        let preferences = Self.preferences()
        Preferences.setAutoPruneOrphanedWorktrees(true, in: preferences)
        let station = StationCommands(store: store, runner: StationNewSessionTests.runner())
        let clock = TestClock(Date())
        let upkeep = StationUpkeep(station: station, orphanedWorktrees: monitor,
                                   preferences: preferences, now: { clock.now }, pace: .test)
        upkeep.start()
        defer { upkeep.stop() }
        _ = kind.connect(to: station)

        #expect(await waitUntil { monitor.worktrees.map(\.path) == ["/worktrees/stray"] })
        #expect(disk.removed.isEmpty)
        #expect(monitor.worktrees.first?.projectID == project.id)

        clock.now = clock.now.addingTimeInterval(OrphanedWorktreeSweep.discoveryInterval)

        #expect(await waitUntil { disk.removed == ["/worktrees/stray"] })
        #expect(await waitUntil { monitor.worktrees.isEmpty })
        #expect(upkeep.orphanCleanupError == nil)
    }

    // MARK: - The daemon

    // The daemon keeps the upkeep going for as long as it serves, and stops it before
    // its quit sweep, so nothing starts a run while the station is being put away.
    @Test func theDaemonRunsTheUpkeepUntilItShutsDown() throws {
        let scratch = ScratchDirectory(prefix: "station-background")
        let station = StationCommands(store: ProjectStore(storeURL: scratch.path("projects.json")),
                                      runner: StationNewSessionTests.runner())
        let lockFile = scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.daemon, at: lockFile).lock)
        let upkeep = StationUpkeep(station: station, preferences: Self.preferences(), pace: .test)
        let daemon = try StationDaemon(station: station, upkeep: upkeep, lock: lock,
                                       socketPath: StationSocketPath.beside(lockFile), onExit: {})
        #expect(upkeep.isRunning)

        daemon.shutdown()

        #expect(!upkeep.isRunning)
    }

    // MARK: - Helpers

    private func folder(_ name: String, in scratch: ScratchDirectory) throws -> URL {
        let url = scratch.path(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sessions(of project: Project, in commands: any StationInterface) async throws -> [String] {
        try await commands.listDirectory().projects.first { $0.id == project.id.uuidString }?
            .sessions.map(\.id) ?? []
    }

    // Worktree removal that succeeds or fails as `remove` says, and never adds anything.
    static func removals(_ remove: @escaping @MainActor (String) -> Bool) -> WorktreeOperations {
        WorktreeOperations(
            addProject: { _, _, _, _ in .failure(GitWorktree.Failure(message: "Unexpected add")) },
            addWorkspaceProject: { _, _, _, _, _ in .failure(GitWorktree.Failure(message: "Unexpected add")) },
            remove: { path, _, _ in
                await remove(path) ? .success(()) : .failure(GitWorktree.Failure(message: "Checkout is in use"))
            })
    }

    private func schedule(of task: Project, in commands: any StationInterface) async throws -> RemoteSchedule? {
        try await commands.listDirectory().projects.first { $0.id == task.id.uuidString }?.schedule
    }


    // A task that runs every minute from `date`, so its first run is due a minute later.
    private func scheduledTask(in store: ProjectStore, under scratch: ScratchDirectory,
                               at date: Date, requiresConfirmation: Bool = false) throws -> Project {
        let task = try store.addTask(named: "Nightly", prompt: "Check the build.",
                                     in: scratch.path("tasks")).get()
        var schedule = TaskSchedule()
        schedule.isEnabled = true
        schedule.interval = 1
        schedule.intervalUnit = .minutes
        schedule.requiresConfirmation = requiresConfirmation
        schedule.restart(at: date)
        var spec = try #require(task.task)
        spec.schedule = schedule
        store.setTaskSpec(spec, for: task.id)
        return try #require(store.project(task.id))
    }

    private func runs(of task: Project, in commands: any StationInterface) async throws -> [RemoteSessionRow] {
        try await commands.listDirectory().projects.first { $0.id == task.id.uuidString }?.sessions ?? []
    }

    // Preferences of the test's own, so the host follows what the scenario sets and not
    // whatever the test process's defaults hold.
    static func preferences() -> UserDefaults {
        UserDefaults(suiteName: "station-background-\(UUID().uuidString)")!
    }
}

// The time as the scenario says it is.
@MainActor
final class TestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

extension StationUpkeep.Pace {
    // Every loop wakes often, so a scenario sees the host act within a few milliseconds
    // of its clock moving.
    static let test = StationUpkeep.Pace(schedules: .milliseconds(10), sweep: .milliseconds(10),
                                         orphans: .milliseconds(10))
}

// The checkouts a fake worktree removal was asked to remove.
@MainActor
final class RemovedPaths {
    var paths: [String] = []
}

// One orphaned checkout as git would report it, until it is removed.
@MainActor
final class OrphanDisk {
    var present = true
    var removed: [String] = []
}
