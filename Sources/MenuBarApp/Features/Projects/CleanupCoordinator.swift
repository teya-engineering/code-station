import Foundation
import Observation

// The cleanup the app does with nobody asking: old sessions and orphaned worktrees under
// the cleanup rule, workspaces that have sat empty for their days, and removals an
// earlier run left unfinished. It runs for as long as the app does, whether or not the
// window is on screen, and the window reads what it publishes.
@MainActor
@Observable
final class CleanupCoordinator {
    // What the old session sweep is counting down to, and what waits for a yes.
    private(set) var status = OldSessionSweep.Status()
    // The empty workspaces in their final hour, and when that hour ends.
    private(set) var workspaceRemoval: EmptyWorkspaceSweep.Removal?
    // The workspaces the latest pass took, so the window can say so.
    private(set) var removedWorkspaces: [ProjectWorkspace] = []
    private(set) var sessionCleanupError: String?
    private(set) var orphanCleanupError: String?

    private struct SweepRule: Equatable {
        let rule: CleanupRule
        let days: Int
    }

    private let store: ProjectStore
    private let runner: SessionRunner
    private let settings: AppSettings
    private let orphanedWorktrees: OrphanedWorktreeMonitor
    @ObservationIgnored private var sweepRule: SweepRule?
    @ObservationIgnored private var sweep: Task<Void, Never>?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    init(store: ProjectStore, runner: SessionRunner, settings: AppSettings,
         orphanedWorktrees: OrphanedWorktreeMonitor) {
        self.store = store
        self.runner = runner
        self.settings = settings
        self.orphanedWorktrees = orphanedWorktrees
    }

    func start() {
        guard loops.isEmpty else { return }
        loops = [Task { await resumePendingSessionRemovals() },
                 Task { await discoverOrphanedWorktrees() },
                 Task { await removeEmptyWorkspaces() }]
        followSweepRule()
    }

    func stop() {
        loops.forEach { $0.cancel() }
        loops = []
        sweep?.cancel()
        sweep = nil
        sweepRule = nil
    }

    private func resumePendingSessionRemovals() async {
        let failures = await SessionLifecycle.resumePendingRemovals(in: store)
        sessionCleanupError = failures.isEmpty
            ? nil
            : failures.map(\.message).joined(separator: "\n")
    }

    // MARK: - Old sessions and orphaned worktrees

    // The sweep starts over whenever the rule or the age changes, so a countdown armed
    // under one rule never ends under another.
    private func followSweepRule() {
        let rule = withObservationTracking {
            SweepRule(rule: settings.cleanupRule, days: settings.oldSessionDays)
        } onChange: { [weak self] in
            // Told before the setting changes, so the new value is read a turn later.
            Task { @MainActor in
                guard let self, !self.loops.isEmpty else { return }
                self.followSweepRule()
            }
        }
        guard rule != sweepRule else { return }
        sweepRule = rule
        sweep?.cancel()
        sweep = Task { await deleteOldSessions(under: rule) }
    }

    // Age is the only thing that makes a session sweepable, and age only moves with the
    // clock, so this runs on a timer rather than off a change in the store.
    private func deleteOldSessions(under sweep: SweepRule) async {
        status = OldSessionSweep.Status()
        guard sweep.rule.deletesOnItsOwn else { return }
        var buffer = OldSessionSweep.EligibilityBuffer()
        var swept = 0

        while !Task.isCancelled {
            let now = Date()
            let deleted = await OldSessionSweep.run(
                days: sweep.days, rule: sweep.rule, store: store, runner: runner,
                buffer: &buffer, now: now,
                orphans: orphanedWorktrees.cleanupCandidates(now: now),
                pruneOrphans: pruneOrphanedWorktrees)
            guard !Task.isCancelled else { return }
            if deleted > 0 { swept = deleted }
            let status = buffer.status(swept: swept)
            if self.status != status { self.status = status }
            do {
                try await Task.sleep(for: OldSessionSweep.monitorInterval)
            } catch {
                return
            }
        }
    }

    private func pruneOrphanedWorktrees(_ worktrees: [OrphanedWorktree]) async -> Int {
        let result = await orphanedWorktrees.prune(worktrees, in: store)
        orphanCleanupError = result.failures.isEmpty
            ? nil
            : result.failures.map(\.message).joined(separator: "\n")
        if !result.failures.isEmpty {
            SessionLog.note("orphan worktree sweep failed count=\(result.failures.count)")
        }
        return result.removed.count
    }

    // Looked for once an hour. Taking them is the sweep's job, under the same rule and
    // countdown as old sessions.
    private func discoverOrphanedWorktrees() async {
        while !Task.isCancelled {
            _ = await orphanedWorktrees.refresh(in: store)
            do {
                try await Task.sleep(for: .seconds(OrphanedWorktreeSweep.discoveryInterval))
            } catch {
                return
            }
        }
    }

    // MARK: - Empty workspaces

    // Workspaces made for a short job go once they have sat empty for their days. They
    // are a rule of their own, so this runs whatever the old session setting says.
    private func removeEmptyWorkspaces() async {
        var buffer = EmptyWorkspaceSweep.Buffer()
        while !Task.isCancelled {
            let removed = EmptyWorkspaceSweep.run(store: store, buffer: &buffer)
            if workspaceRemoval != buffer.removal { workspaceRemoval = buffer.removal }
            if !removed.isEmpty { removedWorkspaces = removed }
            do {
                try await Task.sleep(for: EmptyWorkspaceSweep.monitorInterval)
            } catch {
                return
            }
        }
    }
}
