import Foundation
import Observation

// The comparison belongs to the ask. Reading it never changes the Changes screen.
@MainActor
@Observable
final class SecondOpinionContext {
    let facts: SecondOpinionAskFacts
    var comparison: SecondOpinionDefaults.Comparison
    var refs: [String: String] {
        didSet {
            if refs != oldValue {
                generation += 1
                loading = true
            }
        }
    }
    @ObservationIgnored private var generation = 0
    private(set) var snapshots: [String: GitSnapshot] = [:]
    private(set) var branches: [String: [String]] = [:]
    private(set) var sinceFiles: [SecondOpinionAskFacts.File] = []
    private(set) var loading: Bool
    private(set) var failure: String?
    private(set) var sinceFailure: String?

    init(facts: SecondOpinionAskFacts, comparison: SecondOpinionDefaults.Comparison) {
        self.facts = facts
        self.comparison = comparison
        refs = facts.compareRefs
        loading = !facts.repositories.isEmpty
    }

    var usesBranch: Bool {
        switch comparison {
        case .head: false
        case .branch: true
        case .changesTab:
            facts.repositories.isEmpty ? facts.branch != nil
                : facts.repositories.contains { !facts.headRoots.contains($0.root) }
        }
    }

    var baseTitle: String {
        let selected = bases.values
        let names = Set(selected.isEmpty ? snapshots.values.compactMap { $0.remoteBase?.ref } : Array(selected))
        return names.count > 1 ? "Each project's base" : names.first ?? facts.branch?.base ?? "Base branch"
    }

    var bases: [String: String] {
        guard usesBranch else { return [:] }
        if snapshots.isEmpty { return facts.branch?.bases ?? [:] }
        return snapshots.reduce(into: [:]) { result, entry in
            guard comparison != .changesTab || !facts.headRoots.contains(entry.key),
                  let base = entry.value.remoteBase, entry.value.comparedToRemote else { return }
            result[entry.key] = base.ref
        }
    }

    var inheritsComparison: Bool {
        if comparison == .changesTab && refs == facts.compareRefs { return true }
        let inherited = snapshots.reduce(into: [String: String]()) { result, entry in
            guard !facts.headRoots.contains(entry.key), let base = entry.value.remoteBase else { return }
            result[entry.key] = facts.compareRefs[entry.key] ?? base.ref
        }
        return bases == inherited && refs == facts.compareRefs
    }

    func files(for stop: SecondOpinionStop) -> [SecondOpinionAskFacts.File] {
        if stop == .sinceReview { return sinceFiles }
        let all: [SecondOpinionAskFacts.File]
        if snapshots.isEmpty {
            all = usesBranch ? facts.branch?.files ?? facts.files : facts.files
        } else {
            all = facts.repositories.flatMap { repository in
                guard let snapshot = snapshots[repository.root] else { return [SecondOpinionAskFacts.File]() }
                let files = bases[repository.root] == nil ? snapshot.localFiles : snapshot.files
                return files.filter { !$0.isBinary }.map {
                    SecondOpinionAskFacts.File(root: snapshot.root, path: $0.path,
                                               added: $0.added ?? 0, removed: $0.removed ?? 0)
                }
            }
        }
        guard stop == .file else { return all }
        return all.filter { $0.id == facts.file?.id }
    }

    func scope(for stop: SecondOpinionStop) -> SecondOpinionRequest.Scope {
        switch stop {
        case .sinceReview: .sinceReview(trees: facts.reviewTrees)
        case .file:
            facts.file.map { .file(root: $0.root, path: $0.path, base: base(for: $0)) } ?? .all
        default: bases.isEmpty ? .all : .branch(bases: bases)
        }
    }

    func fileScope(_ file: SecondOpinionAskFacts.File, for stop: SecondOpinionStop) -> SecondOpinionRequest.Scope {
        stop == .sinceReview ? scope(for: stop) : .file(root: file.root, path: file.path, base: base(for: file))
    }

    private func base(for file: SecondOpinionAskFacts.File) -> String? {
        if let base = bases[file.root] { return base }
        return snapshots.first { $0.value.root == file.root }.flatMap { bases[$0.key] }
    }

    func blockedReason(for stop: SecondOpinionStop) -> String? {
        guard stop.kind == .changes else { return nil }
        if loading { return "Reading the review context…" }
        if let failure { return failure }
        if stop == .sinceReview, let sinceFailure { return sinceFailure }
        if stop != .sinceReview && usesBranch && bases.isEmpty && (!snapshots.isEmpty || facts.branch == nil) {
            return "No base branch is available. Choose HEAD or another remote branch."
        }
        if files(for: stop).isEmpty {
            return stop == .sinceReview ? "Nothing changed since the last review."
                : stop == .file ? "This file has no changes in this comparison."
                : usesBranch ? "No changes in this comparison." : "No uncommitted changes. Compare with the base branch."
        }
        return nil
    }

    func read(
        snapshot: (String, String?) async -> GitSnapshot = {
            await GitInspector.snapshot(at: $0, lane: .interactive, comparingToLastCommit: true,
                                        findingRemoteBase: true, comparingToRemote: true, remoteRef: $1)
        },
        remoteBranches: (String) async -> [String] = { await GitInspector.remoteBranches(at: $0).refs },
        since: (String, String) async -> [SecondOpinion.Patch]? = { root, tree in
            guard let changed = await TreeSnapshots.shared.patch(since: tree, at: root) else { return nil }
            return SecondOpinion.split(changed.text, root: changed.root)
        }
    ) async {
        guard !facts.repositories.isEmpty else { return }
        generation += 1
        let reading = generation
        let selectedRefs = refs
        loading = true
        failure = nil
        sinceFailure = nil
        var read: [String: GitSnapshot] = [:]
        var available: [String: [String]] = [:]
        var patches: [SecondOpinion.Patch] = []
        var error: String?
        var snapshotError: String?
        for repository in facts.repositories {
            let value = await snapshot(repository.root, selectedRefs[repository.root])
            guard !Task.isCancelled, generation == reading else { return }
            read[repository.root] = value
            if value.state != .ready { error = "Could not read changes in \(repository.name). Try again." }
            available[repository.root] = await remoteBranches(repository.root)
            if let tree = facts.reviewTrees[repository.root] {
                if let changed = await since(repository.root, tree) { patches += changed }
                else { snapshotError = "The last review snapshot is unavailable. Choose All changes." }
            }
        }
        guard !Task.isCancelled, generation == reading else { return }
        snapshots = read
        branches = available
        sinceFiles = Self.files(in: patches)
        failure = error
        sinceFailure = snapshotError
        loading = false
    }

    nonisolated static func files(in patches: [SecondOpinion.Patch]) -> [SecondOpinionAskFacts.File] {
        patches.map { patch in
            var added = 0
            var removed = 0
            var inHunk = false
            for line in patch.text.components(separatedBy: .newlines) {
                if line.hasPrefix("@@ ") { inHunk = true; continue }
                guard inHunk else { continue }
                if line.hasPrefix("+") { added += 1 }
                if line.hasPrefix("-") { removed += 1 }
            }
            return .init(root: patch.root, path: patch.path,
                         added: added, removed: removed)
        }
    }
}
