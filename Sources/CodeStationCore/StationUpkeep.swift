import Foundation
import Observation

// The work a station host keeps doing while nobody asks for anything: schedules start
// their runs, old sessions are swept, orphaned worktrees are found and pruned, and a
// deletion an earlier run left half done is finished. Every host starts it at launch,
// the GUI from its app delegate and the daemon from its main, so the station behaves the
// same whichever one is up.
//
// Each loop reads the station preferences on every pass, so a setting changed in any
// front end takes effect within a pass. What a front end shows about the work (a
// countdown, a failure) is published here; a scheduled run waiting for confirmation is
// kept in its task's schedule, where every front end can see and answer it.
@MainActor
@Observable
public final class StationUpkeep {
    // How often each loop wakes. The clock the loops read is separate, so a test can let
    // an hour pass at once.
    public struct Pace: Sendable {
        public var schedules: Duration
        public var sweep: Duration
        public var orphans: Duration

        public init(schedules: Duration, sweep: Duration, orphans: Duration) {
            self.schedules = schedules
            self.sweep = sweep
            self.orphans = orphans
        }

        // The schedule loop is coarse because the smallest unit a timer is set in is a
        // minute.
        public static let standard = Pace(schedules: .seconds(2),
                                          sweep: OldSessionSweep.monitorInterval,
                                          orphans: OrphanedWorktreeSweep.monitorInterval)
    }

    public let orphanedWorktrees: OrphanedWorktreeMonitor
    // When the old-session sweep will next delete, and how many sessions it will take.
    public private(set) var oldSessionDeletion: OldSessionSweep.Deletion?
    // Why the last attempt to finish deleting sessions an earlier run left pending failed.
    public private(set) var sessionCleanupError: String?
    // Why the last automatic prune of orphaned worktrees failed.
    public private(set) var orphanCleanupError: String?
    // The last scheduled run that could not start.
    public private(set) var scheduleFailure: ScheduledRunFailure?

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let runner: SessionRunner
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let pace: Pace
    @ObservationIgnored private let worktrees: WorktreeOperations
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    public init(store: ProjectStore, runner: SessionRunner,
                orphanedWorktrees: OrphanedWorktreeMonitor = OrphanedWorktreeMonitor(),
                preferences: UserDefaults = Preferences.defaults,
                now: @escaping @MainActor () -> Date = { Date() },
                pace: Pace = .standard,
                worktrees: WorktreeOperations = .live) {
        self.store = store
        self.runner = runner
        self.orphanedWorktrees = orphanedWorktrees
        self.preferences = preferences
        self.now = now
        self.pace = pace
        self.worktrees = worktrees
    }

    // The upkeep of a host serving `station`, on the same store, runner and worktrees.
    public convenience init(station: StationCommands,
                            orphanedWorktrees: OrphanedWorktreeMonitor = OrphanedWorktreeMonitor(),
                            preferences: UserDefaults = Preferences.defaults,
                            now: @escaping @MainActor () -> Date = { Date() },
                            pace: Pace = .standard) {
        self.init(store: station.store, runner: station.runner,
                  orphanedWorktrees: orphanedWorktrees, preferences: preferences,
                  now: now, pace: pace, worktrees: station.worktrees)
        station.upkeep = self
    }

    public var isRunning: Bool { !loops.isEmpty }

    public func start() {
        guard loops.isEmpty else { return }
        loops = [
            Task { [weak self] in await self?.resumePendingRemovals() },
            Task { [weak self] in await self?.keepSchedules() },
            Task { [weak self] in await self?.sweepOldSessions() },
            Task { [weak self] in await self?.watchOrphanedWorktrees() },
        ]
    }

    public func stop() {
        for loop in loops { loop.cancel() }
        loops = []
    }

    // MARK: - Pending removals

    // A deletion the app was stopped part way through is saved, and finished here.
    private func resumePendingRemovals() async {
        let failures = await SessionLifecycle.resumePendingRemovals(in: store, worktrees: worktrees)
        sessionCleanupError = failures.isEmpty ? nil : failures.map(\.message).joined(separator: "\n")
    }

    // MARK: - Schedules

    private func keepSchedules() async {
        while !Task.isCancelled {
            let failures = ScheduledTaskExecution.tick(
                at: now(), store: store, runner: runner,
                agentAvatarName: Preferences.defaultAgentAvatarName(in: preferences))
            if let last = failures.last { scheduleFailure = last }
            guard (try? await Task.sleep(for: pace.schedules)) != nil else { return }
        }
    }

    // MARK: - Old sessions

    private struct SweepRule: Equatable {
        let policy: OldSessionCleanupPolicy
        let days: Int
    }

