import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ChangesModelTests {
    @Test func aLateRefreshCannotReplaceTheNewerSnapshot() async {
        let reads = SnapshotReads()
        let model = ChangesModel(root: "/repo", navigation: ChangesNavigationMemory(),
                                 readSnapshot: { root, _ in await reads.read(root) })
        let screen = ChangesScreen(gitStats: GitStatsCache())
        let first = Task { await model.reload(for: screen) }
        #expect(await waitUntil { reads.pending.count == 1 })
        let second = Task { await model.reload(for: screen) }
        #expect(await waitUntil { reads.pending.count == 2 })
        reads.pending[1].resume(returning: GitSnapshot(state: .ready, root: "/repo", branch: "newer", hasCommits: false))
        await second.value
        reads.pending[0].resume(returning: GitSnapshot(state: .ready, root: "/repo", branch: "older", hasCommits: false))
        await first.value
        #expect(model.snapshot?.branch == "newer")
        #expect(!model.loading)
    }

    @Test func cancellationClearsLoadingWithoutPublishingTheResult() async {
        let reads = SnapshotReads()
        let model = ChangesModel(root: "/repo", navigation: ChangesNavigationMemory(),
                                 readSnapshot: { root, _ in await reads.read(root) })
        let task = Task { await model.reload(for: ChangesScreen(gitStats: GitStatsCache())) }
        #expect(await waitUntil { reads.pending.count == 1 })
        task.cancel()
        reads.pending[0].resume(returning: GitSnapshot(state: .ready, root: "/repo", hasCommits: false))
        await task.value
        #expect(model.snapshot == nil)
        #expect(!model.loading)
    }

    @Test func comparingToTheRemoteTurnsOffWhenTheRemoteBaseIsGone() async {
        // No commits, so the reload does not go looking for the latest one.
        let model = ChangesModel(root: "/repo", navigation: ChangesNavigationMemory(),
                                 readSnapshot: { _, _ in GitSnapshot(state: .ready, hasCommits: false) })
        model.comparesToRemote = true
        await model.reload(for: ChangesScreen(gitStats: GitStatsCache()))
        #expect(!model.comparesToRemote)
    }

    @Test func theSharedCacheKeepsOnlyUncommittedWork() async {
        let committed = GitChange(path: "a.swift", originalPath: nil, kind: .added, isStaged: false,
                                  isUnstaged: false, added: 9, removed: 0, isBinary: false)
        let uncommitted = GitChange(path: "b.swift", originalPath: nil, kind: .modified, isStaged: false,
                                    isUnstaged: true, added: 1, removed: 0, isBinary: false)
        var compared = GitSnapshot(state: .ready)
        compared.files = [committed, uncommitted]
        compared.uncommittedFiles = [uncommitted]
        compared.remoteBase = GitCompareBase(ref: "origin/main", commit: "abc")
        compared.comparedToRemote = true
        let model = ChangesModel(root: "/repo", navigation: ChangesNavigationMemory(), readSnapshot: { _, _ in compared })
        let stats = GitStatsCache()
        await model.reload(for: ChangesScreen(gitStats: stats))
        #expect(stats.snapshot(at: "/repo")?.files == [uncommitted])
    }

    @Test func showingADiffSwapsTheFileItsTextAndItsThreadsTogether() async {
        let model = ChangesModel(root: "/repo", navigation: ChangesNavigationMemory())
        let lines = [DiffLine(id: 0, kind: .hunk, text: "@@ -1,1 +1,2 @@"),
                     DiffLine(id: 1, kind: .context, text: " kept"),
                     DiffLine(id: 2, kind: .addition, text: "+added")]
        await model.showDiff(FileDiff(lines: lines), of: "a.swift", language: nil, scale: 1,
                             comments: DiffComments(threads: [2]))
        #expect(model.diff?.lines == lines)
        #expect(model.diffFileID == "a.swift")
        #expect(model.diffText?.string.contains("added") == true)
        #expect(model.renderedThreads == [2])
    }

    // A file with nothing to show as text, such as a picture, must not leave the text of
    // the file before it on screen.
    @Test func aFileWithoutLinesReplacesTheTextOfTheOneBefore() async {
        let model = ChangesModel(root: "/repo", navigation: ChangesNavigationMemory())
        await model.showDiff(FileDiff(lines: [DiffLine(id: 0, kind: .addition, text: "+code")]), of: "a.swift",
                             language: nil, scale: 1, comments: DiffComments(threads: [0]))
        await model.showDiff(FileDiff(note: "Binary file"), of: "b.png", language: nil, scale: 1, comments: nil)
        #expect(model.diffFileID == "b.png")
        #expect(model.diff?.note == "Binary file")
        #expect(model.diffText == nil)
        #expect(model.renderedThreads.isEmpty)
    }

    @Test func aReloadKeepsTheOpenFileWhileItStillHasChanges() async throws {
        let repo = try GitRepo()
        try repo.write("a.swift", "one\n")
        try repo.write("b.swift", "two\n")
        let navigation = ChangesNavigationMemory()
        let model = ChangesModel(root: repo.path, navigation: navigation)
        let screen = ChangesScreen(gitStats: GitStatsCache())

        await model.reload(for: screen)
        #expect(model.fileSelection.activeID == "a.swift")
        #expect(model.diffFileID == "a.swift")

        model.fileSelection.select("b.swift", in: ["a.swift", "b.swift"], extendingRange: false, toggling: false)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("a.swift"))
        await model.reload(for: screen)
        #expect(model.fileSelection.activeID == "b.swift")
        #expect(model.diffFileID == "b.swift")

        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("b.swift"))
        await model.reload(for: screen)
        #expect(model.fileSelection.activeID == nil)
        #expect(model.diff == nil)
    }

    @Test func theFirstReloadOpensTheFileThatWasAskedFor() async throws {
        let repo = try GitRepo()
        try repo.write("a.swift", "one\n")
        try repo.write("b.swift", "two\n")
        let model = ChangesModel(root: repo.path, navigation: ChangesNavigationMemory())
        await model.reload(for: ChangesScreen(gitStats: GitStatsCache(), firstPath: "b.swift"))
        #expect(model.fileSelection.activeID == "b.swift")

        // Only the first read picks a file. After that the selection is the person's own.
        model.closeDiff()
        await model.reload(for: ChangesScreen(gitStats: GitStatsCache(), firstPath: "b.swift"))
        #expect(model.fileSelection.activeID == nil)
    }

    @Test func aReloadDropsCommitPicksForFilesThatAreGone() async throws {
        let repo = try GitRepo()
        try repo.write("a.swift", "one\n")
        let navigation = ChangesNavigationMemory()
        navigation.commitDraft(for: repo.path).excluded = ["a.swift", "gone.swift"]
        let model = ChangesModel(root: repo.path, navigation: navigation)
        await model.reload(for: ChangesScreen(gitStats: GitStatsCache()))
        #expect(navigation.commitDraft(for: repo.path).excluded == ["a.swift"])
    }

    @Test func amendTurnsOffOnceTheLastCommitIsPushed() async throws {
        let repo = try GitRepo()
        try repo.write("a.swift", "one\n")
        let file = GitChange(path: "a.swift", kind: .untracked, isStaged: false, isUnstaged: true, isBinary: false)
        var unpushed = GitSnapshot(state: .ready, root: repo.path, upstream: "origin/main", ahead: 1,
                                   lastCommitSubject: "first", files: [file])
        let navigation = ChangesNavigationMemory()
        let draft = navigation.commitDraft(for: repo.path)
        draft.message = "my message"
        draft.setAmend(true, lastMessage: "first")
        let reads = SnapshotQueue()
        let model = ChangesModel(root: repo.path, navigation: navigation, readSnapshot: { _, _ in reads.next() })
        let screen = ChangesScreen(gitStats: GitStatsCache())

        reads.snapshots = [unpushed]
        await model.reload(for: screen)
        #expect(draft.amend)

        unpushed.ahead = 0
        reads.snapshots = [unpushed]
        await model.reload(for: screen)
        #expect(!draft.amend)
        #expect(draft.message == "my message")
    }

    // The list said the file had changed lines, but git has none for it, so the list is
    // read again instead of an empty file being shown.
    @Test func anEmptyDiffForAFileWithCountedLinesReadsTheListAgain() async throws {
        let repo = try GitRepo()
        let stale = GitChange(path: "README.md", kind: .modified, isStaged: false, isUnstaged: true,
                              added: 1, removed: 0, isBinary: false)
        let reads = SnapshotQueue()
        reads.snapshots = [GitSnapshot(state: .ready, root: repo.path, files: [stale]),
                           GitSnapshot(state: .ready, root: repo.path)]
        let model = ChangesModel(root: repo.path, navigation: ChangesNavigationMemory(),
                                 readSnapshot: { _, _ in reads.next() })
        let screen = ChangesScreen(gitStats: GitStatsCache())

        // A reload opens the file without the check, so it cannot loop.
        await model.reload(for: screen)
        #expect(reads.count == 1)
        #expect(model.fileSelection.activeID == "README.md")

        await model.loadDiff(stale, at: repo.path, for: screen)
        #expect(reads.count == 2)
        #expect(model.snapshot?.files.isEmpty == true)
        #expect(model.fileSelection.activeID == nil)
        #expect(model.diff == nil)
    }

    @Test func aDiffForAFileThatIsNoLongerOpenIsDropped() async throws {
        let repo = try GitRepo()
        try repo.write("a.swift", "one\n")
        try repo.write("b.swift", "two\n")
        let model = ChangesModel(root: repo.path, navigation: ChangesNavigationMemory())
        let screen = ChangesScreen(gitStats: GitStatsCache())
        await model.reload(for: screen)
        let other = try #require(model.snapshot?.files.first { $0.id == "b.swift" })
        await model.loadDiff(other, at: repo.path, for: screen)
        #expect(model.diffFileID == "a.swift")
        #expect(!model.loadingDiff)
    }

    @Test func theHistoryKeepsItsCommitWhileTheLogStillHasIt() async throws {
        let repo = try GitRepo()
        try repo.write("README.md", "second")
        try repo.commit("second")
        let navigation = ChangesNavigationMemory()
        navigation.showingHistory = true
        let model = ChangesModel(root: repo.path, navigation: navigation)
        await model.reload(for: ChangesScreen(gitStats: GitStatsCache()))
        #expect(model.historySelection.commit?.subject == "second")
        #expect(navigation.commits[repo.path]?.count == 2)

        let older = try #require(model.commits?.last)
        model.historySelection.select(older)
        await model.loadHistory(at: repo.path)
        #expect(model.historySelection.commit?.subject == "first")
    }
}

@MainActor
private final class SnapshotQueue {
    var snapshots: [GitSnapshot] = []
    private(set) var count = 0

    func next() -> GitSnapshot {
        count += 1
        return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }
}

@MainActor
private final class SnapshotReads {
    var pending: [CheckedContinuation<GitSnapshot, Never>] = []

    func read(_ root: String) async -> GitSnapshot {
        await withCheckedContinuation { pending.append($0) }
    }
}
