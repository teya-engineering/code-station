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
        // Whether the fetch that makes `behind` trustworthy was tried, and whether it
        // worked. Without a fetch the remote refs are only as fresh as the last one.
        var fetchAttempted = false
        var fetched = false
        var lastFetch: Date?
        // The folder holds work git does not have, which no new worktree would carry.
        var dirty = false

        // A repository with no idea of a default branch leaves nothing for the checkout
        // to differ from, so it reads as fine.
        var onDefaultBranch: Bool { defaultBranch == nil || currentBranch == defaultBranch }
        var isStale: Bool { !onDefaultBranch || behind > 0 }
        // A clean checkout can be put on the default branch at the remote tip: a switch
        // when it sits somewhere else, a fast-forward pull when it trails the remote,
        // and both when it is on another branch that has fallen behind too. Uncommitted
        // work is the user's to sort out first, since either move would carry it along.
        // A remote ref is what makes "the latest revision" mean anything, so without one
        // there is nothing to offer.
        var canUpdateCheckout: Bool { isStale && !dirty && remoteRef != nil }

        // The report as a short sentence or two: the wrong branch, the missing commits,
        // and when the fetch failed, how old the answer is. Reads as reassurance when
        // there is nothing wrong, so it can caption a good report too.
        var explanation: String {
            var sentences: [String] = []
            if !onDefaultBranch, let expected = defaultBranch {
                let place = currentBranch.map { "on \($0)" } ?? "on a detached HEAD"
                sentences.append("The checkout is \(place), not \(expected).")
            }
            if behind > 0, let target = remoteRef ?? defaultBranch {
                let subject = sentences.isEmpty ? (currentBranch ?? "The checkout") : "It"
                sentences.append("\(subject) is \(behind) commit\(behind == 1 ? "" : "s") behind \(target).")
            }
            if sentences.isEmpty {
                sentences.append(defaultBranch.map { "The checkout is \($0) at its latest revision." }
                                 ?? "There is no default branch to compare against.")
            }
            if fetchAttempted && !fetched {
                sentences.append(lastFetch.map {
                    "Origin could not be reached, so this is as of the last fetch, \($0.formatted(.relative(presentation: .named)))."
                } ?? "Origin could not be reached, so this may be out of date.")
            }
            return sentences.joined(separator: " ")
        }
    }

    // Long enough for a fetch over a normal connection, short enough that a dead VPN
    // does not hold the sheet's answer hostage.
    private static let fetchTimeout: TimeInterval = 8

    // A check can spend seconds waiting on the network, so it runs on its own concurrent
    // queue rather than the shared serial git lane, which a fetch would otherwise block
    // for every other read. The queue does not bound its own width: `checkAll` caps how
    // many checks it submits at once, and a lone `check` adds at most one more.
    private static let queue = DispatchQueue(label: "com.teya.code-station.git.freshness",
                                             qos: .userInitiated, attributes: .concurrent)

    // Each in-flight check holds a thread while git blocks on the network, so only a
    // few run side by side. More would gain little: they share one connection and disk.
    private static let maxConcurrentChecks = 3

    // nil when there is nothing to compare: no git, no repository, or no commits yet.
    static func check(at path: String, fetch: Bool) async -> Report? {
        guard let tool = await GitInspector.tool() else { return nil }
        let url = URL(fileURLWithPath: path)
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: inspect(tool: tool, url: url, fetch: fetch))
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

    private static func inspect(tool: GitInspector.GitTool, url: URL, fetch: Bool) -> Report? {
        guard GitInspector.run(tool, ["rev-parse", "--verify", "--quiet", "HEAD"], in: url).ok else { return nil }

        var report = Report()

        let head = GitInspector.run(tool, ["rev-parse", "--abbrev-ref", "HEAD"], in: url)
        if head.ok {
            let name = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
            report.currentBranch = name == "HEAD" ? nil : name
        }

        if fetch {
            report.fetchAttempted = true
            report.fetched = GitInspector.run(tool, ["fetch", "--quiet", "origin"], in: url,
                                              timeout: fetchTimeout).ok
        }

        report.defaultBranch = defaultBranch(tool, in: url)
        if let name = report.defaultBranch,
           GitInspector.run(tool, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(name)"], in: url).ok {
            report.remoteRef = "origin/\(name)"
        }

        // Without a remote, a checkout that is on the default branch has nothing it
        // could be behind.
        let target = report.remoteRef ?? (report.onDefaultBranch ? nil : report.defaultBranch)
        if let target {
            let count = GitInspector.run(tool, ["rev-list", "--count", "HEAD..\(target)"], in: url)
            if count.ok {
                report.behind = Int(count.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
            let name = originHead.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let path = gitDir.text.trimmingCharacters(in: .whitespacesAndNewlines) + "/FETCH_HEAD"
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}