    // Age is the only thing that makes a session sweepable, and age only moves with the
    // clock, so this runs on a timer rather than off a change in the store. A change of
    // rule starts the countdown again.
    private func sweepOldSessions() async {
        var rule: SweepRule?
        var buffer = OldSessionSweep.EligibilityBuffer()
        while !Task.isCancelled {
            let current = SweepRule(policy: Preferences.oldSessionCleanupPolicy(in: preferences),
                                    days: Preferences.oldSessionDays(in: preferences))
            if current != rule {
                rule = current
                buffer = OldSessionSweep.EligibilityBuffer()
                if oldSessionDeletion != nil { oldSessionDeletion = nil }
            }
            if current.policy.deletesAutomatically {
                await OldSessionSweep.run(days: current.days, policy: current.policy, store: store,
                                          runner: runner, buffer: &buffer, now: now(),
                                          worktreeOperations: worktrees)
                guard !Task.isCancelled else { return }
                if oldSessionDeletion != buffer.deletion { oldSessionDeletion = buffer.deletion }
            }
            guard (try? await Task.sleep(for: pace.sweep)) != nil else { return }
        }
    }

    // MARK: - Orphaned worktrees

    // Looks for orphans once an hour, and prunes each one an hour after it was first seen
    // while automatic pruning is on. Turning pruning on or off looks again at once.
    private func watchOrphanedWorktrees() async {
        var prunes: Bool?
        var nextDiscoveryAt = Date.distantPast
        while !Task.isCancelled {
            let automatically = Preferences.autoPruneOrphanedWorktrees(in: preferences)
            if automatically != prunes {
                prunes = automatically
                orphanedWorktrees.setAutomaticPruningEnabled(automatically, now: now())
                nextDiscoveryAt = .distantPast
            }
            let date = now()
            if date >= nextDiscoveryAt {
                _ = await orphanedWorktrees.refresh(in: store, now: date)
                guard !Task.isCancelled else { return }
                nextDiscoveryAt = now().addingTimeInterval(OrphanedWorktreeSweep.discoveryInterval)
            }

            if automatically {
                let due = orphanedWorktrees.automaticPruningCandidates(now: date)
                if !due.isEmpty {
                    let result = await orphanedWorktrees.prune(due, in: store, now: date)
                    orphanCleanupError = result.failures.isEmpty
                        ? nil
                        : result.failures.map(\.message).joined(separator: "\n")
                    if !result.removed.isEmpty {
                        SessionLog.note("orphan worktree sweep pruned count=\(result.removed.count)")
                    }
                    if !result.failures.isEmpty {
                        SessionLog.note("orphan worktree sweep failed count=\(result.failures.count)")
                    }
                }
            } else if orphanCleanupError != nil {
                orphanCleanupError = nil
            }
            guard (try? await Task.sleep(for: pace.orphans)) != nil else { return }
        }
    }

    // MARK: - Launch housekeeping

    // What a host does once as it starts, before it serves anyone: watch its own memory,
    // record this run so the next one can tell what it left behind, clear up after
    // earlier runs that ended without their quit sweep, and drop old pasted files.
    public static func launchHousekeeping() {
        SessionLog.startMemoryMonitoring()
        RunRegistry.shared.record(RunRegistry.launchCoalition())
        clearUpAfterEarlierRuns()
        AttachmentFolder.pruneOldPastes()
    }

    // A terminal outlives the app that opened it. A run ending anywhere other than its
    // quit sweep - a crash, a force quit, a debug build killed from a terminal - strands
    // every shell it had open, and nothing else will ever close them. Launch is the first
    // moment anything can. It waits on shells that are slow to hang up, so it stays off
    // the main actor.
    //
    // The same goes for anything else such a run started, like a daemon a command sent
    // off on its own. The shells and commands go first, since those have notes of their
    // own and are closed the way they expect.
    private static func clearUpAfterEarlierRuns() {
        Task.detached(priority: .utility) {
            let closed = await ShellRegistry.shared.reapOrphans()
            if !closed.isEmpty {
                SessionLog.note("closed \(counted(closed.count, "shell")) left behind by an earlier run")
            }
            let stopped = await ShellRegistry.tasks.reapOrphans()
            if !stopped.isEmpty {
                SessionLog.note("stopped \(counted(stopped.count, "command")) left behind by an earlier run")
            }
            let ended = RunRegistry.shared.reapEarlierRuns()
            guard ended > 0 else { return }
            SessionLog.note("stopped \(counted(ended, "process", plural: "processes")) left behind by an earlier run")
        }
    }
}

// Where files pasted or dropped into a composer are kept. They only matter for as long as
// the conversation does, so they stay out of backups.
public enum AttachmentFolder {
    public static var url: URL { AppPaths.directory("attachments", backedUp: false) }

    // A pasted file is referenced by path in a conversation that can be resumed later,
    // so it has to outlive the turn that sent it. A week is long enough for that and
    // short enough that the folder does not grow forever.
    public static func pruneOldPastes(olderThan days: Int = 7) {
        let files = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let contents = (try? files.contentsOfDirectory(at: url,
                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: .skipsHiddenFiles)) ?? []
        for file in contents {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? files.removeItem(at: file) }
        }
    }
}
