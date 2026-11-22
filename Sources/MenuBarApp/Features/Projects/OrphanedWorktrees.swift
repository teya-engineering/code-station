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

// Orphans are looked for once an hour. Taking them on their own is the old session
// sweep's job, so a clean orphan and an old session share one countdown.
enum OrphanedWorktreeSweep {
    nonisolated static let discoveryInterval: TimeInterval = 3_600
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
    private(set) var isPruning = false
    // Worktrees the person asked to hear about later, by path. Saved, since the answer
    // is a choice that should outlast a restart.
    private(set) var deferredUntil: [String: Date]
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        deferredUntil = Preferences.orphanCleanupDeferrals(in: preferences)
    }

    // The orphans cleanup may look at: everything but the ones put off for now.
    func cleanupCandidates(now: Date = Date()) -> [OrphanedWorktree] {
        worktrees.filter { (deferredUntil[$0.id] ?? .distantPast) <= now }
    }

    func deferCleanup(of worktreeID: String, until date: Date, now: Date = Date()) {
        deferredUntil = deferredUntil.filter { $0.value > now }
        deferredUntil[worktreeID] = date
        Preferences.setOrphanCleanupDeferrals(deferredUntil, in: preferences)
    }

    func refresh(in store: ProjectStore) async -> [OrphanedWorktree] {
        let found = await OrphanedWorktreeDiscovery.find(in: store)
        guard !Task.isCancelled else { return worktrees }
        worktrees = found
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
    }

    func prune(_ candidates: [OrphanedWorktree], in store: ProjectStore,
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
        for worktree in candidates {
            guard !Task.isCancelled else { break }
            if store.protectsWorktree(at: worktree.path) {
                worktrees.removeAll { $0.id == worktree.id }
                continue
            }
            switch await operation(worktree) {
            case .success:
                removed.append(worktree)
            case .failure(let failure):
                failures.append(failure)
            }
        }
        let removedIDs = Set(removed.map(\.id))
        worktrees.removeAll { removedIDs.contains($0.id) }
        return PruneResult(removed: removed, failures: failures)
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
