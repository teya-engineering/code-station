import Foundation
import Testing
@testable import MenuBarApp

// The sweep deletes without being asked, so what it will and will not touch is the whole
// point of these. Nothing here runs git or removes anything: the git answer is faked, and
// what is checked is the decision made from it.
@MainActor
struct OldSessionSweepTests {
    private let testPreferences = TestPreferences()

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project
    private let runner: SessionRunner

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store)
        runner = SessionRunner(preferences: testPreferences.store, paths: [:])
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

    // The rule as it ships: on, asking about everything, orphans left alone.
    private let rule = CleanupRule(deletesOnItsOwn: true, asked: CleanupRule.askedByDefault,
                                   includesOrphans: false)

    private func rule(asking asked: Set<CleanupReason>, orphans: Bool = false) -> CleanupRule {
        CleanupRule(deletesOnItsOwn: true, asked: asked, includesOrphans: orphans)
    }

    private func orphan(at path: String) -> OrphanedWorktree {
        OrphanedWorktree(projectID: project.id, projectName: project.name,
                         projectPath: project.path, path: path,
                         branch: "code-station/orphan", allocatedBytes: 1_024)
    }

    nonisolated private func snapshot(changedFiles: Int, unpushed: Int = 0) -> GitSnapshot {
        var snapshot = GitSnapshot(state: .ready)
        snapshot.unpushedCommits = unpushed
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
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        let afterWarning = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
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
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        #expect(buffer.deletion?.sessions == 1)

        let second = agedSession()
        let deadline = firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod)
        let atDeadline = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: deadline)

        #expect(atDeadline == 1)
        #expect(store.session(first.id) == nil)
        #expect(store.session(second.id) != nil)

        _ = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: deadline)

        #expect(buffer.deletion == OldSessionSweep.Deletion(
            at: deadline.addingTimeInterval(OldSessionSweep.gracePeriod), sessions: 1))
        #expect(store.session(second.id) != nil)
    }

    @Test func armsNoMoreThanOneBatchAtATime() async throws {
        for _ in 0..<(OldSessionSweep.batchLimit + 5) { _ = agedSession() }
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
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
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
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
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))
        _ = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
            now: awake)
        let afterWarning = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
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
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        let afterWarning = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(duringWarning == 0)
        #expect(afterWarning == 0)
        #expect(store.session(old.id) != nil)
        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func takesAnUnbuiltDesignWhenTheAskListLeavesItOut() async throws {
        let old = agedSession(seed: .init(mode: .design))
        let artifact = try #require(store.designArtifactURL(for: old))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>kept</html>".utf8).write(to: artifact)
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, rule: rule(asking: []), store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule(asking: []), store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(deleted == 1)
        #expect(store.session(old.id) == nil)
        #expect(buffer.parked.isEmpty)
    }

    @Test func takesUncommittedChangesWhenTheAskListLeavesThemOut() async throws {
        let old = agedSession(worktreePath: try folderOnDisk())
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, rule: rule(asking: []), store: store, runner: runner,
            buffer: &buffer, now: firstSeen) { _ in self.snapshot(changedFiles: 1) }
        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule(asking: []), store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod)) { _ in
                self.snapshot(changedFiles: 1)
            }

        #expect(deleted == 1)
        #expect(store.session(old.id) == nil)
        #expect(buffer.parked.isEmpty)
    }

    @Test func takesNothingWhenTheSwitchIsOff() async throws {
        _ = agedSession()
        let off = CleanupRule(deletesOnItsOwn: false, asked: [], includesOrphans: true)
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(days: 7, rule: off, store: store, runner: runner,
                                      buffer: &buffer, now: Date())

        #expect(buffer.deletion == nil)
        #expect(buffer.parked.isEmpty)
    }

    // Git inspection yields to the app. Opening the session while that answer is on its
    // way must protect it just as opening it before the sweep starts does.
    @Test func keepsASessionOpenedWhileItsWorktreeIsBeingChecked() async throws {
        let store = store
        let old = agedSession(worktreePath: try folderOnDisk())
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        let duringWarning = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen) { _ in self.snapshot(changedFiles: 0) }

        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
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
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen) { _ in self.snapshot(changedFiles: 0) }

        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod)) { _ in
                await MainActor.run { store.setPinned(true, forSession: old.id) }
                return self.snapshot(changedFiles: 0)
            }

        #expect(deleted == 0)
        #expect(store.session(old.id)?.isPinned == true)
    }

    // MARK: - The ask list

    @Test func holdsAnUnreadSessionUntilItIsRead() async throws {
        let old = agedSession()
        store.setMarkedUnread(true, for: old.id)
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen)
        #expect(buffer.parked == [OldSessionSweep.Parked(item: .session(old.id),
                                                         reasons: [.unread])])
        #expect(buffer.deletion == nil)

        let afterWarning = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))
        #expect(afterWarning == 0)
        #expect(store.session(old.id) != nil)

        // Once read it is an ordinary old session again, and the sweep takes it on the
        // far side of its own warning hour.
        store.markRead(old.id)
        let readAt = firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod)
        _ = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: readAt)
        #expect(buffer.parked.isEmpty)
        #expect(buffer.deletion?.sessions == 1)

        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: readAt.addingTimeInterval(OldSessionSweep.gracePeriod))
        #expect(deleted == 1)
        #expect(store.session(old.id) == nil)
    }

    // A reason taken off the list stops holding anything back.
    @Test func takesAnUnreadSessionWhenUnreadIsNotAskedAbout() async throws {
        let old = agedSession()
        store.setMarkedUnread(true, for: old.id)
        let firstSeen = Date()
        let rule = rule(asking: [.unpushedCommits, .snoozed])
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(days: 7, rule: rule, store: store, runner: runner,
                                      buffer: &buffer, now: firstSeen)
        #expect(buffer.parked.isEmpty)
        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(deleted == 1)
        #expect(store.session(old.id) == nil)
    }

    // A snoozed session is shown once old rather than hidden, and waits for a yes.
    @Test func holdsAnOldSnoozedSessionForAYes() async throws {
        let old = agedSession()
        store.snooze(old.id, .untilWoken)
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(days: 7, rule: rule, store: store, runner: runner,
                                      buffer: &buffer, now: firstSeen)
        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(deleted == 0)
        #expect(buffer.parked == [OldSessionSweep.Parked(item: .session(old.id),
                                                         reasons: [.snoozed])])
    }

    @Test func holdsCommitsThatNoRemoteHasOnlyWhileTheyAreAskedAbout() async throws {
        let old = agedSession(worktreePath: try folderOnDisk())
        let firstSeen = Date()
        let inspect: SessionCost.Inspect = { _ in self.snapshot(changedFiles: 0, unpushed: 2) }
        var asking = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(days: 7, rule: rule, store: store, runner: runner,
                                      buffer: &asking, now: firstSeen, inspect: inspect)
        #expect(asking.parked == [OldSessionSweep.Parked(item: .session(old.id),
                                                         reasons: [.unpushedCommits])])
        #expect(asking.deletion == nil)

        var notAsking = OldSessionSweep.EligibilityBuffer()
        _ = await OldSessionSweep.run(days: 7, rule: rule(asking: []), store: store,
                                      runner: runner, buffer: &notAsking, now: firstSeen,
                                      inspect: inspect)
        #expect(notAsking.parked.isEmpty)
        #expect(notAsking.deletion?.sessions == 1)
    }

    @Test func holdsASessionThatWouldLoseWorkAndDeletesTheSafeOnes() async throws {
        let dirtyWorktree = try folderOnDisk()
        let dirty = agedSession(worktreePath: dirtyWorktree)
        let clean = agedSession()
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()
        let inspect: SessionCost.Inspect = { path in
            self.snapshot(changedFiles: path == dirtyWorktree ? 2 : 0)
        }

        _ = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen, inspect: inspect)
        #expect(buffer.parked == [OldSessionSweep.Parked(item: .session(dirty.id),
                                                         reasons: [.uncommittedChanges])])
        #expect(buffer.deletion?.sessions == 1)

        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod),
            inspect: inspect)

        #expect(deleted == 1)
        #expect(store.session(clean.id) == nil)
        #expect(store.session(dirty.id) != nil)
        #expect(buffer.parked.map(\.sessionID) == [dirty.id])
    }

    // Work started during the warning hour is held for a yes rather than quietly skipped.
    @Test func holdsASessionThatGainsWorkDuringTheWarningHour() async throws {
        let old = agedSession(worktreePath: try folderOnDisk())
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer, now: firstSeen) { _ in self.snapshot(changedFiles: 0) }
        #expect(buffer.deletion?.sessions == 1)

        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner,
            buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod)) { _ in
                self.snapshot(changedFiles: 1)
            }

        #expect(deleted == 0)
        #expect(store.session(old.id) != nil)
        #expect(buffer.parked == [OldSessionSweep.Parked(item: .session(old.id),
                                                         reasons: [.uncommittedChanges])])
    }

    // Keep on a row of the countdown puts the session off for a week, which takes it out
    // of the cohort at once, so the countdown ending does not take it.
    @Test func doesNotTakeASessionKeptFromTheCohort() async throws {
        let kept = agedSession()
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()
        _ = await OldSessionSweep.run(days: 7, rule: rule, store: store, runner: runner,
                                      buffer: &buffer, now: firstSeen)
        #expect(buffer.cohort == [kept.id])

        store.deferCleanup(of: kept.id, until: firstSeen.addingTimeInterval(OldSessions.deferral))
        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod))

        #expect(deleted == 0)
        #expect(store.session(kept.id) != nil)
        #expect(buffer.parked.isEmpty)
    }

    // MARK: - Orphaned worktrees

    @Test func takesACleanOrphanWithTheCountdownAndHoldsADirtyOne() async throws {
        let clean = orphan(at: try folderOnDisk())
        let dirty = orphan(at: try folderOnDisk())
        let firstSeen = Date()
        let rule = rule(asking: CleanupRule.askedByDefault, orphans: true)
        let inspect: SessionCost.Inspect = { path in
            self.snapshot(changedFiles: path == dirty.path ? 1 : 0)
        }
        var pruned: [String] = []
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(days: 7, rule: rule, store: store, runner: runner,
                                      buffer: &buffer, now: firstSeen,
                                      orphans: [clean, dirty], inspect: inspect)
        #expect(buffer.deletion?.worktrees == 1)
        #expect(buffer.deletion?.sessions == 0)
        #expect(buffer.parked == [OldSessionSweep.Parked(item: .worktree(dirty.id),
                                                         reasons: [.uncommittedChanges])])

        let deleted = await OldSessionSweep.run(
            days: 7, rule: rule, store: store, runner: runner, buffer: &buffer,
            now: firstSeen.addingTimeInterval(OldSessionSweep.gracePeriod),
            orphans: [clean, dirty],
            inspect: inspect,
            pruneOrphans: { worktrees in
                pruned += worktrees.map(\.path)
                return worktrees.count
            })

        #expect(deleted == 1)
        #expect(pruned == [clean.path])
        #expect(buffer.parked.map(\.item) == [.worktree(dirty.id)])
    }

    @Test func leavesOrphansAloneUnlessAskedToTreatThemLikeOldSessions() async throws {
        let clean = orphan(at: try folderOnDisk())
        var buffer = OldSessionSweep.EligibilityBuffer()

        _ = await OldSessionSweep.run(days: 7, rule: rule, store: store, runner: runner,
                                      buffer: &buffer, now: Date(), orphans: [clean]) { _ in
            Issue.record("An orphan should not be read when orphans are left alone")
            return self.snapshot(changedFiles: 0)
        }

        #expect(buffer.deletion == nil)
        #expect(buffer.parked.isEmpty)
    }

    // MARK: - What the strip says

    @Test func stripNamesWhatGoesAndWhatWaits() {
        let deletion = OldSessionSweep.Deletion(at: now, sessions: 6, worktrees: 1)
        #expect(CleanupStrip.deletionTitle(deletion) == "7 will be deleted")
        #expect(CleanupStrip.deletionDetail(deletion) == "6 sessions, 1 worktree")
        #expect(CleanupStrip.deletionDetail(.init(at: now, sessions: 1)) == "1 session")

        let parked = [
            OldSessionSweep.Parked(item: .session(UUID()), reasons: [.uncommittedChanges]),
            OldSessionSweep.Parked(item: .session(UUID()), reasons: [.unread, .unbuiltDesign]),
            OldSessionSweep.Parked(item: .worktree("/w"), reasons: [.uncommittedChanges]),
            OldSessionSweep.Parked(item: .session(UUID()), reasons: [.unread]),
            OldSessionSweep.Parked(item: .session(UUID()), reasons: [.snoozed])
        ]
        #expect(CleanupStrip.waitingTitle(parked) == "5 waiting for your OK")
        #expect(CleanupStrip.waitingDetail(parked) == "3 hold work · 2 not seen yet")
        #expect(CleanupStrip.waitingDetail(Array(parked.prefix(1))) == "1 holds work")
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
