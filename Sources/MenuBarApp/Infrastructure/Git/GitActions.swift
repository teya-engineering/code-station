import Foundation

struct GitRemoteCommit: Identifiable, Sendable, Equatable {
    let id: String
    let subject: String

    var shortID: String { String(id.prefix(8)) }
}

enum GitPushPreview: Sendable, Equatable {
    case commits([GitRemoteCommit])
    // Origin has commits this branch does not, so it would refuse the push.
    case behindUpstream(incoming: [GitRemoteCommit], outgoing: [GitRemoteCommit])
    // A branch with no upstream whose name origin already uses. When origin's copy is
    // part of this branch's history, the push just moves it on and `unrelated` is empty.
    // Otherwise the two only share a name, often an old branch nobody cleaned up, and
    // origin refuses the push. The only way through is to replace origin's copy at `tip`,
    // which drops the `unrelated` commits from origin.
    case nameOnOrigin(outgoing: [GitRemoteCommit], unrelated: [GitRemoteCommit], tip: String)
    // Origin's tip is an old version of this branch, left by an amend or a rebase. Pushing
    // replaces the `replaced` commits on origin, and refuses if origin no longer points at `tip`.
    case rewroteUpstream(outgoing: [GitRemoteCommit], replaced: [GitRemoteCommit], tip: String)
    case failed(String)
}

// What a pull did, in the terms the screen has to report. Up to date and updated are both
// success; they read differently only because one of them has nothing to show.
enum GitPullOutcome: Sendable, Equatable {
    case upToDate
    case updated([GitRemoteCommit])
    // The branch moved, but the uncommitted work could not be put back cleanly, so it is
    // sitting in the files as conflict markers.
    case updatedWithStashConflict([GitRemoteCommit])
    case failed(String)
}

// The git commands that change a repository: switching branch, committing, pulling and
// pushing. They live apart from GitInspector so the inspection side stays read-only,
// but they start git through the same runner, so PATH lookup and prompt suppression
// behave the same everywhere. Most actions return nil on success or the error text git
// gave, ready to show in a dialog. Pull is the exception: it can succeed in more than one
// way worth telling apart, so it answers with an outcome instead.
enum GitActions {

    // Long enough for a fetch over a normal connection, short enough that an unreachable
    // origin cannot hold a button down for minutes.
    private static let networkTimeout: TimeInterval = 30

    private static let upstreamAdvancedAfterRewrite =
        "You rewrote commits that origin still has, and origin has newer work. Reconcile the changes in a terminal before pulling or pushing."

