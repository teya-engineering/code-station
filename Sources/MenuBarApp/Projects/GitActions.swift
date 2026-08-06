import Foundation

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

    // A branch with no upstream yet, which is every session worktree branch, is published
    // to origin under its own name and starts tracking it.
    static func push(hasUpstream: Bool, at root: String) async -> String? {
        await perform(at: root) { tool, url in
            hasUpstream
                ? GitInspector.run(tool, ["push"], in: url)
                : GitInspector.run(tool, ["push", "-u", "origin", "HEAD"], in: url)
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
}
