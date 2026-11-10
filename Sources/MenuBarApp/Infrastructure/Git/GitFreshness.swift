import Foundation

// How the project folder's checkout relates to the branch new work should start from.
// A new session forks from whatever the folder has checked out, so the sheet that
// creates one asks here whether that base is the default branch at its latest revision.
// Everything read here only reads; the one exception is `git fetch`, which touches
// nothing but the remote tracking refs.
enum GitFreshness {

    struct Report: Sendable, Equatable {
        // nil when HEAD is detached.
        var currentBranch: String?
        // The branch new work is expected to start from: what origin calls its default,
        // or a local main or master when there is no remote to ask.
        var defaultBranch: String?
        // "origin/main" when the remote tracking ref exists. Comparisons prefer it over
        // the local default branch, which can trail the remote just as a feature branch
        // can.
        var remoteRef: String?
        // Commits the comparison target has that HEAD does not.
        var behind = 0
        // Commits that exist on only one side of the local default branch and its remote.
        // These are separate from `behind`, which follows HEAD and may describe a feature
        // branch instead of the branch an update would switch to.
        var defaultBranchAhead = 0
        var defaultBranchBehind = 0
        // Whether the fetch that makes `behind` trustworthy was tried, and whether it
        // worked. Without a fetch the remote refs are only as fresh as the last one.
        var fetchAttempted = false
        var fetched = false
        var lastFetch: Date?
        // How long the fetch was allowed to wait for origin, and how it failed: by
        // running out of that time, or by origin saying no. Only a timeout is worth
        // retrying with a longer wait.
        var fetchWait: TimeInterval?
        var fetchTimedOut = false
        // What git said when origin said no.
        var fetchFailure: String?
        // The folder holds work git does not have, which no new worktree would carry.
        var dirty = false

        // A repository with no idea of a default branch leaves nothing for the checkout
        // to differ from, so it reads as fine.
        var onDefaultBranch: Bool { defaultBranch == nil || currentBranch == defaultBranch }
        var fetchFailed: Bool { fetchAttempted && !fetched }
        var isStale: Bool { !onDefaultBranch || behind > 0 }
        var defaultBranchHasDiverged: Bool {
            defaultBranchAhead > 0 && defaultBranchBehind > 0
        }
        // A clean checkout can be put on the default branch with the remote changes: a
        // switch when it sits somewhere else, a fast-forward when it only trails, or an
        // explicit rebase when both sides have commits. A conflicting rebase is aborted.
        // A remote ref is what makes "the latest revision" mean anything, so without one
        // there is nothing to offer.
        var canUpdateCheckout: Bool { isStale && !dirty && remoteRef != nil }
        // A dirty folder cannot be updated as a whole, but its default branch can still
        // be moved up when it only trails the remote: that move needs no stash.
        var canFastForwardDefaultBranch: Bool {
            dirty && defaultBranch != nil && remoteRef != nil
                && defaultBranchBehind > 0 && defaultBranchAhead == 0
        }

        var divergenceExplanation: String? {
            guard defaultBranchHasDiverged, let branch = defaultBranch, let remote = remoteRef else {
                return nil
            }
            return "\(branch) and \(remote) have diverged: \(branch) has "
                + counted(defaultBranchAhead, "local commit") + " and \(remote) has "
                + counted(defaultBranchBehind, "remote commit") + "."
        }

        // The report as a short sentence or two: the wrong branch, the missing commits,
        // and when the fetch failed, how old the answer is. Reads as reassurance when
        // there is nothing wrong, so it can caption a good report too.
        var explanation: String {
            var sentences: [String] = []
            if !onDefaultBranch, let expected = defaultBranch {
                let place = currentBranch.map { "on \($0)" } ?? "on a detached HEAD"
                sentences.append("The checkout is \(place), not \(expected).")
            }
            if let divergenceExplanation {
                sentences.append(divergenceExplanation)
            } else if behind > 0, let target = remoteRef ?? defaultBranch {
                let subject = sentences.isEmpty ? (currentBranch ?? "The checkout") : "It"
                sentences.append("\(subject) is \(counted(behind, "commit")) behind \(target).")
            }
            if sentences.isEmpty {
                sentences.append(defaultBranch.map { "The checkout is \($0) at its latest revision." }
                                 ?? "There is no default branch to compare against.")
            }
            if let fetchProblem { sentences.append(fetchProblem) }
            return sentences.joined(separator: " ")
        }

