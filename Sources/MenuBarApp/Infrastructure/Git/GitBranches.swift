import Foundation
import CryptoKit

struct GitBranch: Identifiable, Sendable, Equatable {
    let ref: String
    let name: String
    let tip: String
    let upstream: String
    let worktree: String
    let remote: Bool
    var id: String { ref }
}

struct GitBranchPolicy: Sendable {
    var protectedNames: Set<String> = []
    var allowsMerge = true
    var allowsSquash = true
    var allowsRewrite = true
    var note = "Local repository"
}

struct GitBranchCatalog: Sendable {
    var branches: [GitBranch]
    var current: String
    var policy: GitBranchPolicy
    var recovery: GitBranchRecovery?
    var stashes: [GitBranchStash]
}

struct GitBranchStash: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let message: String
}

struct GitBranchPreview: Sendable {
    let source: GitBranch
    let destination: String
    let head: String
    let fingerprint: String
    let dirtyCount: Int
    let incoming: [GitRemoteCommit]
    let outgoing: Int
    let unmergedCount: Int
    let files: [GitChange]
    let conflicts: [String]
    let conflictNote: String?
    let freshness: String
    let remoteVerified: Bool
    let policy: GitBranchPolicy
}

struct GitBranchRecovery: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case merge, squash, rebase, stash, fastForward = "fast-forward" }
    var kind: Kind
    var branch: String
    var originalHead: String
    var source: String
    var sourceTip: String
    var stash: String?
    var restoring = false
    var message: String { "\(kind == .squash ? "Squash" : "Merge") \(source) into \(branch)" }
}

struct GitBranchResult: Sendable {
    var message: String
    var recovery: GitBranchRecovery?
    var failed = false
}

struct GitConflictContents: Sendable {
    var current: String?
    var incoming: String?
    var working: String?
}

// All mutations use GitInspector's serial background lane, including the existing
// commit and push helpers. The preview token also detects edits made outside the app.
enum GitBranches {
    private struct Failure: Error { let message: String }
    private static let recoveryName = "code-station-branch-operation.json"

    static func catalog(at root: String) async -> Result<GitBranchCatalog, Error> {
        guard let tool = await GitInspector.tool() else { return .failure(Failure(message: "Git is unavailable.")) }
        let gh = await githubTool(tool)
        return await GitInspector.offMain {
            Result {
                let url = URL(fileURLWithPath: root)
                let branches = try readBranches(tool, url)
                return GitBranchCatalog(branches: branches,
                    current: GitInspector.run(tool, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: url).trimmedText,
                    policy: readPolicy(tool, gh, url), recovery: try recovery(tool, url), stashes: try stashes(tool, url))
            }
        }
    }

