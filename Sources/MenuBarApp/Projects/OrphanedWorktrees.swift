import Foundation
import Observation

// A checkout the app created but no saved session owns. The project details are kept
// with it because cleanup can be started from the global sidebar as well as that project.
struct OrphanedWorktree: Identifiable, Equatable, Sendable {
    let projectID: UUID
    let projectName: String
    let projectPath: String
    let path: String
    let branch: String?
    let allocatedBytes: Int64

    var id: String { path }
}

// Finds app-owned checkouts across every project. Pending removals are not orphans: their
// cleanup is already saved and retried at launch, so a second cleanup path must not race it.
@MainActor
enum OrphanedWorktreeDiscovery {
    static func find(in store: ProjectStore) async -> [OrphanedWorktree] {
        let pendingPaths = Set(store.pendingSessionRemovals.flatMap(\.worktrees).map(\.path))
        var activePaths: [UUID: Set<String>] = [:]
        for session in store.sessions {
            for checkout in store.checkoutProjects(for: session) {
                if let path = checkout.worktreePath {
                    activePaths[checkout.projectID, default: []].insert(path)
                }
            }
        }

        var found: [OrphanedWorktree] = []
        for project in store.projects {
            guard !Task.isCancelled else { return [] }
            let excluded = activePaths[project.id, default: []].union(pendingPaths)
            let worktrees = await GitWorktree.orphaned(projectPath: project.path,
                                                       excluding: excluded)
            found += worktrees.map {
                OrphanedWorktree(projectID: project.id,
                                 projectName: project.name,
                                 projectPath: project.path,
                                 path: $0.path,
                                 branch: $0.branch,
                                 allocatedBytes: $0.allocatedBytes)
            }
        }
        return found.sorted {
            let projects = $0.projectName.localizedStandardCompare($1.projectName)
            return projects == .orderedSame
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : projects == .orderedAscending
        }
    }
}

// Automatic pruning uses the same warning model as old sessions. An orphan must remain
// visible for a full hour in this run of the app before it can be removed without asking.
enum OrphanedWorktreeSweep {
    static let interval: Duration = .seconds(3_600)
    nonisolated static let gracePeriod: TimeInterval = 3_600
    static let batchLimit = 50

    struct EligibilityBuffer {
        private var firstSeenAt: [String: Date] = [:]

        var nextReadyAt: Date? {
            firstSeenAt.values
                .map { $0.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod) }
                .min()
        }

        mutating func ready(_ worktrees: [OrphanedWorktree], now: Date) -> [OrphanedWorktree] {
            let eligibleIDs = Set(worktrees.map(\.id))
            firstSeenAt = firstSeenAt.filter { eligibleIDs.contains($0.key) }

            for worktree in worktrees where firstSeenAt[worktree.id] == nil {
                firstSeenAt[worktree.id] = now
            }

            return Array(worktrees.filter { worktree in
                guard let firstSeen = firstSeenAt[worktree.id] else { return false }
                return now.timeIntervalSince(firstSeen) >= OrphanedWorktreeSweep.gracePeriod
            }.prefix(OrphanedWorktreeSweep.batchLimit))
        }

        mutating func remove(_ worktreeID: String) {
            firstSeenAt[worktreeID] = nil
        }
    }
}

@MainActor
@Observable
final class OrphanedWorktreeMonitor {
    struct PruneResult {
        let removed: [OrphanedWorktree]
        let failures: [GitWorktree.Failure]
    }

    typealias Remove = (OrphanedWorktree) async -> Result<Void, GitWorktree.Failure>

    private(set) var worktrees: [OrphanedWorktree] = []
    private(set) var automaticDeletionAt: Date?
    private(set) var isPruning = false

    func refresh(in store: ProjectStore) async -> [OrphanedWorktree] {
        let found = await OrphanedWorktreeDiscovery.find(in: store)
        guard !Task.isCancelled else { return worktrees }
        worktrees = found
        if worktrees.isEmpty { automaticDeletionAt = nil }
        return found
    }

    func replace(_ projectWorktrees: [GitWorktree.Orphaned], for project: Project) {
        worktrees.removeAll { $0.projectID == project.id }
        worktrees += projectWorktrees.map {
            OrphanedWorktree(projectID: project.id,
                             projectName: project.name,
                             projectPath: project.path,
                             path: $0.path,
                             branch: $0.branch,
                             allocatedBytes: $0.allocatedBytes)
        }
        worktrees.sort {
            let projects = $0.projectName.localizedStandardCompare($1.projectName)
            return projects == .orderedSame
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : projects == .orderedAscending
        }
        if worktrees.isEmpty { automaticDeletionAt = nil }
    }

    func setAutomaticDeletionAt(_ date: Date?) {
        automaticDeletionAt = worktrees.isEmpty ? nil : date
    }

    func prune(_ candidates: [OrphanedWorktree], remove: Remove? = nil) async -> PruneResult {
        guard !isPruning else { return PruneResult(removed: [], failures: []) }
        isPruning = true
        defer { isPruning = false }

        let operation: Remove = remove ?? { worktree in
            await GitWorktree.remove(worktreePath: worktree.path,
                                     projectPath: worktree.projectPath,
                                     branch: worktree.branch)
        }
        var removed: [OrphanedWorktree] = []
        var failures: [GitWorktree.Failure] = []
        for worktree in candidates {
            guard !Task.isCancelled else { break }
            switch await operation(worktree) {
            case .success:
                removed.append(worktree)
            case .failure(let failure):
                failures.append(failure)
            }
        }
        let removedIDs = Set(removed.map(\.id))
        worktrees.removeAll { removedIDs.contains($0.id) }
        if worktrees.isEmpty { automaticDeletionAt = nil }
        return PruneResult(removed: removed, failures: failures)
    }
}
