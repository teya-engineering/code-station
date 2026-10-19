import Foundation

// Syncing a checkout with origin and moving it between branches, as the GUI's changes
// header does it: push, pull and fetch, and switching to or creating a branch. A command
// names its place by a scope, which is a session's id (the checkout is then one the
// session works in, as its changes list them) or a project's or workspace's id (the
// checkout is then the project's folder, or a member project's), and the checkout by its
// path. Both are checked against what the store and git say now.

// Which way a sync goes.
public enum RemoteSyncAction: String, Codable, Sendable, CaseIterable {
    case push, pull, fetch
}

// What a sync did, in words a person reads, with the commits that went or came.
public struct RemoteSyncResult: Codable, Equatable, Sendable {
    public let action: RemoteSyncAction
    // "Pushed 2 commits to origin/main", "Already up to date", "Fetched origin · …".
    public let summary: String
    public let commits: [RemoteSyncCommit]

    public init(action: RemoteSyncAction, summary: String, commits: [RemoteSyncCommit] = []) {
        self.action = action
        self.summary = summary
        self.commits = commits
    }
}

public struct RemoteSyncCommit: Codable, Equatable, Sendable {
    public let id: String
    public let subject: String

    public init(id: String, subject: String) {
        self.id = id
        self.subject = subject
    }

    public var shortID: String { String(id.prefix(8)) }
}

// The branches a checkout can switch to, for a branch picker: the local ones and the
// remote ones, each most recently committed first, and where the checkout stands now.
public struct RemoteBranches: Codable, Equatable, Sendable {
    public let checkout: String
    // The branch checked out, or "detached at …" when none is.
    public let current: String
    public let onBranch: Bool
    public let local: [String]
    // "origin/feature", including ones that already have a local branch of that name.
    public let remote: [String]
    public let upstream: String?
    public let ahead: Int
    public let behind: Int

