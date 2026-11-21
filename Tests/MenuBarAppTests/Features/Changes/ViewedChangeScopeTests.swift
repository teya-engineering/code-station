import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ViewedChangeScopeTests {
    @Test func readingTheLastCommitLeavesEarlierChangesUnviewed() async throws {
        let repo = try GitRepo()
        let common = (1...30).map { "unchanged line \($0)" }.joined(separator: "\n")
        try repo.write("review.txt", "requireAuthentication()\n" + common + "\nold footer\n")
        try repo.commit("Add original file")
        try repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
        try repo.git("checkout", "-qb", "feature")
        try repo.write("review.txt", common + "\nold footer\n")
        try repo.commit("Remove authentication")
        try repo.write("review.txt", common + "\nnew footer\n")
        try repo.commit("Change footer")

        let commit = await GitInspector.commitFiles(repo.head, root: repo.path)
        let file = try #require(commit.files.first { $0.path == "review.txt" })
        let lastDiff = await GitInspector.commitFileDiff(repo.head, parent: commit.parents.first,
                                                        file: file, root: repo.path)
        #expect(!lastDiff.lines.contains { $0.text.contains("requireAuthentication") })

        let session = UUID()
        let store = ViewedFileStore(url: nil)
        let key = ViewedFileStore.key(root: repo.path, path: file.path)
        let lastChange = try #require(commit.versions[file.path])
        store.mark(key, change: lastChange, in: session)

        let whole = await GitInspector.snapshot(at: repo.path, comparingToRemote: true)
        let wholeFile = try #require(whole.files.first { $0.path == file.path })
        let wholeDiff = await GitInspector.reviewDiff(for: wholeFile, root: repo.path,
                                                      base: whole.diffBase(for: wholeFile))
        #expect(wholeDiff.lines.contains { $0.text == "-requireAuthentication()" })
        let wholeChange = try #require(wholeDiff.reviewChange)
        #expect(wholeChange.after == lastChange.after)
        #expect(wholeChange.before != lastChange.before)
        #expect(store.state(key, change: wholeChange, in: session) == .notViewed)
        #expect(store.latest(key, change: wholeChange, in: session) == nil)
    }

    @Test func theSameDiffStaysViewedWhenCommitted() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "reviewed work\n")
        let snapshot = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true)
        let changes = await GitInspector.reviewChanges(in: snapshot)
        let working = try #require(changes["README.md"])
        let session = UUID()
        let store = ViewedFileStore(url: nil)
        store.mark("README.md", change: working, in: session)

        try repo.commit("Keep reviewed work")
        let committed = await GitInspector.commitFiles(repo.head, root: repo.path)
        let version = try #require(committed.versions["README.md"])
        #expect(working == version)
        #expect(store.state("README.md", change: version, in: session) == .viewed)
    }

    @Test func switchingBasesModesAndRenameSourcesDoesNotReuseAViewedMark() {
        let session = UUID()
        let store = ViewedFileStore(url: nil)
        let change = ViewedChange(before: .init(mode: "100644", blob: "base-one"),
                                  after: .init(mode: "100644", blob: "same-content"), originalPath: "old.txt")
        store.mark("new.txt", change: change, in: session)
        var otherBase = change
        otherBase.before.blob = "base-two"
        #expect(store.state("new.txt", change: otherBase, in: session) == .notViewed)
        var otherSource = change
        otherSource.originalPath = "another.txt"
        #expect(store.state("new.txt", change: otherSource, in: session) == .notViewed)
        var otherMode = change
        otherMode.after.mode = "100755"
        #expect(store.state("new.txt", change: otherMode, in: session).isEdited)
        #expect(store.state("new.txt", change: change, in: session) == .viewed)
    }

    @Test func deletionsKeepTheIdentityOfWhatWasDeleted() async throws {
        let repo = try GitRepo()
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("README.md"))
        let snapshot = await GitInspector.snapshot(at: repo.path, comparingToLastCommit: true)
        let changes = await GitInspector.reviewChanges(in: snapshot)
        let deleted = try #require(changes["README.md"])
        #expect(deleted.after == .absent)
        #expect(deleted.before.blob == FileVersion.blobID(Data("hello".utf8)))
        let session = UUID()
        let store = ViewedFileStore(url: nil)
        store.mark("README.md", change: deleted, in: session)
        var other = deleted
        other.before.blob = "another-version"
        #expect(store.state("README.md", change: other, in: session) == .notViewed)
    }

    @Test func undoClearRestoresTextOnDiskForLaterHighlights() throws {
        let folder = ScratchDirectory(prefix: "viewed-undo")
        let url = folder.url.appendingPathComponent("viewed.json")
        let session = UUID()
        let store = ViewedFileStore(url: url)
        let text = "reviewed text\n"
        let change = ViewedChange(before: .absent,
                                  after: .init(mode: "100644", blob: FileVersion.blobID(Data(text.utf8))))
        store.mark("file", change: change, text: text, in: session)
        let checkpoint = store.checkpoint(in: session)
        store.clear(session)
        #expect(store.text(of: change.after.blob) == nil)
        store.restore(checkpoint, in: session)
        #expect(store.flush())

        let reopened = ViewedFileStore(url: url)
        #expect(reopened.state("file", change: change, in: session) == .viewed)
        #expect(reopened.text(of: change.after.blob) == text)
        #expect(ViewedLines.added(since: try #require(reopened.text(of: change.after.blob)),
                                 in: text + "later edit\n") == [2])
    }

    @Test func oldUnscopedMarksCannotMarkAnyComparisonViewed() throws {
        let folder = ScratchDirectory(prefix: "viewed-legacy")
        let url = folder.url.appendingPathComponent("viewed.json")
        let session = UUID()
        let marks = [session: ["file": [ViewedMark(version: "same-content", at: Date())]]]
        try PersistentFile.makeEncoder().encode(marks).write(to: url)
        let store = ViewedFileStore(url: url)
        let change = ViewedChange(before: .absent, after: .init(mode: "100644", blob: "same-content"))
        #expect(store.loadError == nil)
        #expect(store.state("file", change: change, in: session) == .notViewed)
        store.mark("file", change: change, in: session)
        #expect(store.state("file", change: change, in: session) == .viewed)
    }

    @Test func anOpenDiffKeepsTheVersionThatWasActuallyShown() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "first edit\n")
        let navigation = ChangesNavigationMemory()
        let model = ChangesModel(root: repo.path, navigation: navigation)
        let review = ReviewTarget(sessionID: UUID(), agent: .claudeCode, reviews: ReviewCommentStore(url: nil))
        await model.reload(for: ChangesScreen(gitStats: GitStatsCache(), review: review))
        let displayed = try #require(model.diff?.reviewChange)

        try repo.write("README.md", "second edit\n")
        let snapshot = try #require(model.snapshot)
        let fresh = await GitInspector.reviewChanges(in: snapshot)
        #expect(fresh["README.md"] != displayed)
        #expect(model.diff?.reviewChange == displayed)
        review.reviews.viewed.mark("README.md", change: displayed, in: review.sessionID)
        let state = review.reviews.viewed.state("README.md", change: fresh["README.md"], in: review.sessionID)
        #expect(state.isEdited)
    }
}
