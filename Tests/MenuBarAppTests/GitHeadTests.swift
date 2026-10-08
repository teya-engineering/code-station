import Foundation
import Testing
@testable import MenuBarApp

// Reading the checked-out branch from files, for a plain clone and for the checkouts
// whose .git is a file that points somewhere else.
@MainActor
struct GitHeadTests {

    @Test func readsTheBranchOfAPlainClone() throws {
        let checkout = try folder()
        try write("ref: refs/heads/main\n", to: checkout.appendingPathComponent(".git/HEAD"))

        #expect(GitHead.branch(at: checkout.path) == "main")
    }

    @Test func followsALinkedWorktreeToItsGitDirectory() throws {
        let gitDirectory = try folder().appendingPathComponent("repo/.git/worktrees/feature")
        try write("ref: refs/heads/code-station/4f2ab8c1\n",
                  to: gitDirectory.appendingPathComponent("HEAD"))
        let checkout = try folder()
        try write("gitdir: \(gitDirectory.path)\n", to: checkout.appendingPathComponent(".git"))

        #expect(GitHead.branch(at: checkout.path) == "code-station/4f2ab8c1")
    }

    @Test func followsARelativePointerFromTheCheckout() throws {
        let root = try folder()
        try write("ref: refs/heads/develop\n",
                  to: root.appendingPathComponent(".git/modules/lib/HEAD"))
        let checkout = root.appendingPathComponent("lib")
        try write("gitdir: ../.git/modules/lib\n", to: checkout.appendingPathComponent(".git"))

        #expect(GitHead.branch(at: checkout.path) == "develop")
    }

    @Test func hasNoBranchOnADetachedHead() throws {
        let checkout = try folder()
        try write("4b825dc642cb6eb9a060e54bf8d69288fbee4904\n",
                  to: checkout.appendingPathComponent(".git/HEAD"))

        #expect(GitHead.branch(at: checkout.path) == nil)
    }

    @Test func hasNoBranchOutsideARepository() throws {
        #expect(GitHead.branch(at: try folder().path) == nil)
    }

    // Each test gets a fresh path, so the short-lived branch cache never answers for another.
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHeadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
