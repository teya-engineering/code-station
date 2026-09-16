import Foundation
import Testing
@testable import MenuBarApp

// The sweep deletes without being asked, so what it will and will not touch is the whole
// point of these. Nothing here runs git or removes anything: the git answer is faked, and
// what is checked is the decision made from it.
@MainActor
struct OldSessionSweepTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project
    private let runner: SessionRunner

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
        runner = SessionRunner(paths: [:])
    }

    private func session(daysAgo: Double, worktree: String? = nil) -> ChatSession {
        var session = ChatSession(projectID: UUID())
        session.createdAt = now.addingTimeInterval(-daysAgo * 86_400)
        session.worktreePath = worktree
        return session
    }

    // A session in the store that went quiet over a week ago, beside a fresh one that
    // the sweep must leave alone.
    private func agedSession(seed: ProjectStore.SessionSeed = .init(),
                             worktreePath: String? = nil) -> ChatSession {
        let old = store.newSession(in: project.id, worktreePath: worktreePath, seed: seed)
        store.append(ChatMessage(role: .user, text: "Old work",
                                 date: Date().addingTimeInterval(-8 * 86_400)),
                     to: old.id)
        _ = store.newSession(in: project.id)
        return old
    }

    // A folder that is really there, since "is this worktree still on disk?" is answered
    // by the file system rather than by the fake.
    private func folderOnDisk() throws -> String {
        let url = scratch.path("sweep-\(UUID().uuidString)")
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

    @Test func takesOnlyWhatHasGoneQuietAndIsNeitherOpenNorRunning() {
        let running = session(daysAgo: 30)
        let open = session(daysAgo: 20)
        var pinned = session(daysAgo: 40)
        pinned.isPinned = true
        let sessions = [session(daysAgo: 0.5), running, open, pinned, session(daysAgo: 8)]

        let due = OldSessionSweep.due(days: 7, in: sessions, now: now,
                                      isBusy: { $0 == running.id },
                                      isOpen: { $0 == open.id })

        #expect(due.map(\.id) == [sessions[4].id])
    }

    @Test func offersABacklogOldestFirst() {
        let sessions = (0..<(OldSessionSweep.batchLimit + 20)).map {
            session(daysAgo: 8 + Double($0))
        }

        let due = OldSessionSweep.due(days: 7, in: sessions, now: now,
                                      isBusy: { _ in false },
                                      isOpen: { _ in false })

        #expect(due.count == sessions.count)
        // Oldest first, so a capped cohort works through the backlog from the far end.
        #expect(due.first?.id == sessions.last?.id)
    }

    @Test func countsDownForTheCohortItArmed() {
        let first = UUID()
        let second = UUID()
        var buffer = OldSessionSweep.EligibilityBuffer()

        #expect(buffer.deletion == nil)
        #expect(buffer.canArm(now: now))
        buffer.arm([first, second], now: now)

        #expect(buffer.deletion == OldSessionSweep.Deletion(
            at: now.addingTimeInterval(OldSessionSweep.gracePeriod), sessions: 2))
        #expect(!buffer.isDue(now: now.addingTimeInterval(OldSessionSweep.gracePeriod - 1)))
        #expect(buffer.isDue(now: now.addingTimeInterval(OldSessionSweep.gracePeriod)))
    }

    // The number beside the countdown is a promise about a fixed set, so a session that
    // goes quiet while the clock runs waits for the next cohort instead of joining this
    // one behind the count that has already been shown.
    @Test func doesNotTakeOnMoreSessionsOnceTheCountdownHasStarted() {
        let armed = UUID()
        let newlyOld = UUID()
        var buffer = OldSessionSweep.EligibilityBuffer()
        buffer.arm([armed], now: now)

        let halfway = now.addingTimeInterval(OldSessionSweep.gracePeriod / 2)
        #expect(!buffer.canArm(now: halfway))
        buffer.keepOnly([armed, newlyOld])

        #expect(buffer.cohort == [armed])
        #expect(buffer.deletion?.sessions == 1)
    }

    @Test func dropsASessionThatStopsBeingEligibleWhileTheCohortWaits() {
        let kept = UUID()
        let takenBack = UUID()
        var buffer = OldSessionSweep.EligibilityBuffer()
        buffer.arm([kept, takenBack], now: now)

        buffer.keepOnly([kept])

        #expect(buffer.cohort == [kept])
        #expect(buffer.deletion?.sessions == 1)
    }

    @Test func standsDownWhenEveryMemberOfTheCohortLeaves() {
        var buffer = OldSessionSweep.EligibilityBuffer()
        buffer.arm([UUID()], now: now)

        buffer.keepOnly([])

        #expect(buffer.deletion == nil)
        #expect(buffer.canArm(now: now))
    }

    // Settling a cohort reads git, so finding nothing safe to take must not turn into a
    // worktree read every second.
    @Test func waitsBeforeLookingAgainWhenNothingCanBeTaken() {
        var buffer = OldSessionSweep.EligibilityBuffer()
        buffer.arm([], now: now)

        #expect(buffer.deletion == nil)
        #expect(!buffer.canArm(
            now: now.addingTimeInterval(OldSessionSweep.retryInterval - 1)))
        #expect(buffer.canArm(now: now.addingTimeInterval(OldSessionSweep.retryInterval)))
    }

    @Test func deletesAStillEligibleSessionAfterTheWarningHour() async throws {
        let old = agedSession()
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        let duringWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        let afterWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(duringWarning == 0)
        #expect(afterWarning == 1)
        #expect(store.session(old.id) == nil)
    }

    // A session that goes quiet while the countdown runs is not swept up by a deadline
    // that was set, and counted, before it was old. It gets a cohort, and an hour, of
    // its own.
    @Test func leavesASessionThatGoesQuietDuringTheCountdownForTheNextCohort() async throws {
        let first = agedSession()
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        #expect(buffer.deletion?.sessions == 1)

        let second = agedSession()
        let deadline = firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod)
        let atDeadline = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer, now: deadline)

        #expect(atDeadline == 1)
        #expect(store.session(first.id) == nil)
        #expect(store.session(second.id) != nil)

        _ = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer, now: deadline)

        #expect(buffer.deletion == OldSessionSweep.Deletion(
            at: deadline.addingTimeInterval(OldSessionSweep.gracePeriod), sessions: 1))
        #expect(store.session(second.id) != nil)
    }

    @Test func armsNoMoreThanOneBatchAtATime() async throws {
        for _ in 0..<(OldSessionSweep.batchLimit + 5) { _ = agedSession() }
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer, now: Date())

        #expect(buffer.deletion?.sessions == OldSessionSweep.batchLimit)
    }

    // Snooze stops the unattended deletion behind the countdown as well as the offer in
    // the sheet, so nothing of that project goes before the deadline it was given.
    @Test func takesNothingFromASnoozedProject() async throws {
        let old = agedSession()
        let firstSeen = Date()
        store.snoozeCleanup(forProject: project.id, now: firstSeen)
        var buffer = OldSessionSweep.EligibilityBuffer()

        let afterWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(afterWarning == 0)
        #expect(store.session(old.id) != nil)
    }

    // The snooze expires on its own, and the session it was protecting is picked up again
    // on the far side of a fresh warning hour without anyone clearing anything.
    @Test func takesTheSessionOnceTheSnoozeHasRunOut() async throws {
        let old = agedSession()
        let firstSeen = Date()
        store.snoozeCleanup(forProject: project.id, now: firstSeen)
        var buffer = OldSessionSweep.EligibilityBuffer()
        let awake = firstSeen.addingTimeInterval(ProjectSnooze.step + 1)

        let whileSnoozed = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))
        _ = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner, buffer: &buffer,
            now: awake)
        let afterWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner, buffer: &buffer,
            now: awake.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(whileSnoozed == 0)
        #expect(afterWarning == 1)
        #expect(store.session(old.id) == nil)
    }

    @Test func keepsAnOldDesignSessionThatContainsGeneratedFiles() async throws {
        let old = agedSession(seed: .init(mode: .design))
        let artifact = try #require(store.designArtifactURL(for: old))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>kept</html>".utf8).write(to: artifact)
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        let duringWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        let afterWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(duringWarning == 0)
        #expect(afterWarning == 0)
        #expect(store.session(old.id) != nil)
        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func deletesGeneratedDesignFilesWhenThePolicyIncludesSavedWork() async throws {
        let old = agedSession(seed: .init(mode: .design))
        let artifact = try #require(store.designArtifactURL(for: old))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>deleted</html>".utf8).write(to: artifact)
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        let duringWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteAll, store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        let afterWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteAll, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(duringWarning == 0)
        #expect(afterWarning == 1)
        #expect(store.session(old.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func deletesAWorktreeWithoutCheckingForChangesWhenThePolicyIncludesSavedWork()
        async throws {
        let worktree = try folderOnDisk()
        let old = agedSession(worktreePath: worktree)
        let worktrees = WorktreeOperations(
            addProject: { _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected add"))
            },
            addWorkspaceProject: { _, _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected add"))
            },
            remove: { path, _, _ in
                #expect(path == worktree)
                return .success(())
            })
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, policy: .deleteAll, store: store, runner: runner,
            buffer: &buffer, now: firstSeen, worktreeOperations: worktrees) { _ in
                Issue.record("Delete-all should not inspect the worktree")
                return self.snapshot(changedFiles: 1)
            }
        let deleted = await OldSessionSweep.run(
            days: 7, policy: .deleteAll, store: store, runner: runner,
            buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod),
            worktreeOperations: worktrees) { _ in
                Issue.record("Delete-all should not inspect the worktree")
                return self.snapshot(changedFiles: 1)
            }

        #expect(deleted == 1)
        #expect(store.session(old.id) == nil)
    }

    // Git inspection yields to the app. Opening the session while that answer is on its
    // way must protect it just as opening it before the sweep starts does.
    @Test func keepsASessionOpenedWhileItsWorktreeIsBeingChecked() async throws {
        let store = store
        let old = agedSession(worktreePath: try folderOnDisk())
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        let duringWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer, now: firstSeen) { _ in self.snapshot(changedFiles: 0) }

        let deleted = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod)) { _ in
                await MainActor.run { store.selectSession(old.id) }
                return self.snapshot(changedFiles: 0)
            }

        #expect(duringWarning == 0)
        #expect(deleted == 0)
        #expect(store.session(old.id) != nil)
        #expect(store.selection == .session(old.id))
    }

    @Test func keepsASessionPinnedWhileItsWorktreeIsBeingChecked() async throws {
        let store = store
        let old = agedSession(worktreePath: try folderOnDisk())
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer, now: firstSeen) { _ in self.snapshot(changedFiles: 0) }

        let deleted = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store, runner: runner,
            buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod)) { _ in
                await MainActor.run { store.setPinned(true, forSession: old.id) }
                return self.snapshot(changedFiles: 0)
            }

        #expect(deleted == 0)
        #expect(store.session(old.id)?.isPinned == true)
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

    @Test func checksOnlyWorkspaceWorktreesThatStillExist() async throws {
        let existing = try folderOnDisk()
        let outcome = await SessionCost.settledOutcome(
            worktrees: ["/nowhere/gone", existing]
        ) { path in
            path == existing ? self.snapshot(changedFiles: 0) : .state(.failed("unexpected"))
        }

        #expect(outcome == .worktreeRemoved)
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
