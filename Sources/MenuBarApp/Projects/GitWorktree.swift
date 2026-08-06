import Foundation

// Creates and removes the git worktrees a session can run in. Each worktree is an
// isolated checkout on its own branch, kept in the app's config directory, so several
// sessions of one project can edit files at the same time without racing each other.
enum GitWorktree {
    struct Created {
        let path: String
        let branch: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let folder = "worktrees"

    // Reading where the checkouts go does not create the folder, so the new session sheet
    // can show the path it would use without leaving anything behind if it is cancelled.
    static var baseDirectory: URL {
        AppPaths.support.appendingPathComponent(folder)
    }

    // What adding a worktree for this session would produce. The sheet that offers the
    // choice shows this, so it has to be the same answer `add` acts on rather than a
    // description of it.
    //
    // The session id makes the folder and branch unique; the project name keeps them
    // recognisable when browsing the worktrees directory by hand.
    static func plan(projectName: String, sessionID: UUID) -> Created {
        let suffix = String(sessionID.uuidString.prefix(8)).lowercased()
        let name = String(projectName.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return Created(path: baseDirectory.appendingPathComponent("\(name)-\(suffix)").path,
                       branch: "conductor/\(suffix)")
    }

    static func add(projectPath: String, projectName: String, sessionID: UUID) async throws -> Created {
        guard let tool = await tool() else {
            throw Failure(message: "Could not find git on PATH.")
        }
        let planned = plan(projectName: projectName, sessionID: sessionID)

        let outcome: Result<Created, Failure> = await offMain {
            // Kept out of backups: a worktree can be recreated from the repository it came
            // from, and copying every checkout into Time Machine is not worth the room.
            _ = AppPaths.directory(folder, backedUp: false)
            let result = run(tool, ["-C", projectPath, "worktree", "add", planned.path, "-b", planned.branch])
            guard result.status == 0 else {
                return .failure(Failure(message: result.stderr.isEmpty
                    ? "git worktree add exited with code \(result.status)."
                    : result.stderr))
            }
            return .success(planned)
        }
        return try outcome.get()
    }

    // Best effort teardown: the worktree folder goes even if git cannot remove it
    // (a deleted project folder, for example), and the branch is only deleted when
    // git considers that safe, so committed work is never thrown away.
    static func remove(worktreePath: String, projectPath: String, branch: String?) async {
        let tool = await tool()
        await offMain {
            if let tool {
                _ = run(tool, ["-C", projectPath, "worktree", "remove", "--force", worktreePath])
                if let branch { _ = run(tool, ["-C", projectPath, "branch", "-d", branch]) }
            }
            if FileManager.default.fileExists(atPath: worktreePath) {
                try? FileManager.default.removeItem(atPath: worktreePath)
            }
            if let tool { _ = run(tool, ["-C", projectPath, "worktree", "prune"]) }
        }
    }

    // MARK: - Running git

    private struct Tool: Sendable {
        let git: String
        let searchPath: String
    }

    // ProcessManager owns executable lookup and is main-actor bound, so the paths are
    // captured here before the work hops off the main thread.
    @MainActor private static func tool() -> Tool? {
        guard let git = ProcessManager.resolve("git") else { return nil }
        return Tool(git: git, searchPath: ProcessManager.searchPath)
    }

    private static func run(_ tool: Tool, _ arguments: [String]) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.git)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = tool.searchPath
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        // Both pipes are drained at the same time so git can never block on a full one.
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        _ = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        let stderr = String(decoding: box.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, stderr)
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        var value: Data {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

// The branch a folder has checked out, read straight from .git/HEAD instead of by running
// git: sidebar rows redraw often and none of them are worth a process. The answer is held
// for a moment so a burst of redraws costs a single read.
@MainActor
enum GitHead {
    private static var cache: [String: (branch: String?, readAt: Date)] = [:]
    private static let ttl: TimeInterval = 5

    static func branch(at path: String) -> String? {
        if let hit = cache[path], Date().timeIntervalSince(hit.readAt) < ttl { return hit.branch }
        let branch = read(path)
        cache[path] = (branch, Date())
        return branch
    }

    // A detached head holds a sha rather than a ref, which is nothing a row can use.
    private static func read(_ path: String) -> String? {
        guard let head = try? String(contentsOfFile: path + "/.git/HEAD", encoding: .utf8) else { return nil }
        let reference = "ref: refs/heads/"
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(reference) else { return nil }
        return String(line.dropFirst(reference.count))
    }
}
