import Foundation
import Testing
@testable import MenuBarApp

// Session deletion moves a checkout aside before unlinking it in the background. These
// tests cover the move, the later unlink, and failures that must remain visible.
struct WorktreeTrashTests {

    private let root = ScratchDirectory(prefix: "worktree-trash-tests")
    private var trash: URL { root.path("trash") }

    @Test func keepsTheDeletionQueueOutOfApplicationSupport() {
        #expect(WorktreeTrash.directory.path.hasSuffix("/.code-station/worktrees-trash"))
        #expect(!WorktreeTrash.directory.path.contains("Application Support"))
    }

    private func checkout(_ name: String) throws -> URL {
        let url = root.path(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("dependency".utf8).write(to: url.appendingPathComponent("node_modules.txt"))
        return url
    }

    private func contents(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url,
                                                      includingPropertiesForKeys: nil)) ?? []
    }

    @Test func takesTheCheckoutOffItsPath() throws {
        let worktree = try checkout("project-abc12345")

        #expect(WorktreeTrash.accept(worktree.path, into: trash))

        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
        let waiting = contents(of: trash)
        #expect(waiting.count == 1)
        // What was inside comes with it: nothing is unlinked by the move itself.
        #expect(FileManager.default.fileExists(
            atPath: try #require(waiting.first).appendingPathComponent("node_modules.txt").path))
    }

    // The name is only there to make the folder recognisable by hand, so two checkouts
    // called the same thing have to be able to wait side by side.
    @Test func holdsTwoCheckoutsOfTheSameName() throws {
        let first = try checkout("one/project-abc12345")
        let second = try checkout("two/project-abc12345")

        #expect(WorktreeTrash.accept(first.path, into: trash))
        #expect(WorktreeTrash.accept(second.path, into: trash))

        #expect(contents(of: trash).count == 2)
    }

    @Test func unlinksWhatIsWaiting() throws {
        _ = WorktreeTrash.accept(try checkout("project-abc12345").path, into: trash)

        WorktreeTrash.empty(trash)
        WorktreeTrash.settle()

        #expect(contents(of: trash).isEmpty)
    }

    // A folder that was never moved must not report success: the caller deletes it where it
    // stands on the strength of this answer, and a false yes would leave it on disk forever.
    @Test func refusesAFolderItCannotMove() throws {
        #expect(WorktreeTrash.accept(root.path("never-existed").path, into: trash) == false)
    }
}
