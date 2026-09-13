import Foundation
import Testing
@testable import MenuBarApp

// A changed picture is shown, not described. The pane needs the bytes of each version
// that exists, and must fall back to the binary note only when there is nothing to draw.
struct GitImageDiffTests {

    // Any bytes will do for git, but a PNG signature keeps the file honest.
    private let first = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    private let second = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 8, 7])

    @Test func anUntrackedImageHasOnlyAnAfter() async throws {
        let repo = try GitRepo()
        try repo.write("shots/new.png", bytes: first)

        let diff = await diff(of: "shots/new.png", in: repo)
        #expect(diff.images == DiffImages(before: nil, after: first))
        #expect(diff.note == nil)
    }

    @Test func aModifiedImageHasBothSides() async throws {
        let repo = try GitRepo()
        try repo.write("logo.png", bytes: first)
        try repo.commit("add logo")
        try repo.write("logo.png", bytes: second)

        let diff = await diff(of: "logo.png", in: repo)
        #expect(diff.images == DiffImages(before: first, after: second))
    }

    @Test func aStagedImageStillComparesAgainstTheLastCommit() async throws {
        let repo = try GitRepo()
        try repo.write("logo.png", bytes: first)
        try repo.commit("add logo")
        try repo.write("logo.png", bytes: second)
        try repo.git("add", "logo.png")

        let diff = await diff(of: "logo.png", in: repo)
        #expect(diff.images == DiffImages(before: first, after: second))
    }

    @Test func aDeletedImageHasOnlyABefore() async throws {
        let repo = try GitRepo()
        try repo.write("logo.png", bytes: first)
        try repo.commit("add logo")
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("logo.png"))

        let diff = await diff(of: "logo.png", in: repo)
        #expect(diff.images == DiffImages(before: first, after: nil))
    }

    @Test func aRenamedImageReadsItsBeforeFromTheOldName() async throws {
        let repo = try GitRepo()
        try repo.write("old.png", bytes: first)
        try repo.commit("add image")
        try repo.git("mv", "old.png", "new.png")

        let diff = await diff(of: "new.png", in: repo)
        #expect(diff.images == DiffImages(before: first, after: first))
    }

    // Other binary files keep the note: there is nothing the pane could draw.
    @Test func aBinaryThatIsNotAnImageKeepsTheNote() async throws {
        let repo = try GitRepo()
        try repo.write("blob.bin", bytes: first)

        let diff = await diff(of: "blob.bin", in: repo)
        #expect(diff.images == nil)
        #expect(diff.note == "Binary file. Line by line changes are not shown.")
    }

    private func diff(of path: String, in repo: GitRepo) async -> FileDiff {
        let snapshot = await GitInspector.snapshot(at: repo.path)
        guard let change = snapshot.files.first(where: { $0.path == path }) else {
            Issue.record("\(path) is not in the snapshot: \(snapshot.files.map(\.path))")
            return FileDiff()
        }
        return await GitInspector.diff(for: change, root: repo.path)
    }
}
