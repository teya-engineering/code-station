import Foundation
import Observation
import SwiftUI

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
    typealias Discover = @MainActor (String, Set<String>) async -> [GitWorktree.Orphaned]

    static func find(in store: ProjectStore,
                     discover: Discover = { projectPath, protectedPaths in
                         await GitWorktree.orphaned(projectPath: projectPath,
                                                    excluding: protectedPaths)
                     }) async -> [OrphanedWorktree] {
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

// Automatic pruning uses the same warning model as old sessions. An orphan must remain
// visible for a full hour in this run of the app before it can be removed without asking.
enum OrphanedWorktreeSweep {
    static let monitorInterval: Duration = .seconds(1)
    nonisolated static let discoveryInterval: TimeInterval = 3_600
    nonisolated static let gracePeriod: TimeInterval = 3_600
    nonisolated static let retryInterval: TimeInterval = 3_600
    static let batchLimit = 50

    struct EligibilityBuffer {
        private var firstSeenAt: [String: Date] = [:]
        private var retryAt: [String: Date] = [:]

        var nextReadyAt: Date? {
            firstSeenAt.map { worktreeID, firstSeen in
                max(firstSeen.addingTimeInterval(OrphanedWorktreeSweep.gracePeriod),
                    retryAt[worktreeID] ?? .distantPast)
            }
                .min()
        }

        mutating func ready(_ worktrees: [OrphanedWorktree], now: Date) -> [OrphanedWorktree] {
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

        mutating func retry(_ worktreeID: String, at date: Date) {
            guard firstSeenAt[worktreeID] != nil else { return }
            retryAt[worktreeID] = date
        }

        mutating func remove(_ worktreeID: String) {
            firstSeenAt[worktreeID] = nil
            retryAt[worktreeID] = nil
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
    private var automaticPruningEnabled = false
    private var eligibilityBuffer = OrphanedWorktreeSweep.EligibilityBuffer()

    func setAutomaticPruningEnabled(_ enabled: Bool, now: Date = Date()) {
        if automaticPruningEnabled != enabled {
            eligibilityBuffer = OrphanedWorktreeSweep.EligibilityBuffer()
        }
        automaticPruningEnabled = enabled
        synchronizeEligibility(now: now)
    }

    func refresh(in store: ProjectStore, now: Date = Date()) async -> [OrphanedWorktree] {
        let found = await OrphanedWorktreeDiscovery.find(in: store)
        guard !Task.isCancelled else { return worktrees }
        worktrees = found
        synchronizeEligibility(now: now)
        return found
    }

    func replace(_ projectWorktrees: [GitWorktree.Orphaned], for project: Project,
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

    func automaticPruningCandidates(now: Date = Date()) -> [OrphanedWorktree] {
        guard automaticPruningEnabled else { return [] }
        let candidates = eligibilityBuffer.ready(worktrees, now: now)
        updateAutomaticDeletionAt()
        return candidates
    }

    func prune(_ candidates: [OrphanedWorktree], in store: ProjectStore,
               now: Date = Date(),
               remove: Remove? = nil) async -> PruneResult {
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

enum OrphanedWorktreePruning {
    static func confirmation(for worktrees: [OrphanedWorktree],
                             handler: @escaping () -> Void) -> Dialog {
        let count = worktrees.count
        return Dialog(
            title: "Prune \(counted(count, "orphaned worktree"))?",
            message: "These checkouts have no session. Any uncommitted changes in them will be lost. Branches are kept when they have unmerged commits.",
            content: AnyView(OrphanedWorktreeDetails(worktrees: worktrees)),
            actions: [
                Dialog.Action(label: "Prune all", kind: .destructive, handler: handler),
                Dialog.Action(label: "Cancel", kind: .cancel)
            ],
            width: 520)
    }
}

private struct OrphanedWorktreeDetails: View {
    let worktrees: [OrphanedWorktree]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(worktrees) { worktree in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(worktree.projectName)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(worktree.branch ?? "Detached HEAD")
                                .font(.mono(10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(worktree.allocatedBytes > 0
                                 ? worktree.allocatedBytes.formatted(.byteCount(style: .file))
                                 : "No disk usage")
                                .font(.mono(10))
                                .foregroundStyle(.tertiary)
                        }
                        Text("LOCATION")
                            .font(.mono(8.5, .semibold))
                            .kerning(0.8)
                            .foregroundStyle(.tertiary)
                        Text(worktree.path)
                            .font(.mono(10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .surface(Theme.field, cornerRadius: 8)
                }
            }
        }
        .frame(height: min(CGFloat(worktrees.count) * 92, 260))
    }
}