    static func fetchOrigin(at root: String) async -> String? {
        guard let tool = await GitInspector.tool() else {
            return "Could not find git on PATH."
        }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            let origin = GitInspector.run(tool, ["remote", "get-url", "origin"], in: url)
            guard origin.ok else { return nil }
            let fetch = GitInspector.run(tool, ["fetch", "--quiet", "origin"], in: url,
                                         timeout: networkTimeout)
            return fetch.ok ? nil : fetch.failureMessage
        }
    }

    static func switchBranch(_ branch: String, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            GitInspector.run(tool, ["switch", branch], in: url)
        }
    }

    // Throws away the uncommitted work in the chosen files. A tracked file goes back to
    // the last commit, in the index and the working tree at once, so a change that was
    // only half staged goes with the rest. A rename is one row on the screen but two paths
    // in git: the new name has to go and the old one has to come back. A file git has never
    // seen has no committed version to restore, so it is moved to the trash, which at least
    // leaves a way back.
    static func discard(_ files: [GitChange], at root: String) async -> String? {
        guard !files.isEmpty else { return "No files are selected." }
        guard let tool = await GitInspector.tool() else { return "Could not find git on PATH." }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            guard !GitBranches.blocksOtherActions(tool, url) else {
                return "Finish or abort the current operation in Branches before discarding files."
            }
            let paths = pathspec(for: files.filter { !$0.isUntracked })
            if !paths.isEmpty {
                let restored = GitInspector.run(
                    tool, ["restore", "--staged", "--worktree", "--source=HEAD", "--"] + paths, in: url)
                guard restored.ok else { return restored.failureMessage }
            }
            for file in files where file.isUntracked {
                do {
                    try FileManager.default.trashItem(
                        at: url.appendingPathComponent(file.path), resultingItemURL: nil)
                } catch {
                    return "\(file.path): \(error.localizedDescription)"
                }
            }
            return nil
        }
    }

    // Commits just the chosen files and leaves the rest of the tree alone, index
    // included. Staging first brings untracked files in, and the pathspec on the commit
    // itself keeps anything staged earlier but not chosen from riding along. A rename is
    // two paths that have to travel together: with only the new one, git records a
    // delete and an unrelated new file.
    static func commitSelected(message: String, files: [GitChange], amend: Bool = false,
                               at root: String) async -> String? {
        let paths = pathspec(for: files)
        guard !paths.isEmpty else { return "No files are selected." }
        // Only paths with unstaged work go through add. A path whose change is already
        // staged in full, like the old side of a rename, is gone from both the working
        // tree and the index, and add refuses a pathspec that matches nothing.
        let unstaged = files.filter(\.isUnstaged).map { ":(literal)" + $0.path }
        return await perform(at: root) { tool, url in
            if !unstaged.isEmpty {
                let add = GitInspector.run(tool, ["add", "-A", "--"] + unstaged, in: url)
                guard add.ok else { return add }
            }
            return GitInspector.run(
                tool, commitArguments(message: message, amend: amend) + ["--"] + paths, in: url)
        }
    }

    private static func commitArguments(message: String, amend: Bool) -> [String] {
        amend ? ["commit", "--amend", "-m", message] : ["commit", "-m", message]
    }

    // :(literal) keeps a path that happens to contain a glob character from matching
    // other files when git reads it back as a pathspec.
    private static func pathspec(for files: [GitChange]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for file in files {
            for path in [file.originalPath, file.path].compactMap({ $0 })
            where seen.insert(path).inserted {
                paths.append(":(literal)" + path)
            }
        }
        return paths
    }

    // Pull works out how to reconcile the branch itself rather than leaning on pull.rebase,
    // which git refuses to guess at and which plenty of checkouts never set: a button has
    // no way to stop halfway and ask. The fetch comes first, so the decision runs on how
    // far apart the two branches are now instead of whenever origin was last read, and the
    // step that follows is a fast-forward or a rebase based on those numbers. Uncommitted
    // work is stashed around the move either way, since sessions leave trees dirty all the
    // time and a pull otherwise refuses to touch them.
    static func pull(at root: String) async -> GitPullOutcome {
        guard let tool = await GitInspector.tool() else {
            return .failed("Could not find git on PATH.")
        }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            reconcile(tool, in: url, with: "@{u}", refusingRewrittenCommits: true)
        }
    }

    // Puts the checkout on `branch` with all of its local commits on top of origin. The
    // choice that calls this says when a rebase is needed, so preserving those commits is
    // explicit. A failed rebase aborts itself, and a checkout that started on another
    // branch is put back there so a failed session launch leaves the folder unchanged.
    static func updateCheckout(to branch: String, at root: String) async -> String? {
        guard let tool = await GitInspector.tool() else {
            return "Could not find git on PATH."
        }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            guard !GitBranches.blocksOtherActions(tool, url) else {
                return "Finish or abort the current operation in Branches before switching branches."
            }
            let originalBranch = GitInspector.run(
                tool, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: url)
            let originalHead = GitInspector.run(tool, ["rev-parse", "--verify", "HEAD"], in: url)
            let switched = GitInspector.run(tool, ["switch", branch], in: url)
            guard switched.ok else { return switched.failureMessage }

            switch reconcile(tool, in: url, with: "origin/\(branch)") {
            case .upToDate, .updated:
                return nil
            case .updatedWithStashConflict:
                return "The branch was updated, but uncommitted changes could not be put back cleanly. Resolve the conflicts before starting a session."
            case .failed(let message):
                let restored = restoreCheckout(tool, in: url, branch: originalBranch, head: originalHead,
                                               unlessAlreadyOn: branch)
                return restored ? message : message + "\n\nThe checkout could not be switched back to where it started."
            }
        }
    }

    // Moves `branch` up to `target` without stashing, so the folder's uncommitted work is
    // never at risk. On the checked-out branch git refuses outright when an incoming
    // commit would change a file the work also changes. Any other branch moves as a bare
    // ref, which never touches the working tree; going through fetch rather than
    // update-ref keeps git's own guards against a move that is not a fast-forward and
    // against moving a branch another worktree has checked out.
    static func fastForwardBranch(_ branch: String, to target: String,
                                  at root: String) async -> String? {
        guard let tool = await GitInspector.tool() else {
            return "Could not find git on PATH."
        }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            guard !GitBranches.blocksOtherActions(tool, url) else {
                return "Finish or abort the current operation in Branches before updating \(branch)."
            }
            let current = GitInspector.run(
                tool, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: url)
            let moved = current.ok && current.trimmedText == branch
                ? GitInspector.run(tool, ["merge", "--ff-only", "--no-autostash", target], in: url)
                : GitInspector.run(
                    tool, ["fetch", "--quiet", ".", "refs/remotes/\(target):refs/heads/\(branch)"],
                    in: url)
            return moved.ok ? nil : moved.failureMessage
        }
    }

    // A branch with no upstream yet, which is every session worktree branch, is published
    // to origin under its own name and starts tracking it. Replacing origin's copy is
    // pinned to the tip the review showed, so if anyone moved it since, origin refuses
    // and nothing they pushed is lost.
    static func push(hasUpstream: Bool, replacing tip: String? = nil, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            let publish = hasUpstream ? [] : ["-u", "origin", "HEAD"]
            guard let tip else { return GitInspector.run(tool, ["push"] + publish, in: url) }
            let branch = GitInspector.run(tool, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: url)
            guard branch.ok else { return branch }

            if hasUpstream {
                let upstream = GitInspector.run(
                    tool, ["for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)",
                           "refs/heads/\(branch.trimmedText)"], in: url)
                guard upstream.ok else { return upstream }
                let destination = upstream.trimmedText.components(separatedBy: "\0")
                guard destination.count == 2, !destination[0].isEmpty,
                      destination[1].hasPrefix("refs/heads/") else {
                    return GitInspector.CommandOutput(
                        errorText: "Could not resolve the upstream branch. Refresh the push review before trying again.")
                }
                let remote = destination[0]
                let ref = destination[1]

                // The review shows the upstream, so Git's push settings must not send
                // its replacement to a different branch or remote.
                return GitInspector.run(
                    tool, ["push", "--force-with-lease=\(ref):\(tip)", "--", remote, "HEAD:\(ref)"], in: url)
            }

            return GitInspector.run(tool, ["push", "--force-with-lease=refs/heads/\(branch.trimmedText):\(tip)"]
                                    + publish, in: url)
        }
    }

    // Reads what a push would send, and whether origin would take it. A push refused for
    // being behind is the one failure that can be seen coming, but only from a fresh read
    // of origin, so a branch with an upstream fetches first. A fetch that fails is not
    // fatal here: reaching origin is the push's own job, and the preview can still be built
    // from whatever the last one left behind.
    static func commitsToPush(hasUpstream: Bool, at root: String) async -> GitPushPreview {
        guard let tool = await GitInspector.tool() else {
            return .failed("Could not find git on PATH.")
        }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            if hasUpstream {
                _ = GitInspector.run(tool, ["fetch", "--quiet", "origin"], in: url,
                                     timeout: networkTimeout)
            }
            let tip = hasUpstream ? nil : originTipForCurrentBranch(tool, in: url)
            let arguments = hasUpstream
                ? ["log", "--no-color", "--format=%H%x09%s", "@{u}..HEAD"]
                : ["log", "--no-color", "--format=%H%x09%s", "HEAD", "--not", "--remotes=origin"]
            let output = GitInspector.run(tool, arguments, in: url)
            guard output.ok else { return .failed(output.failureMessage) }
            let commits = parseRemoteCommits(output.text)
            if let tip {
                let theirs = GitInspector.run(tool, ["log", "--no-color", "--format=%H%x09%s", "HEAD..\(tip)"], in: url)
                guard theirs.ok else { return .failed(theirs.failureMessage) }
                return .nameOnOrigin(outgoing: commits, unrelated: parseRemoteCommits(theirs.text), tip: tip)
            }
            guard hasUpstream else { return .commits(commits) }

            let behind = GitInspector.run(tool, ["log", "--no-color", "--format=%H%x09%s", "HEAD..@{u}"], in: url)
            guard behind.ok else { return .failed(behind.failureMessage) }
            let incoming = parseRemoteCommits(behind.text)
            guard let upstream = incoming.first else { return .commits(commits) }
            guard !commits.isEmpty, let rewritten = rewrittenCommit(in: incoming, tool, at: url) else {
                return .behindUpstream(incoming: incoming, outgoing: commits)
            }
            guard rewritten == upstream.id else { return .failed(upstreamAdvancedAfterRewrite) }

            return .rewroteUpstream(outgoing: commits, replaced: incoming, tip: upstream.id)
        }
    }

    // A rewritten commit can sit below newer work on origin. Check every incoming
    // commit against the branch's old tips so pulling cannot undo that rewrite.
    private static func rewrittenCommit(in commits: [GitRemoteCommit],
                                        _ tool: GitInspector.GitTool, at url: URL) -> String? {
        let branch = GitInspector.run(tool, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: url)
        guard branch.ok else { return nil }
        let reflog = GitInspector.run(tool, ["reflog", "show", "--format=%H", "refs/heads/\(branch.trimmedText)", "--"],
                                      in: url)
        guard reflog.ok else { return nil }
        let previousTips = Set(reflog.text.split(whereSeparator: \.isNewline).map(String.init))

        return commits.first { previousTips.contains($0.id) }?.id
    }

    // Where origin's branch of the same name points, or nil when origin has none. A branch
    // with no upstream can still share its name with one on origin, and that branch is
    // what the push would land on. Origin is asked directly, since a remote ref left by an
    // old fetch can name a branch that was deleted long ago. That branch alone is then
    // fetched, so its commits can be listed. When origin cannot be reached, the last fetch
    // is the best guess, and the push itself will say that origin is out of reach.
    private static func originTipForCurrentBranch(_ tool: GitInspector.GitTool, in url: URL) -> String? {
        let branch = GitInspector.run(tool, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: url)
        guard branch.ok, !branch.trimmedText.isEmpty else { return nil }
        let name = branch.trimmedText
        let listed = GitInspector.run(tool, ["ls-remote", "--heads", "origin", "refs/heads/\(name)"], in: url,
                                      timeout: networkTimeout)
        guard listed.ok else {
            let cached = GitInspector.run(tool, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(name)"], in: url)
            return cached.ok && !cached.trimmedText.isEmpty ? cached.trimmedText : nil
        }
        guard let tip = listed.text.split(separator: "\t").first.map(String.init), !tip.isEmpty else { return nil }
        _ = GitInspector.run(tool, ["fetch", "--quiet", "origin", "+refs/heads/\(name):refs/remotes/origin/\(name)"],
                             in: url, timeout: networkTimeout)
        return tip
    }

    static func originMatches(repositoryURL: String, at root: String) async -> Bool {
        guard let tool = await GitInspector.tool() else { return false }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            let origin = GitInspector.run(tool, ["remote", "get-url", "origin"], in: url)
            let push = GitInspector.run(tool, ["remote", "get-url", "--push", "--all", "origin"], in: url)
            let destinations = push.text.split(whereSeparator: \.isNewline)
            return origin.ok && push.ok && destinations.count == 1
                && remoteMatches(origin.trimmedText, repositoryURL: repositoryURL)
                && remoteMatches(String(destinations[0]), repositoryURL: repositoryURL)
        }
    }

    static func remoteMatches(_ remote: String, repositoryURL: String) -> Bool {
        let address: URL?
        if remote.contains("://") {
            address = URL(string: remote)
        } else if let colon = remote.firstIndex(of: ":"), remote[..<colon].contains("@") {
            address = URL(string: "ssh://" + remote[..<colon] + "/" + remote[remote.index(after: colon)...])
        } else {
            return false
        }
        guard let address, let repository = URL(string: repositoryURL), let host = repository.host else { return false }
        var path = address.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if path.hasSuffix(".git") { path.removeLast(4) }
        return address.host?.lowercased() == host.lowercased()
            && path == repository.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    // Keeps a folder out of `git status` without touching the repository's .gitignore.
    // The exclude file is shared by every worktree of a repository.
    static func excludeFromStatus(_ folder: String, at root: String) async {
        guard let tool = await GitInspector.tool() else { return }
        let url = URL(fileURLWithPath: root)
        await GitInspector.offMain {
            let path = GitInspector.run(tool, ["rev-parse", "--git-path", "info/exclude"], in: url)
            guard path.ok else { return }
            let exclude = URL(fileURLWithPath: path.trimmedText, relativeTo: url).standardizedFileURL
            let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
            guard !existing.split(whereSeparator: \.isNewline).contains(where: { $0 == folder }) else { return }
            try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            let line = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + folder + "\n"
            try? (existing + line).write(to: exclude, atomically: true, encoding: .utf8)
        }
    }

    private static func perform(
        at root: String,
        _ work: @escaping @Sendable (GitInspector.GitTool, URL) -> GitInspector.CommandOutput
    ) async -> String? {
        guard let tool = await GitInspector.tool() else {
            return "Could not find git on PATH."
        }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            guard !GitBranches.blocksOtherActions(tool, url) else {
                return "Finish or abort the current operation in Branches before starting another Git action."
            }
            let output = work(tool, url)
            return output.ok ? nil : output.failureMessage
        }
    }

    private static func reconcile(_ tool: GitInspector.GitTool, in url: URL, with target: String,
                                  refusingRewrittenCommits: Bool = false) -> GitPullOutcome {
        guard !GitBranches.blocksOtherActions(tool, url) else {
            return .failed("Finish or abort the current operation in Branches before pulling.")
        }
        let fetch = GitInspector.run(tool, ["fetch", "--quiet", "origin"], in: url,
                                     timeout: networkTimeout)
        guard fetch.ok else { return .failed(fetch.failureMessage) }

        let counts = GitInspector.run(
            tool, ["rev-list", "--count", "--left-right", "HEAD...\(target)"], in: url)
        guard counts.ok else { return .failed(counts.failureMessage) }
        guard let (ahead, behind) = counts.aheadBehind else {
            return .failed("Could not read how far this branch is from \(target).")
        }
        guard behind > 0 else { return .upToDate }
        let incoming = GitInspector.run(
            tool, ["log", "--no-color", "--format=%H%x09%s", "HEAD..\(target)"], in: url)
        guard incoming.ok else { return .failed(incoming.failureMessage) }
        let commits = parseRemoteCommits(incoming.text)
        if refusingRewrittenCommits, ahead > 0,
           let rewritten = rewrittenCommit(in: commits, tool, at: url) {
            guard rewritten == commits.first?.id else { return .failed(upstreamAdvancedAfterRewrite) }
            return .failed("You rewrote these commits, so pulling would bring the old versions back. Push to replace them on origin instead.")
        }

        // With no commits of its own to replay, the branch only has to move forward,
        // and moving forward cannot conflict with anything. --ff-only holds it to that:
        // if something did make a merge necessary, it stops instead of making one.
        if ahead == 0 {
            let merge = GitInspector.run(
                tool, ["merge", "--ff-only", "--autostash", target], in: url)
            guard merge.ok else { return .failed(merge.failureMessage) }
            return stashConflicted(merge)
                ? .updatedWithStashConflict(commits)
                : .updated(commits)
        }

        let rebase = GitInspector.run(tool, ["rebase", "--autostash", target], in: url)
        guard rebase.ok else {
            let files = conflictedFiles(tool, in: url)
            // A rebase that stops leaves the branch halfway onto origin, and this screen
            // has nothing to finish one with. Aborting puts the branch and the stashed
            // work back where they were, so a press that cannot succeed leaves no rebase.
            let restored = GitInspector.run(tool, ["rebase", "--abort"], in: url).ok
            return .failed(conflictReport(files: files, restored: restored, output: rebase))
        }
        return stashConflicted(rebase)
            ? .updatedWithStashConflict(commits)
            : .updated(commits)
    }

    private static func restoreCheckout(_ tool: GitInspector.GitTool, in url: URL,
                                        branch: GitInspector.CommandOutput,
                                        head: GitInspector.CommandOutput,
                                        unlessAlreadyOn target: String) -> Bool {
        if branch.ok {
            let name = branch.trimmedText
            guard name != target else { return true }
            return GitInspector.run(tool, ["switch", name], in: url).ok
        }
        guard head.ok else { return false }
        return GitInspector.run(tool, ["switch", "--detach", head.trimmedText], in: url).ok
    }

    // An autostash that will not go back on cleanly is the one way the reconcile step
    // reports trouble while still exiting zero: the branch did move, and the uncommitted
    // work is now conflict markers in the files.
    private static func stashConflicted(_ output: GitInspector.CommandOutput) -> Bool {
        (output.text + output.errorText).contains("autostash resulted in conflicts")
    }

    private static func conflictedFiles(_ tool: GitInspector.GitTool, in url: URL) -> [String] {
        let output = GitInspector.run(tool, ["diff", "--name-only", "--diff-filter=U"], in: url)
        guard output.ok else { return [] }
        return output.text.split(separator: "\n").map(String.init)
    }

    private static func conflictReport(files: [String], restored: Bool,
                                       output: GitInspector.CommandOutput) -> String {
        guard !files.isEmpty else { return output.failureMessage }
        let shown = files.prefix(5).joined(separator: "\n")
        let rest = files.count > 5 ? "\nand \(files.count - 5) more" : ""
        let tail = restored
            ? "Nothing was changed. To work through it, run git pull --rebase in a terminal."
            : "The rebase could not be undone, so this repository is still in the middle of one."
        return "Your commits and origin's changed the same lines in:\n\(shown)\(rest)\n\n\(tail)"
    }

    private static func parseRemoteCommits(_ text: String) -> [GitRemoteCommit] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            return GitRemoteCommit(id: String(fields[0]), subject: String(fields[1]))
        }
    }
}
