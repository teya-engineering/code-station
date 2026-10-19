import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

@MainActor
struct ChangesModelTests {
    @Test func aLateRefreshCannotReplaceTheNewerSnapshot() async {
        let reads = SnapshotReads()
        let model = ChangesModel(readSnapshot: { await reads.read($0) })
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
        let model = ChangesModel(readSnapshot: { await reads.read($0) })
        let task = Task { await model.reload(root: "/repo", fetchOrigin: false, gitStats: GitStatsCache(), onError: { _ in }) }
        #expect(await waitUntil { reads.pending.count == 1 })
        task.cancel()
        reads.pending[0].resume(returning: GitSnapshot(state: .ready, root: "/repo", hasCommits: false))
        #expect(await task.value == false)
        #expect(model.snapshot == nil)
        #expect(!model.loading)
    }
}

@MainActor
private final class SnapshotReads {
    var pending: [CheckedContinuation<GitSnapshot, Never>] = []

    func read(_ root: String) async -> GitSnapshot {
        await withCheckedContinuation { pending.append($0) }
    }
}
