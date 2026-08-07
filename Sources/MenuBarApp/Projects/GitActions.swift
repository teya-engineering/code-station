import Foundation

struct GitPushCommit: Identifiable, Sendable, Equatable {
    let id: String
    let subject: String

    var shortID: String { String(id.prefix(8)) }
}

enum GitPushPreview: Sendable, Equatable {
    case commits([GitPushCommit])
    case failed(String)
}

// The git commands that change a repository: switching branch, committing, pulling and
// pushing. They live apart from GitInspector so the inspection side stays read-only,
// but they start git through the same runner, so PATH lookup and prompt suppression
// behave the same everywhere. Each action returns nil on success or the error text git
// gave, ready to show in a dialog.
enum GitActions {

    static func switchBranch(_ branch: String, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            GitInspector.run(tool, ["switch", branch], in: url)
        }
    }

    // Commits everything the changes list shows, staged or not, the way the screen
    // presents it: one working tree, one commit.
    static func commitAll(message: String, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            let add = GitInspector.run(tool, ["add", "-A"], in: url)
            guard add.ok else { return add }
            return GitInspector.run(tool, ["commit", "-m", message], in: url)
        }
    }

    // --no-edit keeps a merge pull from waiting on an editor that can never appear here.
    static func pull(at root: String) async -> String? {
        await perform(at: root) { tool, url in
            GitInspector.run(tool, ["pull", "--no-edit"], in: url)
        }
    }

    // --ff-only so this can only move the branch up to the remote tip or fail: it runs
    // unattended before a session starts, where a surprise merge has no place. The
    // timeout covers the fetch a pull begins with.
    static func fastForwardPull(at root: String) async -> String? {
        await perform(at: root) { tool, url in
            GitInspector.run(tool, ["pull", "--ff-only"], in: url, timeout: 30)
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

    static func commitsToPush(hasUpstream: Bool, at root: String) async -> GitPushPreview {
        guard let tool = await GitInspector.tool() else {
            return .failed("Could not find git on PATH.")
        }
        let url = URL(fileURLWithPath: root)
        return await GitInspector.offMain {
            let arguments = hasUpstream
                ? ["log", "--no-color", "--format=%H%x09%s", "@{u}..HEAD"]
                : ["log", "--no-color", "--format=%H%x09%s", "HEAD", "--not", "--remotes=origin"]
            let output = GitInspector.run(tool, arguments, in: url)
            guard output.ok else { return .failed(output.failureMessage) }
            return .commits(parsePushCommits(output.text))
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

    private static func parsePushCommits(_ text: String) -> [GitPushCommit] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            return GitPushCommit(id: String(fields[0]), subject: String(fields[1]))
        }
    }
}
