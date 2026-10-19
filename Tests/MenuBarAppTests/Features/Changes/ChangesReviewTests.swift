import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct ChangesReviewTests {
    @Test func replacementBlocksAlignWithoutShiftingContext() {
        let lines = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -20,3 +20,4 @@"),
            DiffLine(id: 1, kind: .context, text: " before"),
            DiffLine(id: 2, kind: .deletion, text: "-old"),
            DiffLine(id: 3, kind: .addition, text: "+new"),
            DiffLine(id: 4, kind: .addition, text: "+extra"),
            DiffLine(id: 5, kind: .context, text: " after")
        ]
        let rows = DiffComparisonRow.align(lines)
        #expect(rows.count == 5)
        #expect(rows[2].oldNumber == 21 && rows[2].newNumber == 21)
        #expect(rows[3].left == nil && rows[3].newNumber == 22)
        #expect(rows[4].oldNumber == 22 && rows[4].newNumber == 23)
    }

    @Test func copiesCompleteVersionsAndPatchAcrossStagedAndUnstagedChanges() async throws {
        let repo = try GitRepo()
        let original = (1...80).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try repo.write("file.txt", original)
        try repo.commit("Add file")
        try repo.write("file.txt", original.replacingOccurrences(of: "line 30\n", with: "staged\n"))
        try repo.git("add", "file.txt")
        let final = original.replacingOccurrences(of: "line 30\n", with: "working\n")
        try repo.write("file.txt", final)
        let change = try #require(await GitInspector.snapshot(at: repo.path).files.first)
        let before = try await GitInspector.copyText(for: change, root: repo.path, version: .before).get()
        let after = try await GitInspector.copyText(for: change, root: repo.path, version: .after).get()
        let patch = try await GitInspector.copyText(for: change, root: repo.path, version: .patch).get()
        #expect(before == original)
        #expect(after == final)
        #expect(patch.contains("--- a/file.txt\n+++ b/file.txt\n@@"))
        #expect(patch.contains("-line 30\n+working\n"))
        #expect(!patch.contains("+staged"))
        let review = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true)
        #expect(review.files.first?.added == 1)
        #expect(review.files.first?.removed == 1)
    }

    @Test func newAndDeletedVersionsAreEmptyOnTheMissingSide() async throws {
        let repo = try GitRepo()
        try repo.write("new.txt", "new\n")
        var change = try #require(await GitInspector.snapshot(at: repo.path).files.first { $0.path == "new.txt" })
        #expect(try await GitInspector.copyText(for: change, root: repo.path, version: .before).get() == "")
        #expect(try await GitInspector.copyText(for: change, root: repo.path, version: .patch).get().contains("+new\n"))
        try repo.git("rm", "README.md")
        change = try #require(await GitInspector.snapshot(at: repo.path).files.first { $0.path == "README.md" })
        #expect(try await GitInspector.copyText(for: change, root: repo.path, version: .after).get() == "")
        #expect(try await GitInspector.copyText(for: change, root: repo.path, version: .before).get() == "hello")
    }
}

extension ChangesReviewTests {
    @Test func cleanDoesNotImplySynced() {
        var snapshot = GitSnapshot(state: .ready)
        #expect(snapshot.syncDescription() == "No upstream branch")
        snapshot.upstream = "origin/main"
        #expect(snapshot.syncDescription() == "Remote status unknown")
        snapshot.trackingKnown = true
        #expect(snapshot.syncDescription().hasPrefix("Up to date"))
        #expect(snapshot.syncDescription(remoteUnavailable: true) == "Remote status unavailable")
        snapshot.ahead = 2
        snapshot.behind = 3
        #expect(snapshot.syncDescription() == "2 ahead · 3 behind origin/main")
    }

    @Test func remoteActionsFollowWhatTheBranchNeeds() {
        var snapshot = GitSnapshot(state: .ready)
        #expect(snapshot.remoteActions == [.publish])
        snapshot.hasCommits = false
        #expect(snapshot.remoteActions.isEmpty)
        snapshot.hasCommits = true
        snapshot.upstream = "origin/main"
        #expect(snapshot.remoteActions.isEmpty)
        snapshot.ahead = 2
        #expect(snapshot.remoteActions == [.push(2)])
        snapshot.behind = 3
        #expect(snapshot.remoteActions == [.pull(3), .push(2)])
        snapshot.ahead = 0
        #expect(snapshot.remoteActions == [.pull(3)])
    }

    @Test func renamedVersionsKeepWhitespaceAndMissingFinalNewline() async throws {
        let repo = try GitRepo()
        try repo.write("old.txt", "\tkeep whitespace\nlast line")
        try repo.commit("Add text")
        try repo.git("mv", "old.txt", "new.txt")
        try repo.write("new.txt", "\tkeep whitespace\nnew last line")
        let change = try #require(await GitInspector.snapshot(at: repo.path).files.first)
        #expect(try await GitInspector.copyText(for: change, root: repo.path, version: .before).get() == "\tkeep whitespace\nlast line")
        #expect(try await GitInspector.copyText(for: change, root: repo.path, version: .after).get() == "\tkeep whitespace\nnew last line")
    }

    @Test func unbornBranchComparesTheWorkingVersion() async throws {
        let repo = try GitRepo(initialCommit: false)
        try repo.write("new.txt", "staged\n")
        try repo.git("add", "new.txt")
        try repo.write("new.txt", "working\n")
        let change = try #require(await GitInspector.snapshot(at: repo.path).files.first)
        let patch = try await GitInspector.copyText(for: change, root: repo.path, version: .patch).get()
        #expect(patch.contains("+working\n"))
        #expect(!patch.contains("+staged\n"))
    }

    @Test @MainActor func expandedContextUsesBothLineNumbers() {
        let gap = DiffGap(revision: .workingTree, path: "file", id: 0, start: 1, count: 18)
        let lines = [DiffLine(id: 0, kind: .gap, text: "", gap: gap),
                     DiffLine(id: 1, kind: .context, text: " nineteen"),
                     DiffLine(id: 2, kind: .hunk, text: "@@ -20 +20 @@"),
                     DiffLine(id: 3, kind: .deletion, text: "-old"),
                     DiffLine(id: 4, kind: .addition, text: "+new")]
        let rows = DiffComparisonRow.align(lines)
        #expect(rows[1].oldNumber == 19 && rows[1].newNumber == 19)
        let rendered = DiffText.attributed(lines, numbered: true).string
        #expect(rendered.contains("   19    19   nineteen"))
    }
}
