import Foundation
import Testing
@testable import MenuBarApp

// Cloning a repository to make a project from it. The clone runs against a throwaway local
// repository, and what matters most is what is left on disk when it does not work out.
struct GitCloneTests {
    private let sandbox = ScratchDirectory(prefix: "clone")

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sandbox.url.path)
    }

    // MARK: - Naming the folder

    @Test(arguments: [
        ("https://github.com/owner/repo.git", "repo"),
        ("https://github.com/owner/repo", "repo"),
        ("https://github.com/owner/repo/", "repo"),
        ("git@github.com:owner/repo.git", "repo"),
        ("git@host:repo.git", "repo"),
        ("ssh://git@host:22/owner/repo.git", "repo"),
        ("  https://github.com/owner/repo.git\n", "repo"),
        ("/Users/me/code/repo", "repo")
    ])
    func namesTheFolderAfterTheRepository(remote: String, name: String) {
        #expect(GitClone.folderName(for: remote) == name)
    }

    @Test(arguments: ["", "   ", "/", ".git", "https://github.com/.."])
    func offersNoNameWhenTheAddressHasNone(remote: String) {
        #expect(GitClone.folderName(for: remote) == nil)
    }

    // MARK: - Reading git's output

    // A meter update ends in a carriage return and can be split across two reads.
    @Test func readsTheMeterAcrossChunks() {
        var output = GitClone.Output()
        #expect(output.read(Data("Receiving objects:  4".utf8)) == nil)
        let progress = output.read(Data("5% (450/1000)\r".utf8))
        #expect(progress == GitClone.Progress(phase: "Receiving objects", percent: 45))
        #expect(output.complaint.isEmpty)
    }

    // The reason comes after the meter, and is what the person needs to read.
    @Test func keepsTheReasonAndDropsTheChatter() {
        var output = GitClone.Output()
        let text = "Cloning into 'x'...\n"
            + "remote: Enumerating objects: 3, done.\n"
            + "remote: Counting objects:  50% (1/2)\r"
            + "remote: Repository not found.\n"
            + "fatal: repository 'x' not found\n"
        let progress = output.read(Data(text.utf8))
        #expect(progress == GitClone.Progress(phase: "Counting objects", percent: 50))
        #expect(output.complaint == "remote: Repository not found.\nfatal: repository 'x' not found")
    }

    // MARK: - Cloning

    @Test func clonesIntoTheDestinationAndLeavesNothingElse() async throws {
        let repo = try GitRepo()
        let destination = sandbox.path("copy")

        let outcome = await GitClone.clone(repo.path, to: destination) { _ in }

        #expect(outcome == .cloned(destination))
        #expect(try String(contentsOf: destination.appendingPathComponent("README.md"),
                           encoding: .utf8) == "hello")
        #expect(try leftovers() == ["copy"])
    }

    @Test func aFailedCloneSaysWhyAndLeavesNoFolder() async throws {
        let outcome = await GitClone.clone(sandbox.path("nothing-here").path,
                                           to: sandbox.path("copy")) { _ in }

        guard case .failed(let message) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("does not exist"))
        #expect(try leftovers().isEmpty)
    }

    // An existing folder is never written into, even an empty one that git would accept.
    @Test func refusesAFolderThatAlreadyExists() async throws {
        let repo = try GitRepo()
        let destination = sandbox.path("copy")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let outcome = await GitClone.clone(repo.path, to: destination) { _ in }

        guard case .failed = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func aCancelledCloneLeavesNoFolder() async throws {
        let repo = try GitRepo()
        let task = Task { await GitClone.clone(repo.path, to: sandbox.path("copy")) { _ in } }
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(try leftovers().isEmpty)
    }
}
