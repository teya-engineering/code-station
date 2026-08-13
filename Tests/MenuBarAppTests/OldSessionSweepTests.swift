import Foundation
import Testing
@testable import MenuBarApp

// The sweep deletes without being asked, so what it will and will not touch is the whole
// point of these. Nothing here runs git or removes anything: the git answer is faked, and
// what is checked is the decision made from it.
@MainActor
struct OldSessionSweepTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(daysAgo: Double, worktree: String? = nil) -> ChatSession {
        var session = ChatSession(projectID: UUID())
        session.createdAt = now.addingTimeInterval(-daysAgo * 86_400)
        session.worktreePath = worktree
        return session
    }

    // A folder that is really there, since "is this worktree still on disk?" is answered
    // by the file system rather than by the fake.
    private func folderOnDisk() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    nonisolated private func snapshot(changedFiles: Int) -> GitSnapshot {
        var snapshot = GitSnapshot(state: .ready)
        snapshot.files = (0..<changedFiles).map {
            GitChange(path: "file-\($0).swift", kind: .modified, isStaged: false,
                      isUnstaged: true, added: 3, removed: 1, isBinary: false)
        }
        return snapshot
    }

    // MARK: - What the sweep picks up

    @Test func takesOnlyWhatHasGoneQuietAndIsNotRunning() {
        let running = session(daysAgo: 30)
        let sessions = [session(daysAgo: 0.5), running, session(daysAgo: 8)]

        let due = OldSessionSweep.due(days: 7, in: sessions, now: now) { $0 == running.id }

        #expect(due.map(\.id) == [sessions[2].id])
    }

    @Test func clearsALongBacklogOverSeveralPasses() {
        let sessions = (0..<(OldSessionSweep.batchLimit + 20)).map {
            session(daysAgo: 8 + Double($0))
        }

        let due = OldSessionSweep.due(days: 7, in: sessions, now: now) { _ in false }

        #expect(due.count == OldSessionSweep.batchLimit)
        // Oldest first, so the backlog is worked through from the far end.
        #expect(due.first?.id == sessions.last?.id)
    }

    // MARK: - What git has to say first

    @Test func aSessionWithNoWorktreeCostsOnlyItsHistory() async {
        let outcome = await SessionCost.settledOutcome(worktrees: []) { _ in
            Issue.record("git should not be asked about a session with no worktree")
            return .state(.failed("unexpected"))
        }
        #expect(outcome == .historyOnly)
    }

    @Test func aWorktreeAlreadyGoneFromDiskCostsOnlyItsHistory() async {
        let outcome = await SessionCost.settledOutcome(worktrees: ["/nowhere/gone"]) { _ in
            Issue.record("git should not be asked about a worktree that is not there")
            return .state(.failed("unexpected"))
        }
        #expect(outcome == .historyOnly)
    }

    @Test func anEmptyWorktreeIsSafeToTakeUnattended() async throws {
        let path = try folderOnDisk()
        let outcome = await SessionCost.settledOutcome(worktrees: [path]) { _ in
            self.snapshot(changedFiles: 0)
        }
        #expect(outcome == .worktreeRemoved)
        #expect(outcome.losesNothing)
    }

    @Test func uncommittedWorkIsLeftForAPersonToDecideOn() async throws {
        let path = try folderOnDisk()
        let outcome = await SessionCost.settledOutcome(worktrees: [path]) { _ in
            self.snapshot(changedFiles: 2)
        }
        #expect(outcome == .wouldLoseWork(added: 6, removed: 2))
        #expect(!outcome.losesNothing)
    }

    // Silence from git is not the same as an empty worktree, and only one of the two is
    // safe to act on.
    @Test func aWorktreeGitCouldNotReadIsNeverTakenUnattended() async throws {
        let path = try folderOnDisk()
        let outcome = await SessionCost.settledOutcome(worktrees: [path]) { _ in
            .state(.failed("git exploded"))
        }
        #expect(outcome == .checkFailed)
        #expect(!outcome.losesNothing)
    }

    // A workspace session holds several checkouts, and any one of them holding work is
    // enough to keep the whole session.
    @Test func oneDirtyCheckoutKeepsAWorkspaceSession() async throws {
        let clean = try folderOnDisk()
        let dirty = try folderOnDisk()
        let outcome = await SessionCost.settledOutcome(worktrees: [clean, dirty]) { path in
            self.snapshot(changedFiles: path == dirty ? 1 : 0)
        }
        #expect(outcome == .wouldLoseWork(added: 3, removed: 1))
    }
}
