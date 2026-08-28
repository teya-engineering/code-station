import Foundation

// Creates and removes the git worktrees a session can run in. Each worktree is an
// isolated checkout on its own branch, kept in the app's worktree directory, so several
// sessions of one project can edit files at the same time without racing each other.
enum GitWorktree {
    struct Created: Sendable {
        let path: String
        let branch: String
    }

    struct Failure: Error, Sendable {
        let message: String
    }

    struct Orphaned: Identifiable, Sendable, Equatable {
        let path: String
        let branch: String?
        let allocatedBytes: Int64

        var id: String { path }
    }

    private static let folder = "worktrees"
    private static let cleanupCommandTimeout: TimeInterval = 30

    private static var storageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".code-station", isDirectory: true)
    }

    // Reading where the checkouts go does not create the folder, so the new session sheet
    // can show the path it would use without leaving anything behind if it is cancelled.
    static var baseDirectory: URL {
        storageDirectory.appendingPathComponent(folder, isDirectory: true)
    }

    // Session records hold their exact checkout paths and can outlive the root used for new
    // sessions. Every supported root stays owned so those sessions can be restored and
    // cleaned up without moving a live worktree underneath an agent or terminal.
    static var legacyBaseDirectory: URL {
        AppPaths.support.appendingPathComponent(folder, isDirectory: true)
    }

    private static var ownedBaseDirectories: [URL] { [baseDirectory, legacyBaseDirectory] }

    static func owns(_ path: String) -> Bool {
        ownedBaseDirectory(containing: path) != nil
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
                       branch: "code-station/\(suffix)")
    }

    // Workspace checkouts share a session folder. The project id suffix prevents two
    // repositories with the same display name from choosing the same path.
    static func plan(projectName: String, projectID: UUID, sessionID: UUID) -> Created {
        let sessionSuffix = String(sessionID.uuidString.prefix(8)).lowercased()
        let projectSuffix = String(projectID.uuidString.prefix(8)).lowercased()
        let folder = baseDirectory.appendingPathComponent(sessionSuffix, isDirectory: true)
        return Created(path: folder.appendingPathComponent("\(safeName(projectName))-\(projectSuffix)").path,
                       branch: "code-station/\(sessionSuffix)")
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

    // Git is the source of truth for which checkouts belong to a repository. Limiting
    // the result to the app's worktree folder prevents a checkout made by the user from
    // ever appearing as app cleanup, even when no session knows about it.
    static func orphaned(projectPath: String, excluding activePaths: Set<String>) async
        -> [Orphaned] {
        guard let tool = await GitInspector.tool() else { return [] }
        let active = Set(activePaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })

        return await GitInspector.offMain {
            let output = GitInspector.run(
                tool, ["-C", projectPath, "worktree", "list", "--porcelain", "-z"])
            guard output.ok else { return [] }

            return parseWorktreeList(output.text).compactMap { checkout in
                let path = URL(fileURLWithPath: checkout.path).standardizedFileURL.path
                guard owns(path), !active.contains(path),
                      FileManager.default.fileExists(atPath: path) else { return nil }
                return Orphaned(path: path,
                                branch: checkout.branch,
                                allocatedBytes: allocatedSize(of: path))
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    static func parseWorktreeList(_ output: String) -> [(path: String, branch: String?)] {
        var worktrees: [(path: String, branch: String?)] = []
        var path: String?
        var branch: String?

        func finish() {
            guard let path else { return }
            worktrees.append((path, branch))
        }

        for field in output.components(separatedBy: "\0") {
            if field.isEmpty {
                finish()
                path = nil
                branch = nil
            } else if field.hasPrefix("worktree ") {
                if path != nil { finish() }
                path = String(field.dropFirst("worktree ".count))
                branch = nil
            } else if field.hasPrefix("branch refs/heads/") {
                branch = String(field.dropFirst("branch refs/heads/".count))
            }
        }
        if path != nil { finish() }
        return worktrees
    }

    private static func allocatedSize(of path: String) -> Int64 {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey
        ]
        guard let files = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }

        var bytes: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return bytes
    }

    private static func add(projectPath: String, planned: Created,
                            from base: String?) async -> Result<Created, Failure> {
        guard let tool = await GitInspector.tool() else {
            return .failure(Failure(message: "Could not find git on PATH."))
        }

        return await GitInspector.offMain {
            prepareContainingFolder(for: planned.path)
            var arguments = ["-C", projectPath, "worktree", "add", planned.path, "-b", planned.branch]
            if let base { arguments.append(base) }
            return worktreeAdd(tool, arguments).map { _ in planned }
        }
    }

    // Kept out of backups: a worktree can be recreated from the repository it came from,
    // and copying every checkout into Time Machine is not worth the room.
    private static func prepareContainingFolder(for path: String) {
        if let base = ownedBaseDirectory(containing: path) {
            _ = AppPaths.directory(at: base, backedUp: false)
        }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }

    private static func ownedBaseDirectory(containing path: String) -> URL? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return ownedBaseDirectories.first { base in
            let root = base.standardizedFileURL.path
            return candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    private static func worktreeAdd(_ tool: GitInspector.GitTool,
                                    _ arguments: [String]) -> Result<Void, Failure> {
        let result = GitInspector.run(tool, arguments)
        return result.ok ? .success(()) : .failure(Failure(message: result.failureMessage))
    }

    // Where a rebuilt checkout would get its commits. Read before anything is changed so a
    // confirmation can state the outcome, and handed back to `restore` so what runs is what
    // was promised rather than a second lookup that could answer differently.
    enum RestoreSource: Sendable, Equatable {
        case localBranch
        case remoteBranch(String)
        // Nothing of the branch is left anywhere, so the checkout starts from whatever the
        // project has, and work committed only on that branch does not come back.
        case projectHead

        var keepsCommits: Bool { self != .projectHead }
    }

    // Nil where the question cannot be asked at all - no git, no project folder. That is
    // not the same answer as "the branch is gone" and must not be shown as one.
    static func restoreSource(of branch: String, projectPath: String) async -> RestoreSource? {
        guard let tool = await GitInspector.tool(),
              FileManager.default.fileExists(atPath: projectPath) else { return nil }
        return await GitInspector.offMain { source(of: branch, in: projectPath, tool: tool) }
    }

    private static func source(of branch: String, in projectPath: String,
                               tool: GitInspector.GitTool) -> RestoreSource {
        // Spelled out with its refs/heads prefix, since a bare name matches a tag just as
        // readily: checking a tag out would leave a detached head on a checkout whose
        // session records a branch.
        if GitInspector.run(tool, ["-C", projectPath, "rev-parse", "--verify", "--quiet",
                                   "refs/heads/" + branch]).ok {
            return .localBranch
        }
        let listed = GitInspector.run(tool, ["-C", projectPath, "for-each-ref",
                                             "--format=%(refname)", "refs/remotes/*/" + branch])
        let refs = listed.text
            .components(separatedBy: "\n")
            .map(\.trimmed)
            .filter { !$0.isEmpty }
        // Origin wins when several remotes carry the name, rather than whichever git listed
        // first. Naming the ref also keeps git from guessing, which it gives up on in
        // exactly that case - and giving up there would fork from the project instead and
        // lose the commits quietly.
        let preferred = refs.first { $0.hasPrefix("refs/remotes/origin/") } ?? refs.first
        return preferred.map(RestoreSource.remoteBranch) ?? .projectHead
    }

    // Builds a checkout again at the path a session already records, for a folder moved or
    // deleted outside the app. `plan` derives that path and branch from the session id, so
    // what comes back is what the session recorded when it was made and nothing saved has
    // to change for the session to work again.
    //
    // This cannot go through `add`: that one always passes `-b`, which fails on a branch
    // that outlived its folder, and it names no start point, which would fork from the
    // project while the work sits on a remote.
    static func restore(worktreePath: String, branch: String, projectPath: String,
                        from source: RestoreSource) async -> Result<Void, Failure> {
        guard let tool = await GitInspector.tool() else {
            return .failure(Failure(message: "Could not find git on PATH."))
        }
        guard FileManager.default.fileExists(atPath: projectPath) else {
            return .failure(Failure(
                message: "The project folder at \(projectPath.abbreviatedPath) is missing too, "
                    + "so there is nothing to build the checkout from."))
        }

        return await GitInspector.offMain {
            // `--force` is what clears the registration git keeps when only the folder was
            // deleted, but it also waives the rule that a branch is checked out in one place
            // at a time. That one is not ours to waive - commits in either of two checkouts
            // of a branch make the other look out of date - so it is asked here instead.
            if let existing = liveCheckout(of: branch, in: projectPath, tool: tool),
               existing != URL(fileURLWithPath: worktreePath).standardizedFileURL.path {
                return .failure(Failure(
                    message: "\(branch) is already checked out at \(existing.abbreviatedPath). "
                        + "Two checkouts of one branch make each other look out of date."))
            }

            prepareContainingFolder(for: worktreePath)
            // `--force` rather than `git worktree prune` to clear that stale registration:
            // prune drops every registration whose folder is missing, so rebuilding one
            // session's checkout would deregister another session's whose disk is merely
            // unplugged, and that one is an orphan the moment it comes back.
            var arguments = ["-C", projectPath, "worktree", "add", "--force", worktreePath]
            switch source {
            case .localBranch:
                arguments.append(branch)
            case .remoteBranch(let ref):
                arguments.append(contentsOf: ["-b", branch, ref])
            case .projectHead:
                arguments.append(contentsOf: ["-b", branch])
            }
            return worktreeAdd(tool, arguments)
        }
    }

    // The folder a branch is checked out in, when one is still there. A registration whose
    // folder has gone does not count: that is the one being rebuilt.
    private static func liveCheckout(of branch: String, in projectPath: String,
                                     tool: GitInspector.GitTool) -> String? {
        let listed = GitInspector.run(
            tool, ["-C", projectPath, "worktree", "list", "--porcelain", "-z"])
        guard listed.ok else { return nil }
        return parseWorktreeList(listed.text)
            .first { $0.branch == branch && FileManager.default.fileExists(atPath: $0.path) }
            .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
    }

    // The checkout folder must be gone before its session record is dropped. Git may no
    // longer know about the checkout, so filesystem removal remains the final fallback.
    // Branch deletion and pruning are best effort because a branch with unmerged commits
    // is deliberately kept.
    static func remove(worktreePath: String, projectPath: String?, branch: String?) async
        -> Result<Void, Failure> {
        let tool = await GitInspector.tool()
        return await GitInspector.offMain {
            // The folder goes first and is moved rather than deleted, so the caller waits
            // for a rename instead of for however many files the session left behind. What
            // git is told afterwards is the same either way: a checkout whose folder has
            // gone is what `prune` is for.
            if FileManager.default.fileExists(atPath: worktreePath),
               !WorktreeTrash.accept(worktreePath) {
                do {
                    try FileManager.default.removeItem(atPath: worktreePath)
                } catch {
                    return .failure(Failure(
                        message: "Could not remove \(worktreePath.abbreviatedPath): \(error.localizedDescription)"))
                }
            }
            if let tool, let projectPath {
                // Before the branch, not after: git refuses to delete a branch it still
                // believes a checkout has out.
                _ = GitInspector.run(
                    tool, ["-C", projectPath, "worktree", "prune"],
                    timeout: cleanupCommandTimeout)
                if let branch {
                    _ = GitInspector.run(
                        tool, ["-C", projectPath, "branch", "-d", branch],
                        timeout: cleanupCommandTimeout)
                }
            }
            // A workspace session keeps its checkouts together in a folder of its own,
            // which is left empty once the last of them goes.
            let parent = URL(fileURLWithPath: worktreePath).deletingLastPathComponent()
            let workspaceRoot = parent.deletingLastPathComponent().standardizedFileURL
            if ownedBaseDirectories.contains(where: { $0.standardizedFileURL == workspaceRoot }),
               (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: parent)
            }
            WorktreeTrash.empty()
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
        let line = head.trimmed
        guard line.hasPrefix(reference) else { return nil }
        return String(line.dropFirst(reference.count))
    }
}
