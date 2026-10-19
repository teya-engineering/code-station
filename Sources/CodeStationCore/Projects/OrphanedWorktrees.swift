import Foundation
import Observation

// A checkout the app created but no saved session owns. The project details are kept
// with it because cleanup can be started from the global sidebar as well as that project.
public struct OrphanedWorktree: Identifiable, Equatable, Sendable {
    public let projectID: UUID
    public let projectName: String
    public let projectPath: String
    public let path: String
    public let branch: String?
    public let allocatedBytes: Int64

    public var id: String { path }

    public init(projectID: UUID, projectName: String, projectPath: String, path: String, branch: String?, allocatedBytes: Int64) {
        self.projectID = projectID
        self.projectName = projectName
        self.projectPath = projectPath
        self.path = path
        self.branch = branch
        self.allocatedBytes = allocatedBytes
    }
}

// Finds app-owned checkouts across every project. Pending removals are not orphans: their
// cleanup is already saved and retried at launch, so a second cleanup path must not race it.
@MainActor
public enum OrphanedWorktreeDiscovery {
    public typealias Discover = @MainActor (String, Set<String>) async -> [GitWorktree.Orphaned]

    // Asks git for a project's app-owned checkouts that no saved session claims.
    public static let live: Discover = { projectPath, protectedPaths in
        await GitWorktree.orphaned(projectPath: projectPath, excluding: protectedPaths)
    }

    static func find(in store: ProjectStore,
                     discover: Discover = live) async -> [OrphanedWorktree] {
        var found: [OrphanedWorktree] = []
        for project in store.projects {
            guard !Task.isCancelled else { return [] }
            let protectedPaths = store.protectedWorktreePaths(for: project)
            let worktrees = await discover(project.path, protectedPaths)
            guard !Task.isCancelled else { return [] }
            let protectedNow = store.protectedWorktreePaths(for: project)
            found += worktrees.filter {
                !protectedNow.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path)
            }.map {
                OrphanedWorktree(projectID: project.id,
                                 projectName: project.name,
                                 projectPath: project.path,
                                 path: $0.path,
                                 branch: $0.branch,
                                 allocatedBytes: $0.allocatedBytes)
            }
        }
        return found.filter { !store.protectsWorktree(at: $0.path) }.sorted {
            let projects = $0.projectName.localizedStandardCompare($1.projectName)
            return projects == .orderedSame
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : projects == .orderedAscending
        }
    }
}

@MainActor
@Observable
public final class OrphanedWorktreeMonitor {
    public struct PruneResult {
        public let removed: [OrphanedWorktree]
        public let failures: [GitWorktree.Failure]

        public init(removed: [OrphanedWorktree], failures: [GitWorktree.Failure]) {
            self.removed = removed
            self.failures = failures
        }
    }

    public typealias Remove = (OrphanedWorktree) async -> Result<Void, GitWorktree.Failure>

    public private(set) var worktrees: [OrphanedWorktree] = []
    public private(set) var automaticDeletionAt: Date?
    public private(set) var isPruning = false
    private var automaticPruningEnabled = false
    private var eligibilityBuffer = OrphanedWorktreeSweep.EligibilityBuffer()

    // How orphans are found and removed: by git, unless a test stands in for it.
    @ObservationIgnored private let discover: OrphanedWorktreeDiscovery.Discover
    @ObservationIgnored private let remove: Remove?

    public init(discover: @escaping OrphanedWorktreeDiscovery.Discover = OrphanedWorktreeDiscovery.live,
                remove: Remove? = nil) {
        self.discover = discover
        self.remove = remove
    }

    public func setAutomaticPruningEnabled(_ enabled: Bool, now: Date = Date()) {
        if automaticPruningEnabled != enabled {
            eligibilityBuffer = OrphanedWorktreeSweep.EligibilityBuffer()
        }
        automaticPruningEnabled = enabled
        synchronizeEligibility(now: now)
    }

    public func refresh(in store: ProjectStore, now: Date = Date()) async -> [OrphanedWorktree] {
        let found = await OrphanedWorktreeDiscovery.find(in: store, discover: discover)
        guard !Task.isCancelled else { return worktrees }
        worktrees = found
        synchronizeEligibility(now: now)
        return found
    }

    public func replace(_ projectWorktrees: [GitWorktree.Orphaned], for project: Project,
                 now: Date = Date()) {
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
        synchronizeEligibility(now: now)
    }