        // Why the answer may be old, naming the wait when origin was only slow.
        var fetchProblem: String? {
            guard fetchFailed else { return nil }
            let cause: String
            if fetchTimedOut, let fetchWait {
                cause = "Origin did not answer within \(counted(Int(fetchWait), "second"))"
            } else if fetchFailure != nil {
                cause = "Origin refused the fetch"
            } else {
                cause = "Origin could not be reached"
            }
            return lastFetch.map {
                "\(cause), so this is as of the last fetch, \($0.formatted(.relative(presentation: .named)))."
            } ?? "\(cause), so this may be out of date."
        }

        // What the user can do about a failed fetch. A refusal will not go away with a
        // longer wait, so it points at the cause instead.
        var fetchAdvice: String? {
            guard fetchFailed else { return nil }
            if fetchTimedOut {
                return fetchWait.map { $0 > GitFreshness.fetchWaits[0] } == true
                    ? "Still no answer. Check that you are on the VPN, or start from what is already here."
                    : "A slow VPN or a large repository can take longer than that."
            }
            guard let fetchFailure else { return nil }
            return fetchFailure.contains("Permission denied (publickey)")
                ? "Waiting longer will not help here. Check that your SSH key is loaded, then try again."
                : "Waiting longer will not help here. Fix what git reports below, then try again."
        }

        // How long a retry may wait. A timeout earns the next step up the ladder, and the
        // last step is the ceiling. Any other failure is retried with the same wait,
        // since more time would not change the answer.
        var retryWait: TimeInterval {
            let current = fetchWait ?? GitFreshness.fetchWaits[0]
            guard fetchTimedOut else { return current }
            return GitFreshness.fetchWaits.first { $0 > current } ?? GitFreshness.fetchWaits.last ?? current
        }
    }

    // How long a fetch may wait for origin. The first, automatic pass is long enough for
    // a normal connection and short enough that a dead VPN does not hold the sheet's
    // answer hostage. A retry the user asks for climbs to the next step.
    static let fetchWaits: [TimeInterval] = [8, 30, 60]

    // A check can spend seconds waiting on the network, so it runs on its own concurrent
    // queue rather than the shared serial git lane, which a fetch would otherwise block
    // for every other read. The queue does not bound its own width: `checkAll` caps how
    // many checks it submits at once, and a lone `check` adds at most one more.
    private static let queue = DispatchQueue(label: "com.teya.code-station.git.freshness",
                                             qos: .userInitiated, attributes: .concurrent)

    // Each in-flight check holds a thread while git blocks on the network, so only a
    // few run side by side. More would gain little: they share one connection and disk.
    private static let maxConcurrentChecks = 3

    // nil when there is nothing to compare: no git, no repository, or no commits yet,
    // and when the calling task is cancelled, which also stops a fetch in flight.
    static func check(at path: String, fetch: Bool,
                      timeout: TimeInterval = fetchWaits[0]) async -> Report? {
        guard let tool = await GitInspector.tool() else { return nil }
        let url = URL(fileURLWithPath: path)
        var fetched: (output: GitInspector.CommandOutput, wait: TimeInterval)?
        if fetch {
            let output = await GitInspector.runCancellable(tool, ["fetch", "--quiet", "origin"],
                                                           in: url, timeout: timeout)
            if Task.isCancelled { return nil }
            fetched = (output, timeout)
        }
        return await withCheckedContinuation { [fetched] continuation in
            queue.async {
                continuation.resume(returning: inspect(tool: tool, url: url, fetch: fetched))
            }
        }
    }

