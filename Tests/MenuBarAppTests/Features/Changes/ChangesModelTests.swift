import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ChangesModelTests {
    @Test func aProjectsModelStartsOnTheComparisonAskedForAndKeepsItsOwn() {
        let models = ChangesModels()
        #expect(models.model(for: "/session", comparingToRemote: true).comparesToRemote)
        #expect(!models.model(for: "/project").comparesToRemote)

        // Once made, a model keeps what the person picked, whatever a later draw asks for.
        models.model(for: "/session").comparesToRemote = false
        #expect(!models.model(for: "/session", comparingToRemote: true).comparesToRemote)
    }

    @Test func aLateRefreshCannotReplaceTheNewerSnapshot() async {
        let reads = SnapshotReads()
        let model = ChangesModel(readSnapshot: { root, _, _ in await reads.read(root) })
        let stats = GitStatsCache()
        let first = Task { await model.reload(root: "/repo", fetchOrigin: false, gitStats: stats, onError: { _ in }) }
        #expect(await waitUntil { reads.pending.count == 1 })
        let second = Task { await model.reload(root: "/repo", fetchOrigin: false, gitStats: stats, onError: { _ in }) }
        #expect(await waitUntil { reads.pending.count == 2 })
        reads.pending[1].resume(returning: GitSnapshot(state: .ready, root: "/repo", branch: "newer", hasCommits: false))
        #expect(await second.value)
        reads.pending[0].resume(returning: GitSnapshot(state: .ready, root: "/repo", branch: "older", hasCommits: false))
        #expect(await first.value == false)
        #expect(model.snapshot?.branch == "newer")
        #expect(!model.loading)
    }

    @Test func cancellationClearsLoadingWithoutPublishingTheResult() async {
        let reads = SnapshotReads()
        let model = ChangesModel(readSnapshot: { root, _, _ in await reads.read(root) })
        let task = Task { await model.reload(root: "/repo", fetchOrigin: false, gitStats: GitStatsCache(), onError: { _ in }) }
        #expect(await waitUntil { reads.pending.count == 1 })
        task.cancel()
        reads.pending[0].resume(returning: GitSnapshot(state: .ready, root: "/repo", hasCommits: false))
        #expect(await task.value == false)
        #expect(model.snapshot == nil)
        #expect(!model.loading)
    }

    @Test func showingADiffSwapsTheFileItsTextAndItsThreadsTogether() async {
        let model = ChangesModel()
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
        let model = ChangesModel()
        await model.showDiff(FileDiff(lines: [DiffLine(id: 0, kind: .addition, text: "+code")]), of: "a.swift",
                             language: nil, scale: 1, comments: DiffComments(threads: [0]))
        await model.showDiff(FileDiff(note: "Binary file"), of: "b.png", language: nil, scale: 1, comments: nil)
        #expect(model.diffFileID == "b.png")
        #expect(model.diff?.note == "Binary file")
        #expect(model.diffText == nil)
        #expect(model.renderedThreads.isEmpty)
    }
}

@MainActor
private final class SnapshotReads {
    var pending: [CheckedContinuation<GitSnapshot, Never>] = []

    func read(_ root: String) async -> GitSnapshot {
        await withCheckedContinuation { pending.append($0) }
    }
}