    static func preview(_ branch: GitBranch, at root: String) async -> Result<GitBranchPreview, Error> {
        guard let tool = await GitInspector.tool() else { return .failure(Failure(message: "Git is unavailable.")) }
        let gh = await githubTool(tool)
        return await GitInspector.offMain {
            Result {
                let url = URL(fileURLWithPath: root)
                var freshness = "Checked against local \(branch.name). Remote refs are from the last fetch."
                var verified = !branch.remote
                if branch.remote {
                    let remote = String(branch.name.prefix { $0 != "/" })
                    let fetch = GitInspector.run(tool, ["fetch", "--quiet", "--", remote], in: url, timeout: 30)
                    verified = fetch.ok
                    freshness = fetch.ok ? "Fetched \(remote) just now. Checked remote-tracking ref \(branch.name)."
                        : "Fetch failed. \(branch.name) may be stale. Refresh before merging.\n" + fetch.failureMessage
                }
                guard let source = try readBranches(tool, url).first(where: { $0.ref == branch.ref }) else {
                    throw Failure(message: "The selected branch no longer exists.")
                }
                let head = try run(tool, ["rev-parse", "--verify", "HEAD"], url).trimmedText
                let current = try run(tool, ["symbolic-ref", "--quiet", "--short", "HEAD"], url).trimmedText
                let incoming = try run(tool, ["log", "--format=%H%x09%s", "\(head)..\(source.tip)", "--"], url)
                let outgoing = try run(tool, ["rev-list", "--count", "\(source.tip)..\(head)"], url)
                let merge = GitInspector.run(tool, ["merge-tree", "--write-tree", "--name-only", "-z", head, source.tip], in: url)
                let fields = merge.text.components(separatedBy: "\0")
                var conflicts: [String] = []
                if merge.status == 1 {
                    for field in fields.dropFirst() {
                        if field.isEmpty { break }
                        conflicts.append(field)
                    }
                }
                let headTree = try run(tool, ["rev-parse", head + "^{tree}"], url).trimmedText
                let alreadyApplied = merge.ok && fields.first?.trimmed == headTree
                let conflictNote = merge.ok || merge.status == 1 ? nil
                    : "Conflict check unavailable. " + merge.failureMessage
                let changes = try run(tool, ["diff", "--numstat", "-z", "--no-renames", "\(head)...\(source.tip)", "--"], url)
                let status = try run(tool, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], url)
                return GitBranchPreview(source: source, destination: current, head: head,
                    fingerprint: try fingerprint(tool, url), dirtyCount: status.text.split(separator: "\0").count,
                    incoming: alreadyApplied ? [] : commits(incoming.text), outgoing: Int(outgoing.trimmedText) ?? 0,
                    unmergedCount: commits(incoming.text).count, files: changedFiles(changes.text), conflicts: conflicts, conflictNote: conflictNote,
                    freshness: freshness, remoteVerified: verified, policy: readPolicy(tool, gh, url))
            }
        }
    }

    static func integrate(_ preview: GitBranchPreview, kind: GitBranchRecovery.Kind,
                          consent: Bool, at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, gh, url in
            guard preview.remoteVerified else { throw Failure(message: "Fetch the remote branch before merging it.") }
            guard !preview.incoming.isEmpty else { return GitBranchResult(message: "Nothing to merge. This branch already contains \(preview.source.name).") }
            let policy = readPolicy(tool, gh, url)
            if kind == .merge && !policy.allowsMerge || kind == .squash && !policy.allowsSquash {
                throw Failure(message: "Repository policy does not allow this merge method.")
            }
            if kind == .fastForward && preview.outgoing > 0 {
                throw Failure(message: "\(preview.destination) has commits that \(preview.source.name) does not. Create a merge commit instead.")
            }
            if kind == .rebase && (!policy.allowsRewrite || policy.protectedNames.contains(preview.destination)) {
                throw Failure(message: "Rebasing this branch is blocked by repository policy or unavailable policy information.")
            }
            try validate(preview, tool, url)
            var state = GitBranchRecovery(kind: kind, branch: preview.destination, originalHead: preview.head,
                                          source: preview.source.name, sourceTip: preview.source.tip)
            state.stash = try saveWork(consent: consent, branch: state.branch, tool, url)
            try save(state, tool, url)
            guard try clean(tool, url),
                  try run(tool, ["rev-parse", "HEAD"], url).trimmedText == preview.head else {
                return GitBranchResult(message: "Files changed while preparing the operation. Your stash is retained. Abort to restore it.", recovery: state, failed: true)
            }
            let arguments: [String]
            switch kind {
            case .merge: arguments = ["merge", "--no-ff", "--no-edit", "--no-autostash", "-m", state.message, state.sourceTip]
            case .squash: arguments = ["merge", "--squash", "--no-autostash", state.sourceTip]
            case .fastForward: arguments = ["merge", "--ff-only", "--no-autostash", state.sourceTip]
            case .rebase: arguments = ["rebase", "--no-autostash", state.sourceTip]
            case .stash: throw Failure(message: "Choose a merge method.")
            }
            var result = GitInspector.run(tool, arguments, in: url, environment: ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"])
            if kind == .squash && result.ok {
                result = GitInspector.run(tool, ["commit", "-m", state.message], in: url)
            }
            guard result.ok else {
                return GitBranchResult(message: "\(kind.rawValue.capitalized) paused. Resolve the files below, then continue, or abort.\n" + result.failureMessage,
                                       recovery: state, failed: true)
            }
            return try finish(state, tool, url)
        }
    }

    // The recovery screen only works in the checkout it was opened from, so a merge into
    // another checkout must either finish or leave that checkout exactly as it was.
    static func integrateIntoOtherCheckout(_ preview: GitBranchPreview, kind: GitBranchRecovery.Kind,
                                           at root: String) async -> GitBranchResult {
        guard preview.dirtyCount == 0 else {
            return GitBranchResult(message: "\(preview.destination) has uncommitted changes in \(root). Commit or stash them there first.", failed: true)
        }
        guard preview.conflicts.isEmpty, preview.conflictNote == nil else {
            return GitBranchResult(message: "This merge has conflicts. Merge \(preview.destination) into \(preview.source.name) and resolve them there first.", failed: true)
        }
        guard let tool = await GitInspector.tool() else { return GitBranchResult(message: "Git is unavailable.", failed: true) }
        guard await GitInspector.offMain({ !blocksOtherActions(tool, URL(fileURLWithPath: root)) }) else {
            return GitBranchResult(message: "Another Git operation is paused in \(root). Finish or abort it there first.", failed: true)
        }
        let result = await integrate(preview, kind: kind, consent: false, at: root)
        guard result.recovery != nil else { return result }
        let undo = await abort(at: root)
        return GitBranchResult(message: undo.failed
            ? "The merge into \(preview.destination) stopped and could not be undone. Open \(root) to finish or abort it.\n" + undo.message
            : "The merge into \(preview.destination) stopped, so it was undone.\n" + result.message.components(separatedBy: "\n").dropFirst().joined(separator: "\n"),
            failed: true)
    }

    static func switchBranch(_ preview: GitBranchPreview, consent: Bool, at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            try validate(preview, tool, url)
            let source = preview.source
            guard source.worktree.isEmpty else { throw Failure(message: "This branch is already open in \(source.worktree).") }
            let stash = try saveWork(consent: consent, branch: preview.destination, tool, url)
            let arguments: [String]
            if source.remote {
                let local = String(source.name.drop { $0 != "/" }.dropFirst())
                guard !((try readBranches(tool, url)).contains { !$0.remote && $0.name == local }) else {
                    throw Failure(message: "A local branch named \(local) already exists. Select that branch to switch to it. Your saved work remains in Stashes.")
                }
                arguments = ["switch", "--track", source.name]
            } else { arguments = ["switch", "--", source.name] }
            let result = GitInspector.run(tool, arguments, in: url)
            guard result.ok else {
                if let stash {
                    let state = GitBranchRecovery(kind: .stash, branch: preview.destination, originalHead: preview.head,
                                                  source: source.name, sourceTip: source.tip, stash: stash, restoring: true)
                    try save(state, tool, url)
                    return try finish(state, tool, url, message: "Switch failed: " + result.failureMessage)
                }
                throw Failure(message: result.failureMessage)
            }
            return GitBranchResult(message: "Switched to \(source.name)." + (stash == nil ? "" : " Your work remains in a named stash for \(preview.destination)."))
        }
    }

    static func create(name: String, from branch: GitBranch?, worktree: String? = nil, at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            try idle(tool, url)
            try validateName(name, tool, url)
            if let branch { try unchanged(branch, tool, url) }
            let head = GitInspector.run(tool, ["rev-parse", "--verify", "HEAD"], in: url)
            let tip = branch?.tip ?? (head.ok ? head.trimmedText : "")
            if let worktree {
                guard !tip.isEmpty else { throw Failure(message: "Create a first commit before making a worktree.") }
                let target = URL(fileURLWithPath: worktree).standardizedFileURL
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw Failure(message: "Choose a folder that does not already exist.")
                }
                try run(tool, ["worktree", "add", "-b", name, "--", target.path, tip], url)
                return GitBranchResult(message: "Created worktree at \(target.path) on \(name). Your current checkout is unchanged.")
            }
            // Creating a branch does not move dirty work between existing branches.
            try run(tool, ["switch", "-c", name] + (tip.isEmpty ? [] : [tip]), url)
            return GitBranchResult(message: "Created and switched to \(name).")
        }
    }

    static func rename(_ branch: GitBranch, to name: String, at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, gh, url in
            try idle(tool, url)
            try editable(branch, allowingCurrent: true, tool, gh, url)
            try validateName(name, tool, url)
            try run(tool, ["branch", "-m", "--", branch.name, name], url)
            return GitBranchResult(message: "Renamed \(branch.name) to \(name). The remote name is unchanged.")
        }
    }

    static func delete(_ branch: GitBranch, force: Bool, at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, gh, url in
            try idle(tool, url)
            try editable(branch, tool, gh, url)
            let merged = GitInspector.run(tool, ["merge-base", "--is-ancestor", branch.tip, "HEAD"], in: url).ok
            guard merged || force else { throw Failure(message: "This branch has commits not in the current branch. Compare or merge them, or explicitly choose force deletion.") }
            try run(tool, ["branch", force ? "-D" : "-d", "--", branch.name], url)
            return GitBranchResult(message: "Deleted local branch \(branch.name).")
        }
    }

    static func stash(at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            try idle(tool, url)
            let branch = try run(tool, ["symbolic-ref", "--short", "HEAD"], url).trimmedText
            let saved = try saveWork(consent: true, branch: branch, tool, url)
            return GitBranchResult(message: saved == nil ? "No changes to stash." : "Saved your work in a named stash for \(branch).")
        }
    }

    static func restore(_ stash: GitBranchStash, at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            try idle(tool, url)
            guard try clean(tool, url) else { throw Failure(message: "Commit or stash your current work before restoring another stash.") }
            guard try stashes(tool, url).contains(where: { $0.id == stash.id }) else { throw Failure(message: "This stash no longer exists.") }
            let state = GitBranchRecovery(kind: .stash,
                branch: try run(tool, ["symbolic-ref", "--short", "HEAD"], url).trimmedText,
                originalHead: try run(tool, ["rev-parse", "HEAD"], url).trimmedText,
                source: stash.message, sourceTip: "", stash: stash.id, restoring: true)
            try save(state, tool, url)
            return try finish(state, tool, url, message: "Stash restored.")
        }
    }

    static func conflicts(at root: String) async -> [String] {
        guard let tool = await GitInspector.tool() else { return [] }
        return await GitInspector.offMain { conflictPaths(tool, URL(fileURLWithPath: root)) }
    }

    static func contents(path: String, at root: String) async -> GitConflictContents {
        guard let tool = await GitInspector.tool() else { return .init() }
        return await GitInspector.offMain {
            let url = URL(fileURLWithPath: root)
            func version(_ stage: Int) -> String? {
                let result = GitInspector.run(tool, ["show", ":\(stage):\(path)"], in: url)
                return result.ok && !result.truncated && !result.text.contains("\0") ? result.text : nil
            }
            let file = url.appendingPathComponent(path)
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            let text = values?.isSymbolicLink == false && (values?.fileSize ?? Int.max) < 1_000_000
                ? try? String(contentsOf: file, encoding: .utf8) : nil
            return .init(current: version(2), incoming: version(3), working: text?.contains("\0") == false ? text : nil)
        }
    }

    // nil text stages an externally edited file; a side also handles deletion conflicts.
    static func resolve(path: String, side: String? = nil, text: String? = nil, at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            guard let state = try recovery(tool, url), conflictPaths(tool, url).contains(path) else {
                throw Failure(message: "Refresh the conflict list before resolving this file.")
            }
            var stagedDeletion = false
            if let side {
                guard side == "ours" || side == "theirs" else { throw Failure(message: "Invalid conflict side.") }
                let stage = side == "ours" ? 2 : 3
                let exists = GitInspector.run(tool, ["cat-file", "-e", ":\(stage):\(path)"], in: url).ok
                if exists { try run(tool, ["checkout", "--\(side)", "--", path], url) }
                else {
                    try run(tool, ["rm", "--", path], url)
                    stagedDeletion = true
                }
            } else if let text {
                let file = url.appendingPathComponent(path)
                let resolved = file.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(url.resolvingSymlinksInPath().path + "/") else {
                    throw Failure(message: "Edit this symlink in an external editor, then mark it resolved.")
                }
                guard !hasMarkers(text) else { throw Failure(message: "Remove the conflict markers before marking this file resolved.") }
                try text.write(to: file, atomically: true, encoding: .utf8)
            } else if let text = try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8), hasMarkers(text) {
                throw Failure(message: "Remove the conflict markers before marking this file resolved.")
            }
            if !stagedDeletion { try run(tool, ["add", "-A", "--", ":(literal)" + path], url) }
            return GitBranchResult(message: "Resolved \(path).", recovery: state)
        }
    }

    static func continueOperation(at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            guard let state = try recovery(tool, url) else { throw Failure(message: "No operation is waiting to continue.") }
            let active = ["MERGE_HEAD", "rebase-merge", "rebase-apply"].contains { inProgress(tool, url, $0) }
            let head = try run(tool, ["rev-parse", "HEAD"], url).trimmedText
            // Git can finish before the app records the outcome, or a terminal can finish
            // it. Recover the saved work without moving that branch a second time.
            if !state.restoring, !active, conflictPaths(tool, url).isEmpty,
               state.kind != .squash || head != state.originalHead {
                guard try run(tool, ["symbolic-ref", "--short", "HEAD"], url).trimmedText == state.branch else {
                    throw Failure(message: "Return to \(state.branch) before recovering this operation.")
                }
                return try finish(state, tool, url, message: "No Git operation is active. Kept the current branch and recovered saved work.")
            }
            try sameBranch(state, tool, url)
            guard conflictPaths(tool, url).isEmpty else { throw Failure(message: "Resolve every conflict before continuing.") }
            if state.restoring {
                // Keep the recovery stash until the user confirms all restored files.
                try clearRecovery(tool, url)
                return GitBranchResult(message: "Recovery closed. Your saved stash is retained in Stashes for any further recovery.")
            }
            let arguments = state.kind == .rebase ? ["rebase", "--continue"] : ["commit", "-m", state.message]
            let result = GitInspector.run(tool, arguments, in: url, environment: ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"])
            guard result.ok else { return GitBranchResult(message: result.failureMessage, recovery: state, failed: true) }
            return try finish(state, tool, url)
        }
    }

    static func skipRebaseCommit(at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            guard let state = try recovery(tool, url), state.kind == .rebase, !state.restoring else {
                throw Failure(message: "No rebase commit is waiting to be skipped.")
            }
            try sameBranch(state, tool, url)
            let result = GitInspector.run(tool, ["rebase", "--skip"], in: url,
                                          environment: ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"])
            guard result.ok else { return GitBranchResult(message: result.failureMessage, recovery: state, failed: true) }
            return try finish(state, tool, url)
        }
    }

    static func retryRestore(at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            guard let state = try recovery(tool, url), state.restoring else {
                throw Failure(message: "No stash restoration is waiting to retry.")
            }
            try sameBranch(state, tool, url)
            guard try clean(tool, url) else {
                throw Failure(message: "Save or move your current changes before retrying. The retained stash remains available.")
            }
            return try finish(state, tool, url, message: "Local work restored.")
        }
    }

    static func abort(at root: String) async -> GitBranchResult {
        await mutate(at: root) { tool, _, url in
            guard let state = try recovery(tool, url) else { throw Failure(message: "No operation is waiting to abort.") }
            try sameBranch(state, tool, url)
            if state.restoring {
                // Restoration can include untracked paths. Never erase them to retry.
                throw Failure(message: "The branch operation is complete. Resolve the restored files, then finish recovery. Your stash remains available.")
            }
            let result: GitInspector.CommandOutput
            if state.kind == .rebase && inProgress(tool, url, "rebase-merge") || state.kind == .rebase && inProgress(tool, url, "rebase-apply") {
                result = GitInspector.run(tool, ["rebase", "--abort"], in: url)
            } else if inProgress(tool, url, "MERGE_HEAD") {
                result = GitInspector.run(tool, ["merge", "--abort"], in: url)
            } else {
                guard try run(tool, ["rev-parse", "HEAD"], url).trimmedText == state.originalHead else {
                    throw Failure(message: "HEAD changed outside this operation. Your recovery state and stash are retained; inspect the repository before continuing.")
                }
                result = GitInspector.run(tool, ["reset", "--merge", state.originalHead], in: url)
            }
            guard result.ok else { return GitBranchResult(message: result.failureMessage, recovery: state, failed: true) }
            return try finish(state, tool, url, message: "Operation aborted. Your original branch is restored.")
        }
    }

    static func nameProblem(_ name: String, at root: String) async -> String? {
        guard let tool = await GitInspector.tool() else { return "Git is unavailable." }

        return await GitInspector.offMain { nameProblem(name, tool, URL(fileURLWithPath: root)) }
    }

    static func errorMessage(_ error: Error) -> String {
        (error as? Failure)?.message ?? error.localizedDescription
    }

    static func blocksOtherActions(_ tool: GitInspector.GitTool, _ url: URL) -> Bool {
        inProgress(tool, url, recoveryName) || ["MERGE_HEAD", "rebase-merge", "rebase-apply"].contains { inProgress(tool, url, $0) }
    }

    private static func mutate(at root: String,
        _ work: @escaping @Sendable (GitInspector.GitTool, GitInspector.GitTool?, URL) throws -> GitBranchResult) async -> GitBranchResult {
        guard let tool = await GitInspector.tool() else { return GitBranchResult(message: "Git is unavailable.", failed: true) }
        let gh = await githubTool(tool)
        return await GitInspector.offMain {
            let url = URL(fileURLWithPath: root)
            do { return try work(tool, gh, url) }
            catch { return GitBranchResult(message: errorMessage(error), recovery: try? recovery(tool, url), failed: true) }
        }
    }

    private static func readBranches(_ tool: GitInspector.GitTool, _ url: URL) throws -> [GitBranch] {
        let result = try run(tool, ["for-each-ref", "--sort=-committerdate", "--format=%(refname)%00%(objectname)%00%(upstream:short)%00%(worktreepath)%00%(symref)", "refs/heads", "refs/remotes"], url)
        return result.text.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 5, fields[4].isEmpty else { return nil }
            let remote = fields[0].hasPrefix("refs/remotes/")
            return GitBranch(ref: fields[0], name: String(fields[0].dropFirst(remote ? 13 : 11)), tip: fields[1],
                             upstream: fields[2], worktree: fields[3], remote: remote)
        }
    }

    @MainActor private static func githubTool(_ tool: GitInspector.GitTool) -> GitInspector.GitTool? {
        ProcessManager.resolve("gh").map { .init(path: $0, searchPath: tool.searchPath) }
    }

    private static func readPolicy(_ tool: GitInspector.GitTool, _ gh: GitInspector.GitTool?, _ url: URL) -> GitBranchPolicy {
        var policy = GitBranchPolicy()
        let remote = GitInspector.run(tool, ["remote", "get-url", "origin"], in: url)
        guard remote.ok else { return policy }
        if let named = GitInspector.originDefaultBranch(tool, in: url) { policy.protectedNames.insert(named) }
        policy.allowsRewrite = false
        policy.note = "Remote protection could not be verified. Rename, delete and rebase are unavailable."
        guard let gh else { return policy }
        let repository = GitInspector.run(gh, ["api", "repos/{owner}/{repo}"], in: url, timeout: 15)
        let protected = GitInspector.run(gh, ["api", "--paginate", "--slurp", "repos/{owner}/{repo}/branches?protected=true&per_page=100"], in: url, timeout: 15)
        guard repository.ok, protected.ok, !repository.truncated, !protected.truncated,
              let data = repository.text.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let branchData = protected.text.data(using: .utf8),
              let pages = try? JSONSerialization.jsonObject(with: branchData) as? [[[String: Any]]] else { return policy }
        if let name = info["default_branch"] as? String { policy.protectedNames.insert(name) }
        policy.protectedNames.formUnion(pages.flatMap { $0 }.compactMap { $0["name"] as? String })
        policy.allowsMerge = info["allow_merge_commit"] as? Bool ?? false
        policy.allowsSquash = info["allow_squash_merge"] as? Bool ?? false
        policy.allowsRewrite = true
        policy.note = "Repository merge methods and protected branches checked with GitHub. Default branches cannot be renamed, deleted or rebased here."
        return policy
    }

    private static func validate(_ preview: GitBranchPreview, _ tool: GitInspector.GitTool, _ url: URL) throws {
        try idle(tool, url)
        guard try run(tool, ["symbolic-ref", "--short", "HEAD"], url).trimmedText == preview.destination,
              try run(tool, ["rev-parse", "HEAD"], url).trimmedText == preview.head,
              try fingerprint(tool, url) == preview.fingerprint else {
            throw Failure(message: "The branch or working tree changed after the preview. Refresh the preview before continuing.")
        }
        try unchanged(preview.source, tool, url)
    }

    private static func unchanged(_ branch: GitBranch, _ tool: GitInspector.GitTool, _ url: URL) throws {
        guard let fresh = try readBranches(tool, url).first(where: { $0.ref == branch.ref }), fresh.tip == branch.tip,
              fresh.worktree == branch.worktree else {
            throw Failure(message: "The selected branch changed. Refresh the branch list before continuing.")
        }
    }

    private static func editable(_ branch: GitBranch, allowingCurrent: Bool = false, _ tool: GitInspector.GitTool, _ gh: GitInspector.GitTool?, _ url: URL) throws {
        let policy = readPolicy(tool, gh, url)
        try unchanged(branch, tool, url)
        let here = URL(fileURLWithPath: branch.worktree).resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        guard !branch.remote, branch.worktree.isEmpty || allowingCurrent && here,
              policy.allowsRewrite, !policy.protectedNames.contains(branch.name) else {
            throw Failure(message: "This branch is remote, protected, or checked out in a worktree. Its local reference cannot be changed here.")
        }
    }

    private static func validateName(_ name: String, _ tool: GitInspector.GitTool, _ url: URL) throws {
        if let message = nameProblem(name, tool, url) { throw Failure(message: message) }
    }

    private static func nameProblem(_ name: String, _ tool: GitInspector.GitTool, _ url: URL) -> String? {
        guard !name.hasPrefix("-"), !name.isEmpty, name == name.trimmed,
              name != "HEAD", GitInspector.run(tool, ["check-ref-format", "refs/heads/" + name], in: url).ok,
              !GitInspector.run(tool, ["show-ref", "--verify", "--quiet", "refs/heads/" + name], in: url).ok else {
            return "Choose a valid, unique branch name without spaces or Git special characters."
        }

        return nil
    }

    private static func fingerprint(_ tool: GitInspector.GitTool, _ url: URL) throws -> String {
        var hash = SHA256()
        for arguments in [["status", "--porcelain=v1", "-z", "--untracked-files=all"], ["diff", "--binary", "--no-ext-diff"], ["diff", "--cached", "--binary", "--no-ext-diff"]] {
            let output = try run(tool, arguments, url)
            guard !output.truncated else { throw Failure(message: "The working tree is too large to verify safely. Commit or stash it before continuing.") }
            hash.update(data: Data(output.text.utf8))
        }
        let untracked = try run(tool, ["ls-files", "--others", "--exclude-standard", "-z"], url)
        for path in untracked.text.split(separator: "\0") {
            let output = try run(tool, ["hash-object", "--", String(path)], url)
            hash.update(data: Data(output.text.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func saveWork(consent: Bool, branch: String, _ tool: GitInspector.GitTool, _ url: URL) throws -> String? {
        guard try !clean(tool, url) else { return nil }
        guard consent else { throw Failure(message: "Stash consent is required while the working tree has changes.") }
        guard conflictPaths(tool, url).isEmpty else { throw Failure(message: "Resolve existing conflicts before stashing.") }
        try run(tool, ["stash", "push", "--include-untracked", "-m", "Code Station: \(branch) · \(UUID().uuidString)"], url)
        return try run(tool, ["rev-parse", "refs/stash"], url).trimmedText
    }

    private static func finish(_ original: GitBranchRecovery, _ tool: GitInspector.GitTool, _ url: URL,
                               message: String? = nil) throws -> GitBranchResult {
        var state = original
        if let stash = state.stash {
            state.restoring = true
            try save(state, tool, url)
            let restored = GitInspector.run(tool, ["stash", "apply", "--index", stash], in: url)
            guard restored.ok else {
                return GitBranchResult(message: "Local work could not be fully restored. The stash \(stash.prefix(8)) is retained. Resolve any conflicts or recover the remaining files from Stashes before finishing.\n" + restored.failureMessage,
                                       recovery: state, failed: true)
            }
            try dropStash(stash, tool, url)
        }
        try clearRecovery(tool, url)
        let summary = message ?? (state.kind == .rebase
            ? "Rebased \(state.branch) onto \(state.source). Saved locally; nothing was pushed."
            : state.kind == .fastForward
            ? "Fast-forwarded \(state.branch) to \(state.source). Saved locally; nothing was pushed."
            : "\(state.kind == .squash ? "Squashed" : "Merged") \(state.source) into \(state.branch). Saved locally; nothing was pushed.")
        return GitBranchResult(message: summary + (state.stash == nil ? "" : " Your uncommitted work has been restored."))
    }

    private static func dropStash(_ id: String?, _ tool: GitInspector.GitTool, _ url: URL) throws {
        guard let id, let stash = try stashes(tool, url).first(where: { $0.id == id }) else { return }
        try run(tool, ["stash", "drop", stash.name], url)
    }

    private static func stashes(_ tool: GitInspector.GitTool, _ url: URL) throws -> [GitBranchStash] {
        try run(tool, ["stash", "list", "--format=%H%x00%gd%x00%s"], url).text.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            return fields.count == 3 ? GitBranchStash(id: fields[0], name: fields[1], message: fields[2]) : nil
        }
    }

    private static func recoveryURL(_ tool: GitInspector.GitTool, _ url: URL) throws -> URL {
        let path = try run(tool, ["rev-parse", "--absolute-git-dir"], url).trimmedText
        return URL(fileURLWithPath: path).appendingPathComponent(recoveryName)
    }

    private static func recovery(_ tool: GitInspector.GitTool, _ url: URL) throws -> GitBranchRecovery? {
        let file = try recoveryURL(tool, url)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(GitBranchRecovery.self, from: Data(contentsOf: file))
    }

    private static func save(_ state: GitBranchRecovery, _ tool: GitInspector.GitTool, _ url: URL) throws {
        try JSONEncoder().encode(state).write(to: recoveryURL(tool, url), options: .atomic)
    }

    private static func clearRecovery(_ tool: GitInspector.GitTool, _ url: URL) throws {
        let file = try recoveryURL(tool, url)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private static func sameBranch(_ state: GitBranchRecovery, _ tool: GitInspector.GitTool, _ url: URL) throws {
        if state.kind == .rebase && !state.restoring {
            guard inProgress(tool, url, "rebase-merge") || inProgress(tool, url, "rebase-apply") else {
                throw Failure(message: "The rebase state changed outside the app. Inspect the repository and retained stash before recovering.")
            }
            return
        }
        if !state.restoring {
            guard try run(tool, ["rev-parse", "HEAD"], url).trimmedText == state.originalHead else {
                throw Failure(message: "HEAD changed outside this operation. The recovery state and stash are retained.")
            }
        }
        guard try run(tool, ["symbolic-ref", "--short", "HEAD"], url).trimmedText == state.branch else {
            throw Failure(message: "Return to \(state.branch) before recovering this operation.")
        }
    }

    private static func inProgress(_ tool: GitInspector.GitTool, _ url: URL, _ name: String) -> Bool {
        let path = GitInspector.run(tool, ["rev-parse", "--git-path", name], in: url)
        guard path.ok else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: path.trimmedText, relativeTo: url).path)
    }

    private static func idle(_ tool: GitInspector.GitTool, _ url: URL) throws {
        guard !blocksOtherActions(tool, url), conflictPaths(tool, url).isEmpty else {
            throw Failure(message: "Finish or abort the current Git operation before starting another one.")
        }
    }

    private static func clean(_ tool: GitInspector.GitTool, _ url: URL) throws -> Bool {
        try run(tool, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], url).text.isEmpty
    }

    private static func conflictPaths(_ tool: GitInspector.GitTool, _ url: URL) -> [String] {
        GitInspector.run(tool, ["diff", "--name-only", "--diff-filter=U", "-z"], in: url).text.split(separator: "\0").map(String.init)
    }

    private static func hasMarkers(_ text: String) -> Bool {
        text.split(separator: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") || $0 == "=======" }
    }

    @discardableResult private static func run(_ tool: GitInspector.GitTool, _ args: [String], _ url: URL) throws -> GitInspector.CommandOutput {
        let output = GitInspector.run(tool, args, in: url)
        guard output.ok else { throw Failure(message: output.failureMessage) }
        return output
    }

    private static func commits(_ text: String) -> [GitRemoteCommit] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            return fields.count == 2 ? GitRemoteCommit(id: String(fields[0]), subject: String(fields[1])) : nil
        }
    }

    private static func changedFiles(_ text: String) -> [GitChange] {
        text.split(separator: "\0").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            return GitChange(path: String(fields[2]), kind: .modified, isStaged: false, isUnstaged: false,
                             added: Int(fields[0]), removed: Int(fields[1]), isBinary: fields[0] == "-")
        }
    }
}