    // Reads a few repositories side by side, so the wait is closer to the slowest of
    // them than the sum. Each report lands through the callback as soon as it is ready;
    // the screens showing many repositories fill in one row at a time instead of all
    // at once.
    static func checkAll(_ repositories: [(id: UUID, path: String)], fetch: Bool,
                         onReport: @escaping @MainActor (UUID, Report) -> Void) async {
        await withTaskGroup(of: (UUID, Report?).self) { group in
            var pending = repositories.makeIterator()
            let addNext = { (group: inout TaskGroup<(UUID, Report?)>) in
                guard let repository = pending.next() else { return }
                group.addTask { [id = repository.id, path = repository.path] in
                    (id, await check(at: path, fetch: fetch))
                }
            }
            for _ in 0..<maxConcurrentChecks { addNext(&group) }
            for await (id, report) in group {
                addNext(&group)
                guard let report else { continue }
                await onReport(id, report)
            }
        }
    }

    private static func inspect(tool: GitInspector.GitTool, url: URL,
                                fetch: (output: GitInspector.CommandOutput, wait: TimeInterval)?) -> Report? {
        guard GitInspector.run(tool, ["rev-parse", "--verify", "--quiet", "HEAD"], in: url).ok else { return nil }

        var report = Report()

        let head = GitInspector.run(tool, ["rev-parse", "--abbrev-ref", "HEAD"], in: url)
        if head.ok {
            let name = head.trimmedText
            report.currentBranch = name == "HEAD" ? nil : name
        }

        if let fetch {
            report.fetchAttempted = true
            report.fetched = fetch.output.ok
            report.fetchWait = fetch.wait
            if !fetch.output.ok {
                report.fetchTimedOut = fetch.output.timedOut
                report.fetchFailure = fetch.output.timedOut ? nil : fetch.output.failureMessage
            }
        }

        report.defaultBranch = defaultBranch(tool, in: url)
        if let name = report.defaultBranch,
           GitInspector.run(tool, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(name)"], in: url).ok {
            report.remoteRef = "origin/\(name)"
        }

        if let branch = report.defaultBranch, let remote = report.remoteRef {
            let counts = GitInspector.run(
                tool,
                ["rev-list", "--count", "--left-right", "refs/heads/\(branch)...\(remote)"],
                in: url)
            if let drift = counts.aheadBehind {
                report.defaultBranchAhead = drift.ahead
                report.defaultBranchBehind = drift.behind
            }
        }

        // Without a remote, a checkout that is on the default branch has nothing it
        // could be behind.
        let target = report.remoteRef ?? (report.onDefaultBranch ? nil : report.defaultBranch)
        if let target {
            let count = GitInspector.run(tool, ["rev-list", "--count", "HEAD..\(target)"], in: url)
            if count.ok {
                report.behind = Int(count.trimmedText) ?? 0
            }
        }

        report.lastFetch = lastFetch(tool, in: url)

        let status = GitInspector.run(tool, ["status", "--porcelain=v1", "-z"], in: url)
        report.dirty = status.ok && !status.text.isEmpty

        return report
    }

    // What origin calls its default branch, read from the origin/HEAD ref a clone
    // leaves behind. A repository without one falls back to whichever of main or
    // master exists locally.
    private static func defaultBranch(_ tool: GitInspector.GitTool, in url: URL) -> String? {
        let originHead = GitInspector.run(tool, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: url)
        if originHead.ok {
            let name = originHead.trimmedText
            // "origin/main" carries the remote's name up front; the branch itself may
            // hold slashes of its own, so only the first segment goes.
            if let cut = name.range(of: "/") { return String(name[cut.upperBound...]) }
        }
        for candidate in ["main", "master"]
        where GitInspector.run(tool, ["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"], in: url).ok {
            return candidate
        }
        return nil
    }

    // When the remote refs were last brought up to date, taken from the file every
    // fetch rewrites. A repository that has never fetched has no file and no date.
    private static func lastFetch(_ tool: GitInspector.GitTool, in url: URL) -> Date? {
        let gitDir = GitInspector.run(tool, ["rev-parse", "--absolute-git-dir"], in: url)
        guard gitDir.ok else { return nil }
        let path = gitDir.trimmedText + "/FETCH_HEAD"
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}
