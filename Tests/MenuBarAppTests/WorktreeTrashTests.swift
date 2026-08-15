import Foundation
import Testing
@testable import MenuBarApp

// Deleting a session used to wait on unlinking its checkout, which is tens of seconds when
// the session installed dependencies. The folder is moved aside instead, so what these pin
// down is that the move really takes it off its path, that what was moved is unlinked
// afterwards, and that a folder which will not move says so rather than looking cleared.
struct WorktreeTrashTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-trash-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func checkout(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("dependency".utf8).write(to: url.appendingPathComponent("node_modules.txt"))
        return url
    }

    private func contents(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url,
                                                      includingPropertiesForKeys: nil)) ?? []
    }

    @Test func takesTheCheckoutOffItsPath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("trash")
        let worktree = try checkout("project-abc12345", in: root)

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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("trash")
        let first = try checkout("one/project-abc12345", in: root)
        let second = try checkout("two/project-abc12345", in: root)

        #expect(WorktreeTrash.accept(first.path, into: trash))
        #expect(WorktreeTrash.accept(second.path, into: trash))

        #expect(contents(of: trash).count == 2)
    }

    @Test func unlinksWhatIsWaiting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("trash")
        _ = WorktreeTrash.accept(try checkout("project-abc12345", in: root).path, into: trash)

        WorktreeTrash.empty(trash)
        WorktreeTrash.settle()

        #expect(contents(of: trash).isEmpty)
    }

    // A folder that was never moved must not report success: the caller deletes it where it
    // stands on the strength of this answer, and a false yes would leave it on disk forever.
    @Test func refusesAFolderItCannotMove() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(WorktreeTrash.accept(root.appendingPathComponent("never-existed").path,
                                     into: root.appendingPathComponent("trash")) == false)
    }
}
