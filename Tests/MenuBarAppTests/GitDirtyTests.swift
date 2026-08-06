import Foundation
import Testing
@testable import MenuBarApp

// The mark the sidebar puts on a session whose folder holds work git does not have. It
// decides how a delete is worded, so a wrong answer either hides a real loss or cries
// wolf about a clean folder.
struct GitDirtyTests {

    @Test func saysNoForACleanCheckout() async throws {
        let repo = try Repo()
        #expect(await GitInspector.isDirty(at: repo.path) == false)
    }

    @Test func saysYesForAnEditedFile() async throws {
        let repo = try Repo()
        try repo.write("README.md", "changed")
        #expect(await GitInspector.isDirty(at: repo.path) == true)
    }

    // An untracked file is work that would be lost with the folder just as surely as an
    // edit, so it counts.
    @Test func saysYesForAnUntrackedFile() async throws {
        let repo = try Repo()
        try repo.write("notes.txt", "scratch")
        #expect(await GitInspector.isDirty(at: repo.path) == true)
    }

    // Every project folder is asked, whether or not it is a repository at all.
    @Test func saysNoForAPlainFolder() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirty-plain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await GitInspector.isDirty(at: folder.path) == false)
    }

    @Test func saysNoForAFolderThatIsGone() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirty-missing-" + UUID().uuidString)
        #expect(await GitInspector.isDirty(at: missing.path) == false)
    }

    // A repository with one commit in it, thrown away with the test.
    private final class Repo {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirty-repo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try write("README.md", "hello")
            git("init", "-q")
            // The machine running this may have no identity configured, and a commit
            // without one fails.
            git("-c", "user.email=t@example.com", "-c", "user.name=Test", "add", ".")
            git("-c", "user.email=t@example.com", "-c", "user.name=Test",
                "-c", "commit.gpgsign=false", "commit", "-qm", "first")
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        private func git(_ arguments: String...) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = url
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
