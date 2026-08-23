import Foundation
import Testing
@testable import MenuBarApp

// What counts as an old session, and what clearing one would cost. Nothing here deletes
// anything: the point of these is that the offer the sheet makes is the true one.
struct OldSessionsTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(daysAgo: Double, worktree: String? = nil) -> ChatSession {
        var session = ChatSession(projectID: UUID())
        session.createdAt = now.addingTimeInterval(-daysAgo * 86_400)
        session.worktreePath = worktree
        return session
    }

    @Test func picksOnlyWhatHasGoneQuietForLongEnough() {
        let sessions = [session(daysAgo: 0.5), session(daysAgo: 8), session(daysAgo: 30)]
        let old = OldSessions.olderThan(7, in: sessions, now: now)
        #expect(old.count == 2)
        // Oldest first: it is the one most likely to be cleared, so it is read first.
        #expect(old.first?.id == sessions[2].id)
    }

    // The threshold is counted from the last turn rather than from when the session was
    // made, so a long conversation started weeks ago is not old while it is still in use.
    @Test func countsFromTheLastTurnRatherThanTheStart() {
        var session = session(daysAgo: 30)
        session.summary.lastMessageAt = now.addingTimeInterval(-3_600)
        #expect(OldSessions.olderThan(7, in: [session], now: now).isEmpty)
    }

    @Test func aSessionOnTheThresholdIsNotOldYet() {
        #expect(OldSessions.olderThan(7, in: [session(daysAgo: 6.99)], now: now).isEmpty)
        #expect(OldSessions.olderThan(7, in: [session(daysAgo: 7.01)], now: now).count == 1)
    }

    @Test func oneDayMeansTwentyFourHours() {
        #expect(OldSessions.olderThan(1, in: [session(daysAgo: 23.99 / 24)], now: now).isEmpty)
        #expect(OldSessions.olderThan(1, in: [session(daysAgo: 24.01 / 24)], now: now).count == 1)
    }

    // Only what costs nothing but history arrives ticked. A worktree is left alone until
    // git has answered, so a slow repository cannot leave a box ticked unread.
    @Test func ticksOnlyTheOutcomesThatLoseNothing() {
        #expect(SessionOutcome.historyOnly.losesNothing)
        #expect(SessionOutcome.worktreeRemoved.losesNothing)
        #expect(!SessionOutcome.checking.losesNothing)
        #expect(!SessionOutcome.checkFailed.losesNothing)
        #expect(!SessionOutcome.wouldLoseWork(added: 64, removed: 0).losesNothing)
    }

    @Test func onlySelectsSessionsWhoseWorktreeCheckFinished() {
        #expect(SessionOutcome.historyOnly.canSelect)
        #expect(SessionOutcome.worktreeRemoved.canSelect)
        #expect(SessionOutcome.wouldLoseWork(added: 1, removed: 0).canSelect)
        #expect(!SessionOutcome.checking.canSelect)
        #expect(!SessionOutcome.checkFailed.canSelect)
    }

    @Test func designArtifactsAreWorkThatDeletionWouldLose() {
        let design = SessionRemovalCost(worktree: .historyOnly,
                                        deletesDesignArtifacts: true)

        #expect(!design.losesNothing)
        #expect(design.losesWork)
        #expect(design.canSelect)
        #expect(design.label == "would delete design")
    }

    @Test func saysHowLongAgoTheLastTurnWas() {
        #expect(SessionAge.phrase(since: now.addingTimeInterval(-3_600), now: now) == "today")
        #expect(SessionAge.phrase(since: now.addingTimeInterval(-86_400), now: now) == "yesterday")
        #expect(SessionAge.phrase(since: now.addingTimeInterval(-12 * 86_400), now: now) == "12 days ago")
        // A clock that has gone backwards should read as "today", not as a negative count.
        #expect(SessionAge.phrase(since: now.addingTimeInterval(600), now: now) == "today")
    }
}
