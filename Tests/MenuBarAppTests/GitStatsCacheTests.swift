import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct GitStatsCacheTests {
    @Test func remembersTheLastReadySnapshotForAPath() {
        let cache = GitStatsCache()
        var snapshot = GitSnapshot(state: .ready)
        snapshot.files = [GitChange(path: "a.txt", originalPath: nil, kind: .modified,
                                    isStaged: false, isUnstaged: true,
                                    added: 3, removed: 1, isBinary: false)]
        cache.store(snapshot, at: "/repos/demo")
        #expect(cache.snapshot(at: "/repos/demo")?.totalAdded == 3)
        #expect(cache.snapshot(at: "/repos/other") == nil)
    }

    @Test func answersForEverySpellingOfTheSamePath() {
        let cache = GitStatsCache()
        cache.store(GitSnapshot(state: .ready), at: "/repos/demo/")
        #expect(cache.snapshot(at: "/repos/./demo") != nil)
    }

    @Test func dropsWhatItKnewWhenTheTreeCanNoLongerBeRead() {
        let cache = GitStatsCache()
        cache.store(GitSnapshot(state: .ready), at: "/repos/demo")
        cache.store(.state(.missingFolder), at: "/repos/demo")
        #expect(cache.snapshot(at: "/repos/demo") == nil)
    }
}
