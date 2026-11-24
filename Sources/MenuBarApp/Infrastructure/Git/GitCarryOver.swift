import Foundation

// Copies the uncommitted work in a project folder into a new worktree, so a session can
// carry on with something already started. The project folder is only ever read: the
// work is copied, never moved, so the worst a clash can do is leave conflict markers in
// a worktree that can be thrown away.
//
// `git stash create` records the tracked changes as a commit without touching the
// working tree, the index or the stash list that every worktree of the repository
// shares. Untracked files are not in it, so they are copied as files.
enum GitCarryOver {

    // What bringing the work onto a base would do, worked out before anything is made.
    enum Preview: Sendable, Equatable {
        case clean
        // Files that would hold conflict markers, or untracked files the base also has.
        case clashes([String])
        // The folder could not be read, or git is too old to merge without a checkout.
        case unknown
    }

    struct Outcome: Sendable, Equatable {
        // Files left with conflict markers, and untracked files whose copy from the
        // folder replaced the version the worktree started with.
        var conflicts: [String] = []
        // Why some of the work did not come across. Nil when all of it did.
        var failure: String?
    }

    static func preview(at projectPath: String, onto base: String) async -> Preview {
        guard let tool = Git.tool() else { return .unknown }
        let folder = URL(fileURLWithPath: projectPath)
        return await Git.offMain {
            let stash = Git.run(tool, ["stash", "create"], in: folder)
            guard stash.ok else { return .unknown }
            var clashes: [String] = []

            if !stash.trimmedText.isEmpty {
                let commit = stash.trimmedText
                // The stash's first parent is the commit the work was written on, so the
                // merge sees only the work itself as one side's change.
                let merge = Git.run(
                    tool, ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z",
                           "--merge-base=\(commit)^1", base, commit],
                    in: folder)
                switch merge.status {
                case 0: break
                // The first field is the merged tree, the rest are the clashing files.
                case 1: clashes += nulSeparated(merge.text).dropFirst()
                default: return .unknown
                }
            }

            // An untracked file can only clash with a file the base added since HEAD:
            // anything HEAD already tracks could not be untracked.
            let untracked = untrackedFiles(tool, in: folder)
            if !untracked.isEmpty {
                let added = Git.run(
                    tool, ["diff", "--name-only", "-z", "--diff-filter=A", "HEAD", base],
                    in: folder)
                guard added.ok else { return .unknown }
                let addedFiles = Set(nulSeparated(added.text))
                clashes += untracked.filter(addedFiles.contains)
            }

            let files = unique(clashes)
            return files.isEmpty ? .clean : .clashes(files)
        }
    }

    // Reads the folder again rather than reusing what a preview saw, since the work may
    // have changed while the sheet was open. A clash is not a failure: the files keep
    // their conflict markers for the session to resolve.
    static func apply(from projectPath: String, to worktreePath: String) async -> Outcome {
        guard let tool = Git.tool() else {
            return Outcome(failure: Git.notFoundMessage)
        }
        let folder = URL(fileURLWithPath: projectPath)
        let worktree = URL(fileURLWithPath: worktreePath)
        return await Git.offMain {
            let stash = Git.run(tool, ["stash", "create"], in: folder)
            guard stash.ok else { return Outcome(failure: stash.failureMessage) }
            var outcome = Outcome()

            if !stash.trimmedText.isEmpty {
                // Worktrees share one object store, so the new checkout can reach the
                // commit `stash create` just wrote in the project folder.
                let applied = Git.run(tool, ["stash", "apply", stash.trimmedText],
                                      in: worktree)
                if !applied.ok {
                    let files = Git.conflictedPaths(tool, in: worktree)
                    if files.isEmpty { return Outcome(failure: applied.failureMessage) }
                    outcome.conflicts += files
                }
            }

            let files = FileManager.default
            var uncopied: [String] = []
            for path in untrackedFiles(tool, in: folder) {
                let source = folder.appendingPathComponent(path)
                let destination = worktree.appendingPathComponent(path)
                // Read without following links, so a link the base already has counts
                // as being there.
                if (try? files.attributesOfItem(atPath: destination.path)) != nil {
                    outcome.conflicts.append(path)
                    try? files.removeItem(at: destination)
                }
                do {
                    try files.createDirectory(at: destination.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
                    try files.copyItem(at: source, to: destination)
                } catch {
                    uncopied.append(path)
                }
            }
            if !uncopied.isEmpty {
                outcome.failure = "Could not copy " + counted(uncopied.count, "untracked file")
                    + ": " + uncopied.prefix(5).joined(separator: ", ")
                    + (uncopied.count > 5 ? " and more." : ".")
            }

            outcome.conflicts = unique(outcome.conflicts)
            return outcome
        }
    }

    private static func untrackedFiles(_ tool: Git.Tool, in folder: URL) -> [String] {
        let listed = Git.run(tool, ["ls-files", "--others", "--exclude-standard", "-z"],
                             in: folder)
        return listed.ok ? nulSeparated(listed.text) : []
    }

    private static func nulSeparated(_ text: String) -> [String] {
        text.split(separator: "\0").map(String.init)
    }

    private static func unique(_ files: [String]) -> [String] {
        var seen: Set<String> = []
        return files.filter { seen.insert($0).inserted }
    }
}

extension GitCarryOver.Outcome {
    // What the new session's composer is filled with when the work did not land cleanly.
    // It is written as the user's own request, so sending it as is hands the agent the job
    // of finishing what the copy started. Nil when there is nothing to finish.
    func agentNote(projectPath: String, base: String?) -> String? {
        let folder = (projectPath as NSString).abbreviatingWithTildeInPath
        var paragraphs: [String] = []
        if !conflicts.isEmpty {
            let target = base ?? "the commit this worktree started from"
            paragraphs.append(
                "I copied my uncommitted changes from \(folder) into this worktree, "
                + "which starts from \(target). These files clash:\n"
                + conflicts.map { "- \($0)" }.joined(separator: "\n"))
            paragraphs.append(
                "Resolve the conflicts so my changes work on top of \(target). "
                + "Where a file has no conflict markers, compare it with git to see both sides.")
        }
        if let failure {
            paragraphs.append("Copying my uncommitted changes from \(folder) did not finish: "
                              + failure + " Copy over what is missing.")
        }
        guard !paragraphs.isEmpty else { return nil }
        paragraphs.append("The original copies are still in \(folder).")
        return paragraphs.joined(separator: "\n\n")
    }
}
