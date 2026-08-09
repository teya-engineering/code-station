import Foundation

// Creates and removes the git worktrees a session can run in. Each worktree is an
// isolated checkout on its own branch, kept in the app's config directory, so several
// sessions of one project can edit files at the same time without racing each other.
enum GitWorktree {
    struct Created: Sendable {
        let path: String
        let branch: String
    }

    struct Failure: Error, Sendable {
        let message: String
    }

    private static let folder = "worktrees"
    private static let cleanupCommandTimeout: TimeInterval = 30

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
        let name = safeName(projectName)
        return Created(path: baseDirectory.appendingPathComponent("\(name)-\(suffix)").path,
                       branch: "conductor/\(suffix)")
    }

    // Workspace checkouts share a session folder. The project id suffix prevents two
    // repositories with the same display name from choosing the same path.
    static func plan(projectName: String, projectID: UUID, sessionID: UUID) -> Created {
        let sessionSuffix = String(sessionID.uuidString.prefix(8)).lowercased()
        let projectSuffix = String(projectID.uuidString.prefix(8)).lowercased()
        let folder = baseDirectory.appendingPathComponent(sessionSuffix, isDirectory: true)
        return Created(path: folder.appendingPathComponent("\(safeName(projectName))-\(projectSuffix)").path,
                       branch: "conductor/\(sessionSuffix)")
    }

    private static func safeName(_ projectName: String) -> String {
        String(projectName.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    // `base` is the ref the worktree's branch forks from; without one it forks from
    // whatever the project folder has checked out. Naming a ref is what lets a session
    // start from the remote tip while the user's own checkout stays as it is.
    static func add(projectPath: String, projectName: String, sessionID: UUID,
                    from base: String? = nil) async -> Result<Created, Failure> {
        await add(projectPath: projectPath,
                  planned: plan(projectName: projectName, sessionID: sessionID),
                  from: base)
    }

    static func add(projectPath: String, projectName: String, projectID: UUID,
                    sessionID: UUID, from base: String? = nil) async -> Result<Created, Failure> {
        await add(projectPath: projectPath,
                  planned: plan(projectName: projectName, projectID: projectID,
                                sessionID: sessionID),
                  from: base)
    }

    private static func add(projectPath: String, planned: Created,
                            from base: String?) async -> Result<Created, Failure> {
        guard let tool = await GitInspector.tool() else {
            return .failure(Failure(message: "Could not find git on PATH."))
        }

        return await GitInspector.offMain {
            // Kept out of backups: a worktree can be recreated from the repository it came
            // from, and copying every checkout into Time Machine is not worth the room.
            _ = AppPaths.directory(folder, backedUp: false)
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: planned.path).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            var arguments = ["-C", projectPath, "worktree", "add", planned.path, "-b", planned.branch]
            if let base { arguments.append(base) }
            let result = GitInspector.run(tool, arguments)
            guard result.ok else {
                let stderr = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(Failure(message: stderr.isEmpty
                    ? "git worktree add exited with code \(result.status)."
                    : stderr))
            }
            return .success(planned)
        }
    }

    // The checkout folder must be gone before its session record is dropped. Git may no
    // longer know about the checkout, so filesystem removal remains the final fallback.
    // Branch deletion and pruning are best effort because a branch with unmerged commits
    // is deliberately kept.
    static func remove(worktreePath: String, projectPath: String?, branch: String?) async
        -> Result<Void, Failure> {
        let tool = await GitInspector.tool()
        return await GitInspector.offMain {
            if let tool, let projectPath {
                _ = GitInspector.run(
                    tool,
                    ["-C", projectPath, "worktree", "remove", "--force", worktreePath],
                    timeout: cleanupCommandTimeout)
                if let branch {
                    _ = GitInspector.run(
                        tool, ["-C", projectPath, "branch", "-d", branch],
                        timeout: cleanupCommandTimeout)
                }
            }
            if FileManager.default.fileExists(atPath: worktreePath) {
                do {
                    try FileManager.default.removeItem(atPath: worktreePath)
                } catch {
                    return .failure(Failure(
                        message: "Could not remove \(worktreePath.abbreviatedPath): \(error.localizedDescription)"))
                }
            }
            let parent = URL(fileURLWithPath: worktreePath).deletingLastPathComponent()
            if parent.deletingLastPathComponent().standardizedFileURL == baseDirectory.standardizedFileURL,
               (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: parent)
            }
            if let tool, let projectPath {
                _ = GitInspector.run(
                    tool, ["-C", projectPath, "worktree", "prune"],
                    timeout: cleanupCommandTimeout)
            }
            return .success(())
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
