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
    }

    // Long enough for a fetch over a normal connection, short enough that a dead VPN
    // does not hold the sheet's answer hostage.
    private static let fetchTimeout: TimeInterval = 8

    // nil when there is nothing to compare: no git, no repository, or no commits yet.
    static func check(at path: String, fetch: Bool) async -> Report? {
        guard let tool = await tool() else { return nil }
        let url = URL(fileURLWithPath: path)
        return await offMain { inspect(tool: tool, url: url, fetch: fetch) }
    }

    private static func inspect(tool: Tool, url: URL, fetch: Bool) -> Report? {
        guard run(tool, ["rev-parse", "--verify", "--quiet", "HEAD"], in: url).ok else { return nil }

        var report = Report()

        let head = run(tool, ["rev-parse", "--abbrev-ref", "HEAD"], in: url)
        if head.ok {
            let name = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
            report.currentBranch = name == "HEAD" ? nil : name
        }

        if fetch {
            report.fetchAttempted = true
            report.fetched = run(tool, ["fetch", "--quiet", "origin"], in: url,
                                 timeout: fetchTimeout).ok
        }

        report.defaultBranch = defaultBranch(tool, in: url)
        if let name = report.defaultBranch,
           run(tool, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(name)"], in: url).ok {
            report.remoteRef = "origin/\(name)"
        }

        // Without a remote, a checkout that is on the default branch has nothing it
        // could be behind.
        let target = report.remoteRef ?? (report.onDefaultBranch ? nil : report.defaultBranch)
        if let target {
            let count = run(tool, ["rev-list", "--count", "HEAD..\(target)"], in: url)
            if count.ok {
                report.behind = Int(count.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }

        report.lastFetch = lastFetch(tool, in: url)

        let status = run(tool, ["status", "--porcelain=v1", "-z"], in: url)
        report.dirty = status.ok && !status.text.isEmpty

        return report
    }

    // What origin calls its default branch, read from the origin/HEAD ref a clone
    // leaves behind. A repository without one falls back to whichever of main or
    // master exists locally.
    private static func defaultBranch(_ tool: Tool, in url: URL) -> String? {
        let originHead = run(tool, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: url)
        if originHead.ok {
            let name = originHead.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // "origin/main" carries the remote's name up front; the branch itself may
            // hold slashes of its own, so only the first segment goes.
            if let cut = name.range(of: "/") { return String(name[cut.upperBound...]) }
        }
        for candidate in ["main", "master"]
        where run(tool, ["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"], in: url).ok {
            return candidate
        }
        return nil
    }

    // When the remote refs were last brought up to date, taken from the file every
    // fetch rewrites. A repository that has never fetched has no file and no date.
    private static func lastFetch(_ tool: Tool, in url: URL) -> Date? {
        let gitDir = run(tool, ["rev-parse", "--absolute-git-dir"], in: url)
        guard gitDir.ok else { return nil }
        let path = gitDir.text.trimmingCharacters(in: .whitespacesAndNewlines) + "/FETCH_HEAD"
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }

    // MARK: - Running git

    private struct Tool: Sendable {
        let git: String
        let searchPath: String
    }

    // ProcessManager owns executable lookup and is main-actor bound, so the paths are
    // captured before the work hops off the main thread.
    @MainActor private static func tool() -> Tool? {
        guard let git = ProcessManager.resolve("git") else { return nil }
        return Tool(git: git, searchPath: ProcessManager.searchPath)
    }

    private struct Output {
        var text = ""
        var status: Int32 = -1
        var ok: Bool { status == 0 }
    }

    private static func run(_ tool: Tool, _ arguments: [String], in directory: URL,
                            timeout: TimeInterval? = nil) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.git)
        process.currentDirectoryURL = directory
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = tool.searchPath
        // No tty here, so git must never sit waiting for a password.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Output()
        }

        // A fetch can hang on a network that swallows packets rather than refusing
        // them; killing it makes the answer "could not fetch" instead of no answer.
        let killer = timeout.map { limit in
            let item = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: item)
            return item
        }

        // Both pipes are drained at the same time so git can never block on a full one.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer?.cancel()

        return Output(text: String(decoding: data, as: UTF8.self),
                      status: process.terminationStatus)
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