    public init(checkout: String, current: String, onBranch: Bool, local: [String], remote: [String],
                upstream: String?, ahead: Int, behind: Int) {
        self.checkout = checkout
        self.current = current
        self.onBranch = onBranch
        self.local = local
        self.remote = remote
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

extension StationCommands {
    // MARK: - Branches

    public func readBranches(_ scope: String, checkout: String) async throws(StationRefusal) -> RemoteBranches {
        let snapshot = try await syncTree(scope, checkout: checkout)
        return RemoteBranches(checkout: checkout, current: snapshot.branch, onBranch: snapshot.onBranch,
                              local: snapshot.branches, remote: snapshot.remoteBranches.map(\.ref),
                              upstream: snapshot.upstream, ahead: snapshot.ahead, behind: snapshot.behind)
    }

    // Switches the checkout to `branch`: a local branch by name, or a remote one by its
    // "origin/name", which switches to the local branch of that name or makes one that
    // tracks it. With `creating`, makes a new branch from where the checkout is and
    // switches to it.
    public func switchBranch(_ scope: String, checkout: String, to branch: String,
                             creating: Bool) async throws(StationRefusal) {
        let name = branch.trimmed
        guard !name.isEmpty else { throw StationRefusal("Name the branch first.") }
        let snapshot = try await syncTree(scope, checkout: checkout)
        let error: String?
        if creating {
            guard !snapshot.branches.contains(name) else {
                throw StationRefusal("A branch called \(name) already exists.")
            }
            error = await GitActions.createBranch(name, at: snapshot.root)
        } else if snapshot.branches.contains(name) {
            guard !(snapshot.onBranch && snapshot.branch == name) else { return }
            error = await GitActions.switchBranch(name, at: snapshot.root)
        } else if let remote = snapshot.remoteBranches.first(where: { $0.ref == name }) {
            error = snapshot.branches.contains(remote.name)
                ? await GitActions.switchBranch(remote.name, at: snapshot.root)
                : await GitActions.checkoutRemoteBranch(remote, at: snapshot.root)
        } else {
            throw StationRefusal("There is no branch called \(name).")
        }
        nudgeChangesWatches()
        if let error { throw StationRefusal(error.trimmed) }
    }

    // MARK: - Sync

    public func sync(_ scope: String, checkout: String,
                     _ action: RemoteSyncAction) async throws(StationRefusal) -> RemoteSyncResult {
        let snapshot = try await syncTree(scope, checkout: checkout)
        defer { nudgeChangesWatches() }
        switch action {
        case .push: return try await push(snapshot)
        case .pull: return try await pull(snapshot)
        case .fetch: return try await fetch(snapshot, checkout: checkout)
        }
    }

    // A branch with no upstream is published to origin under its own name. One that
    // trails its upstream is refused before anything is sent, since origin would refuse
    // it too; the pull that fixes that is the person's call.
    private func push(_ snapshot: GitSnapshot) async throws(StationRefusal) -> RemoteSyncResult {
        guard snapshot.hasCommits else { throw StationRefusal("There are no commits to push yet.") }
        guard snapshot.onBranch else { throw StationRefusal("Switch to a branch before pushing.") }
        let upstream = snapshot.upstream
        let preview = await GitActions.commitsToPush(hasUpstream: upstream != nil, at: snapshot.root)
        let commits: [GitRemoteCommit]
        switch preview {
        case .commits(let sent): commits = sent
        case .behindUpstream(let behind, _):
            throw StationRefusal("\(upstream ?? "origin") has \(counted(behind, "commit")) this branch does not, "
                                 + "so origin would refuse the push. Pull first, then push.")
        case .failed(let message): throw StationRefusal(message.trimmed)
        }
        if let upstream, commits.isEmpty {
            return RemoteSyncResult(action: .push, summary: "Nothing to push: \(upstream) has every commit")
        }
        if let error = await GitActions.push(hasUpstream: upstream != nil, at: snapshot.root) {
            throw StationRefusal(error.trimmed)
        }
        let summary = upstream.map { "Pushed \(counted(commits.count, "commit")) to \($0)" }
            ?? "Published \(snapshot.branch) to origin"
        return RemoteSyncResult(action: .push, summary: summary, commits: commits.map(RemoteSyncCommit.init))
    }

    private func pull(_ snapshot: GitSnapshot) async throws(StationRefusal) -> RemoteSyncResult {
        guard let upstream = snapshot.upstream else {
            throw StationRefusal("\(snapshot.branch) has no upstream branch to pull from. Push it first.")
        }
        switch await GitActions.pull(at: snapshot.root) {
        case .upToDate:
            return RemoteSyncResult(action: .pull, summary: "Already up to date with \(upstream)")
        case .updated(let commits):
            return RemoteSyncResult(action: .pull, summary: "Pulled \(counted(commits.count, "commit")) from \(upstream)",
                                    commits: commits.map(RemoteSyncCommit.init))
        case .updatedWithStashConflict(let commits):
            return RemoteSyncResult(
                action: .pull,
                summary: "Pulled \(counted(commits.count, "commit")) from \(upstream), with conflicts: "
                    + "your uncommitted changes could not go back on top cleanly. The files hold both "
                    + "versions between conflict markers, and the originals remain in the stash.",
                commits: commits.map(RemoteSyncCommit.init))
        case .failed(let message):
            throw StationRefusal(message.trimmed)
        }
    }

    private func fetch(_ snapshot: GitSnapshot, checkout: String) async throws(StationRefusal) -> RemoteSyncResult {
        guard await Self.hasOrigin(snapshot.root) else {
            throw StationRefusal("This repository has no origin to fetch from.")
        }
        if let error = await GitActions.fetchOrigin(at: snapshot.root) { throw StationRefusal(error.trimmed) }
        let after = await GitInspector.snapshot(at: checkout, lane: .interactive)
        return RemoteSyncResult(action: .fetch, summary: "Fetched origin · " + after.syncDescription())
    }

    private static func hasOrigin(_ root: String) async -> Bool {
        guard let tool = GitInspector.tool() else { return false }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain(lane: .interactive) {
            GitInspector.run(tool, ["remote", "get-url", "origin"], in: url).ok
        }
    }

    // MARK: - Checking what is asked for

    // The folders a scope may sync: a session's checkouts, a project's folder, or a
    // workspace's member folders.
    private func syncCheckouts(of scope: String) throws(StationRefusal) -> [String] {
        guard let id = UUID(uuidString: scope) else { throw .noContainer }
        if let session = store.session(id) { return changesCheckouts(of: session).map(\.path) }
        if let workspace = store.workspace(id) {
            return ([workspace.leadProjectID] + workspace.projectIDs).compactMap { store.project($0)?.path }
        }
        if let project = store.project(id), project.kind != .adHoc { return [project.path] }
        throw .noContainer
    }

    private func syncTree(_ scope: String, checkout: String) async throws(StationRefusal) -> GitSnapshot {
        guard try syncCheckouts(of: scope).contains(checkout) else {
            throw StationRefusal("\(checkout) is not one of this place's checkouts.")
        }
        let snapshot = await GitInspector.snapshot(at: checkout, lane: .interactive)
        switch snapshot.state {
        case .ready: return snapshot
        case .notARepo: throw StationRefusal("\(checkout) is not a git repository.")
        case .missingFolder: throw StationRefusal("\(checkout) is no longer there.")
        case .gitMissing: throw StationRefusal("Could not find git on PATH.")
        case .failed(let message): throw StationRefusal(message)
        }
    }

    private func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

extension RemoteSyncCommit {
    init(_ commit: GitRemoteCommit) {
        self.init(id: commit.id, subject: commit.subject)
    }
}