    public func automaticPruningCandidates(now: Date = Date()) -> [OrphanedWorktree] {
        guard automaticPruningEnabled else { return [] }
        let candidates = eligibilityBuffer.ready(worktrees, now: now)
        updateAutomaticDeletionAt()
        return candidates
    }

    public func prune(_ candidates: [OrphanedWorktree], in store: ProjectStore,
               now: Date = Date(),
               remove: Remove? = nil) async -> PruneResult {
        guard !isPruning else { return PruneResult(removed: [], failures: []) }
        isPruning = true
        defer { isPruning = false }

        let operation: Remove = remove ?? self.remove ?? { worktree in
            await GitWorktree.remove(worktreePath: worktree.path,
                                     projectPath: worktree.projectPath,
                                     branch: worktree.branch)
        }
        var removed: [OrphanedWorktree] = []
        var failures: [GitWorktree.Failure] = []
        var failedIDs: [String] = []
        for worktree in candidates {
            guard !Task.isCancelled else { break }
            if store.protectsWorktree(at: worktree.path) {
                worktrees.removeAll { $0.id == worktree.id }
                eligibilityBuffer.remove(worktree.id)
                continue
            }
            switch await operation(worktree) {
            case .success:
                removed.append(worktree)
            case .failure(let failure):
                failures.append(failure)
                failedIDs.append(worktree.id)
            }
        }
        let removedIDs = Set(removed.map(\.id))
        worktrees.removeAll { removedIDs.contains($0.id) }
        for worktree in removed { eligibilityBuffer.remove(worktree.id) }
        let retryAt = now.addingTimeInterval(OrphanedWorktreeSweep.retryInterval)
        for worktreeID in failedIDs { eligibilityBuffer.retry(worktreeID, at: retryAt) }
        synchronizeEligibility(now: now)
        return PruneResult(removed: removed, failures: failures)
    }

    private func synchronizeEligibility(now: Date) {
        guard automaticPruningEnabled else {
            eligibilityBuffer = OrphanedWorktreeSweep.EligibilityBuffer()
            if automaticDeletionAt != nil { automaticDeletionAt = nil }
            return
        }
        _ = eligibilityBuffer.ready(worktrees, now: now)
        updateAutomaticDeletionAt()
    }

    private func updateAutomaticDeletionAt() {
        let nextReadyAt = eligibilityBuffer.nextReadyAt
        if automaticDeletionAt != nextReadyAt { automaticDeletionAt = nextReadyAt }
    }
}

// Automatic pruning uses the same warning model as old sessions. An orphan must remain
// visible for a full hour in this run of the app before it can be removed without asking.
public enum OrphanedWorktreeSweep {
    public static let monitorInterval: Duration = .seconds(1)
    public nonisolated static let discoveryInterval: TimeInterval = 3_600
    nonisolated static let gracePeriod: TimeInterval = 3_600
    public nonisolated static let retryInterval: TimeInterval = 3_600
    static let batchLimit = 50

    public struct EligibilityBuffer {
        private var firstSeenAt: [String: Date] = [:]
        private var retryAt: [String: Date] = [:]

        public init() {}

        public var nextReadyAt: Date? {
            firstSeenAt.map { worktreeID, firstSeen in
                max(firstSeen.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod),
                    retryAt[worktreeID] ?? .distantPast)
            }
                .min()
        }

        public mutating func ready(_ worktrees: [OrphanedWorktree], now: Date) -> [OrphanedWorktree] {
            let eligibleIDs = Set(worktrees.map(\.id))
            firstSeenAt = firstSeenAt.filter { eligibleIDs.contains($0.key) }
            retryAt = retryAt.filter { eligibleIDs.contains($0.key) }

            for worktree in worktrees where firstSeenAt[worktree.id] == nil {
                firstSeenAt[worktree.id] = now
            }

            return Array(worktrees.filter { worktree in
                guard let firstSeen = firstSeenAt[worktree.id] else { return false }
                let warningEnds = firstSeen.addingTimeInterval(gracePeriod)
                return now >= max(warningEnds, retryAt[worktree.id] ?? .distantPast)
            }.prefix(OrphanedWorktreeSweep.batchLimit))
        }

        public mutating func retry(_ worktreeID: String, at date: Date) {
            guard firstSeenAt[worktreeID] != nil else { return }
            retryAt[worktreeID] = date
        }

        public mutating func remove(_ worktreeID: String) {
            firstSeenAt[worktreeID] = nil
            retryAt[worktreeID] = nil
        }
    }
}
