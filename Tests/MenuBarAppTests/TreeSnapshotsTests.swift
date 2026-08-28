import Foundation
import Testing
@testable import MenuBarApp

// These run real git against a real checkout. What the snapshots are for is seeing writes
// no tool call describes, so nothing short of writing files and asking git can show that
// they work.
struct TreeSnapshotsTests {
    private let git = GitInspector.GitTool(path: "/usr/bin/git",
                                           searchPath: "/usr/bin:/bin:/usr/local/bin")

    @Test func seesWhatAShellCommandWroteAndSaysNothingAboutAReadOnlyOne() async throws {
        let repo = try GitRepo()

        await repo.settle(using: git)
        try repo.write("notes.md", "first\nsecond\n")
        let written = await repo.change(using: git)

        let change = try #require(written)
        #expect(change.files == 1)
        #expect(change.added == 2)
        #expect(change.removed == 0)
        #expect(try #require(change.patch).contains("+++ b/notes.md"))

        // Nothing has moved since, which is what almost every call looks like.
        #expect(await repo.change(using: git) == nil)
    }

    @Test func measuresOneCallAtATimeRatherThanTheWholeTurn() async throws {
        let repo = try GitRepo()

        await repo.settle(using: git)
        try repo.write("one.txt", "a\n")
        let first = try #require(await repo.change(using: git))
        try repo.write("two.txt", "b\nc\n")
        let second = try #require(await repo.change(using: git))

        // The second call is credited with its own two lines, not with all three.
        #expect(first.added == 1)
        #expect(second.added == 2)
        #expect(try #require(second.patch).contains("two.txt"))
        #expect(!(try #require(second.patch).contains("one.txt")))
    }

    @Test func ignoresWhatTheRepositoryItselfIgnores() async throws {
        let repo = try GitRepo()
        try repo.write(".gitignore", "build/\n")
        try repo.commit("work")

        await repo.settle(using: git)
        try repo.write("build/artifact.o", "binary-ish\n")

        #expect(await repo.change(using: git) == nil)
    }

    @Test func keepsCountingWhenTheAgentCommitsMidTurn() async throws {
        let repo = try GitRepo()

        await repo.settle(using: git)
        try repo.write("staged.txt", "one\n")
        _ = await repo.change(using: git)
        // A commit moves HEAD but leaves the tree alone, so nothing is credited to it.
        try repo.commit("work")
        #expect(await repo.change(using: git) == nil)

        try repo.write("after.txt", "two\n")
        #expect(try #require(await repo.change(using: git)).files == 1)
    }

    @Test func leavesTheCheckoutsOwnIndexAlone() async throws {
        let repo = try GitRepo()
        try repo.write("staged-by-hand.txt", "mine\n")
        try repo.git("add", "staged-by-hand.txt")

        await repo.settle(using: git)
        try repo.write("written-by-agent.txt", "theirs\n")
        _ = await repo.change(using: git)

        // The file staged by hand is still the only thing staged, and the agent's file is
        // still untracked. A snapshot that used the real index would have staged both.
        let status = try repo.git("status", "--porcelain")
        #expect(status.contains("A  staged-by-hand.txt"))
        #expect(status.contains("?? written-by-agent.txt"))
    }

    @Test func saysNothingAboutAFolderThatIsNotARepository() async throws {
        let folder = ScratchDirectory(prefix: "not-a-repo")

        let snapshots = TreeSnapshots.shared
        snapshots.baseline(at: folder.url.path, using: git)
        let change = await withCheckedContinuation { continuation in
            snapshots.change(at: folder.url.path, using: self.git) { continuation.resume(returning: $0) }
        }
        #expect(change == nil)
    }

    @Test func measuresTheCallsThatCouldHaveWritten() {
        #expect(TreeSnapshots.measures("Bash"))
        #expect(TreeSnapshots.measures("Edit"))
        #expect(TreeSnapshots.measures("NotebookEdit"))
        #expect(!TreeSnapshots.measures("Read"))
        #expect(!TreeSnapshots.measures("Grep"))
        // An agent's own calls are measured as they arrive, so the call standing for the
        // agent has nothing left of its own.
        #expect(!TreeSnapshots.measures("Task"))
    }
}

private extension GitRepo {
    // The first snapshot of a checkout has nothing to compare against, so it only records
    // where things stand. Taken by hand here rather than through `baseline`, which reports
    // nothing back and so gives a test no way to know it has happened.
    func settle(using git: GitInspector.GitTool) async {
        _ = await change(using: git)
    }

    func change(using git: GitInspector.GitTool) async -> WrittenChange? {
        await withCheckedContinuation { continuation in
            TreeSnapshots.shared.change(at: path, using: git) { continuation.resume(returning: $0) }
        }
    }
}
