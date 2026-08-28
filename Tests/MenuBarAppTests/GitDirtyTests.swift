import Foundation
import Testing
@testable import MenuBarApp

// The mark the sidebar puts on a session whose folder holds work git does not have. It
// decides how a delete is worded, so a wrong answer either hides a real loss or cries
// wolf about a clean folder.
struct GitDirtyTests {

    @Test func saysNoForACleanCheckout() async throws {
        let repo = try GitRepo()
        #expect(await GitInspector.isDirty(at: repo.path) == false)
    }

    @Test func saysYesForAnEditedFile() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "changed")
        #expect(await GitInspector.isDirty(at: repo.path) == true)
    }

    // An untracked file is work that would be lost with the folder just as surely as an
    // edit, so it counts.
    @Test func saysYesForAnUntrackedFile() async throws {
        let repo = try GitRepo()
        try repo.write("notes.txt", "scratch")
        #expect(await GitInspector.isDirty(at: repo.path) == true)
    }

    @Test func countsEveryUncommittedFile() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "changed")
        try repo.write("notes.txt", "scratch")
        try repo.write("nested/todo.txt", "later")

        #expect(await GitInspector.uncommittedFileCount(at: repo.path) == 3)
    }

    // Every project folder is asked, whether or not it is a repository at all.
    @Test func saysNoForAPlainFolder() async throws {
        let folder = ScratchDirectory(prefix: "dirty-plain")
        #expect(await GitInspector.isDirty(at: folder.url.path) == false)
    }

    @Test func saysNoForAFolderThatIsGone() async throws {
        let missing = ScratchDirectory(prefix: "dirty").path("missing")
        #expect(await GitInspector.isDirty(at: missing.path) == false)
    }
}
