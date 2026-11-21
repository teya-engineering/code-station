import Foundation

// The one way the app starts git. Every part of the app that runs git goes through this
// runner, so they all behave the same way: same lookup, same environment, same pipe
// handling.
enum Git {
    static let outputByteLimit = 8 << 20

    struct Tool: Sendable {
        var path: String
        var searchPath: String
    }

    // ProcessManager owns executable lookup, and a Finder launched app has almost no PATH,
    // so reuse it rather than assuming /usr/bin/git exists.
    static func tool() -> Tool? {
        guard let path = ProcessManager.resolve("git") else { return nil }
        return Tool(path: path, searchPath: ProcessManager.searchPath)
    }

    struct Output: Sendable {
        var text = ""
        var errorText = ""
        var status: Int32 = -1
        var truncated = false
        // The command was stopped for running past its timeout, which says the other end
        // was slow rather than that it said no.
        var timedOut = false

        var ok: Bool { status == 0 }
        // Most answers are one line, and git ends every one of them with a newline.
        var trimmedText: String { text.trimmed }
        var failureMessage: String {
            let trimmed = errorText.trimmed
            return trimmed.isEmpty ? "git exited with code \(status)." : trimmed
        }

        // The two numbers `rev-list --left-right --count ours...theirs` prints: commits
        // only ours has, then commits only theirs has. Every caller names the local side
        // first so the pair reads the same way everywhere. Nil when git could not say.
        var aheadBehind: (ahead: Int, behind: Int)? {
            let counts = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard ok, counts.count == 2 else { return nil }
            return (counts[0], counts[1])
        }
    }

    // `directory` is nil for callers that steer git with `-C` instead: the folder they
    // target may no longer exist, and a missing working directory would keep the
    // process from launching at all.
    static func run(_ tool: Tool, _ arguments: [String], in directory: URL? = nil,
                    timeout: TimeInterval? = nil,
                    captureByteLimit: Int = Git.outputByteLimit,
                    environment extra: [String: String] = [:],
                    outputChunkHandler: (@Sendable (Data) -> Void)? = nil) -> Output {
        var environment = GitEnvironment.nonInteractive(searchPath: tool.searchPath)
        // What a caller adds wins over the shared settings. A snapshot sends
        // GIT_INDEX_FILE, an index of its own to record into, so that recording cannot
        // disturb the one the reader's own staged work lives in.
        environment.merge(extra) { _, override in override }

        var result = Output()
        do {
            let output = try CommandRunner.runBlocking(
                executable: tool.path,
                arguments: arguments,
                currentDirectory: directory,
                environment: environment,
                outputChunkHandler: outputChunkHandler,
                timeout: timeout.map { .seconds($0) },
                outputByteLimit: captureByteLimit
            )
            result.text = output.output
            result.errorText = output.errorOutput
            result.status = output.status
            result.truncated = output.outputTruncated || output.errorOutputTruncated
        } catch {
            result.errorText = error.localizedDescription
            result.timedOut = error as? CommandRunner.RunError == .timedOut
        }
        return result
    }

    // The same run for a caller that stops at the first command git refuses.
    @discardableResult
    static func check(_ tool: Tool, _ arguments: [String], in directory: URL? = nil,
                      environment: [String: String] = [:]) throws(GitFailure) -> Output {
        let output = run(tool, arguments, in: directory, environment: environment)
        guard output.ok else { throw GitFailure(message: output.failureMessage) }
        return output
    }

    // The same run for a command the caller may give up on, such as a fetch the user
    // stops: cancelling the calling task stops git and everything it started.
    static func runCancellable(_ tool: Tool, _ arguments: [String], in directory: URL? = nil,
                               timeout: TimeInterval? = nil) async -> Output {
        var result = Output()
        do {
            let output = try await CommandRunner.run(
                executable: tool.path,
                arguments: arguments,
                currentDirectory: directory,
                environment: GitEnvironment.nonInteractive(searchPath: tool.searchPath),
                timeout: timeout.map { .seconds($0) },
                outputByteLimit: Git.outputByteLimit
            )
            result.text = output.output
            result.errorText = output.errorOutput
            result.status = output.status
            result.truncated = output.outputTruncated || output.errorOutputTruncated
        } catch {
            result.errorText = error.localizedDescription
            result.timedOut = error as? CommandRunner.RunError == .timedOut
        }
        return result
    }

    // Git is slow enough on a big repo to be felt, so it runs on a serial background
    // queue rather than the main thread or an unbounded number of shared workers.
    static func offMain<T: Sendable>(lane: Lane = .background,
                                     _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let queue = lane == .interactive ? interactiveQueue : backgroundQueue
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    // Git commands use blocking process and pipe calls. Serial queues keep those calls
    // from exhausting the shared dispatch pool when many folders need inspection.
    //
    // There are two: reads a person is watching for must not wait behind the periodic
    // sweep over every repository in the sidebar. Both lanes only read, and
    // GIT_OPTIONAL_LOCKS=0 means two lanes in the same repository cannot fight over
    // the index, so running them side by side is safe.
    enum Lane: Sendable { case interactive, background }

    private static let backgroundQueue = DispatchQueue(
        label: "com.teya.code-station.git",
        qos: .userInitiated
    )
    private static let interactiveQueue = DispatchQueue(
        label: "com.teya.code-station.git.interactive",
        qos: .userInitiated
    )

    // MARK: - Shared commands

    // What a caller says when git itself is missing. The two wordings belong to different
    // screens.
    static let notFoundMessage = "Could not find git on PATH."
    static let unavailableMessage = "Git is unavailable."

    // The tree every repository has with nothing in it, which stands in for the last
    // commit in a repository that has none yet.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    // Keeps a repository's own diff drivers from running, so a diff is always git's own
    // output.
    static let plainDiff = ["--no-ext-diff", "--no-textconv"]

    // The branch HEAD is on. Fails without a message on a detached head, which is on none.
    static func currentBranch(_ tool: Tool, in directory: URL) -> Output {
        run(tool, ["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
    }

    // The files a stopped merge, rebase or stash left with conflicts to resolve.
    static func conflictedPaths(_ tool: Tool, in directory: URL) -> [String] {
        let output = run(tool, ["diff", "--name-only", "--diff-filter=U", "-z"], in: directory)
        return output.ok ? output.text.split(separator: "\0").map(String.init) : []
    }
}

// What git said when a command it was asked to run failed.
struct GitFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
