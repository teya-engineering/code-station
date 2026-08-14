import Foundation

struct GitPushCommit: Identifiable, Sendable, Equatable {
    let id: String
    let subject: String

    var shortID: String { String(id.prefix(8)) }
}

enum GitPushPreview: Sendable, Equatable {
    case commits([GitPushCommit])
    // Origin has commits this branch does not, so it would refuse the push.
    case behindUpstream(Int, [GitPushCommit])
    case failed(String)
}

// What a pull did, in the terms the screen has to report. Up to date and updated are both
// success; they read differently only because one of them has nothing to show.
enum GitPullOutcome: Sendable, Equatable {
    case upToDate
    case updated
    // The branch moved, but the uncommitted work could not be put back cleanly, so it is
    // sitting in the files as conflict markers.
    case updatedWithStashConflict
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

    static func switchBranch(_ branch: String, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            GitInspector.run(tool, ["switch", branch], in: url)
        }
    }

    // Commits everything the changes list shows, staged or not, the way the screen
    // presents it: one working tree, one commit. With `amend` the result replaces the
    // last commit instead of following it.
    static func commitAll(message: String, amend: Bool = false, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            let add = GitInspector.run(tool, ["add", "-A"], in: url)
            guard add.ok else { return add }
            return GitInspector.run(tool, commitArguments(message: message, amend: amend), in: url)
        }
    }

    // Throws away the uncommitted work in one file. A tracked file goes back to the way the
    // last commit has it, in the index and the working tree at once, so a change that was
    // only half staged goes with the rest. A rename is one row on the screen but two paths
    // in git: the new name has to go and the old one has to come back. A file git has never
    // seen has no committed version to restore, so it is moved to the trash, which at least
    // leaves a way back.
    static func discard(_ file: GitChange, at root: String) async -> String? {
        let url = URL(fileURLWithPath: root)
        guard !file.isUntracked else {
            do {
                try FileManager.default.trashItem(
                    at: url.appendingPathComponent(file.path), resultingItemURL: nil)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
        return await perform(at: root) { tool, url in
            GitInspector.run(
                tool, ["restore", "--staged", "--worktree", "--source=HEAD", "--"] + paths, in: url)
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
    // step that follows is whichever of a fast-forward or a rebase cannot go wrong for
    // those numbers. Uncommitted work is stashed around the move either way, since sessions
    // leave trees dirty all the time and a pull otherwise refuses to touch them.
    static func pull(at root: String) async -> GitPullOutcome {
        guard let tool = await GitInspector.tool() else {
            return .failed("Could not find git on PATH.")
        }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            let fetch = GitInspector.run(tool, ["fetch", "--quiet", "origin"], in: url,
                                         timeout: networkTimeout)
            guard fetch.ok else { return .failed(fetch.failureMessage) }

            let counts = GitInspector.run(
                tool, ["rev-list", "--count", "--left-right", "HEAD...@{u}"], in: url)
            guard counts.ok else { return .failed(counts.failureMessage) }
            guard let (ahead, behind) = divergence(counts.text) else {
                return .failed("Could not read how far this branch is from its upstream.")
            }
            guard behind > 0 else { return .upToDate }

            // With no commits of its own to replay, the branch only has to move forward,
            // and moving forward cannot conflict with anything. --ff-only holds it to that:
            // if something did make a merge necessary, it stops instead of making one.
            if ahead == 0 {
                let merge = GitInspector.run(tool, ["merge", "--ff-only", "--autostash", "@{u}"],
                                             in: url)
                guard merge.ok else { return .failed(merge.failureMessage) }
                return stashConflicted(merge) ? .updatedWithStashConflict : .updated
            }

            let rebase = GitInspector.run(tool, ["rebase", "--autostash", "@{u}"], in: url)
            guard rebase.ok else {
                let files = conflictedFiles(tool, in: url)
                // A rebase that stops leaves the branch halfway onto origin, and this
                // screen has nothing to finish one with. Aborting puts the branch and the
                // stashed work back where they were, so a press that cannot succeed at
                // least leaves nothing behind.
                let restored = GitInspector.run(tool, ["rebase", "--abort"], in: url).ok
                return .failed(conflictReport(files: files, restored: restored, output: rebase))
            }
            return stashConflicted(rebase) ? .updatedWithStashConflict : .updated
        }
    }

    // Puts the checkout on `branch` at the remote tip. Switching to the branch it is
    // already on does nothing, so one call covers both a checkout that is elsewhere and
    // one that has merely fallen behind. --ff-only means the update can only move the
    // branch forward or fail: this runs unattended before a session starts, where a
    // surprise merge has no place. The timeout covers the fetch a pull begins with.
    static func updateCheckout(to branch: String, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            let switched = GitInspector.run(tool, ["switch", branch], in: url)
            guard switched.ok else { return switched }
            return GitInspector.run(tool, ["pull", "--ff-only"], in: url, timeout: 30)
        }
    }

    // A branch with no upstream yet, which is every session worktree branch, is published
    // to origin under its own name and starts tracking it.
    static func push(hasUpstream: Bool, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            hasUpstream
                ? GitInspector.run(tool, ["push"], in: url)
                : GitInspector.run(tool, ["push", "-u", "origin", "HEAD"], in: url)
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
            let arguments = hasUpstream
                ? ["log", "--no-color", "--format=%H%x09%s", "@{u}..HEAD"]
                : ["log", "--no-color", "--format=%H%x09%s", "HEAD", "--not", "--remotes=origin"]
            let output = GitInspector.run(tool, arguments, in: url)
            guard output.ok else { return .failed(output.failureMessage) }
            let commits = parsePushCommits(output.text)
            guard hasUpstream else { return .commits(commits) }

            let behind = GitInspector.run(tool, ["rev-list", "--count", "HEAD..@{u}"], in: url)
            let count = behind.ok
                ? Int(behind.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                : 0
            return count > 0 ? .behindUpstream(count, commits) : .commits(commits)
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
            let output = work(tool, url)
            return output.ok ? nil : output.failureMessage
        }
    }

    // --left-right counts both sides of a three-dot range in one read: the commits only
    // HEAD has, then the ones only the upstream has.
    private static func divergence(_ text: String) -> (ahead: Int, behind: Int)? {
        let fields = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard fields.count == 2 else { return nil }
        return (fields[0], fields[1])
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

    private static func parsePushCommits(_ text: String) -> [GitPushCommit] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            return GitPushCommit(id: String(fields[0]), subject: String(fields[1]))
        }
    }
}
