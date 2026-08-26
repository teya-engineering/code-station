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

    @Test func takesOnlyWhatHasGoneQuietAndIsNeitherOpenNorRunning() {
        let running = session(daysAgo: 30)
        let open = session(daysAgo: 20)
        let sessions = [session(daysAgo: 0.5), running, open, session(daysAgo: 8)]

        let due = OldSessionSweep.due(days: 7, in: sessions, now: now,
                                      isBusy: { $0 == running.id },
                                      isOpen: { $0 == open.id })

        #expect(due.map(\.id) == [sessions[3].id])
    }

    @Test func clearsALongBacklogOverSeveralPasses() {
        let sessions = (0..<(OldSessionSweep.batchLimit + 20)).map {
            session(daysAgo: 8 + Double($0))
        }

        let due = OldSessionSweep.due(days: 7, in: sessions, now: now,
                                      isBusy: { _ in false },
                                      isOpen: { _ in false })

        #expect(due.count == OldSessionSweep.batchLimit)
        // Oldest first, so the backlog is worked through from the far end.
        #expect(due.first?.id == sessions.last?.id)
    }

    @Test func waitsAnHourAfterAnOldSessionIsFirstSeen() {
        let old = session(daysAgo: 8)
        var buffer = OldSessionSweep.EligibilityBuffer()

        #expect(buffer.nextReadyAt == nil)
        #expect(buffer.ready([old], now: now).isEmpty)
        #expect(buffer.nextReadyAt == now.addingTimeInterval(OldSessionSweep.gracePeriod))
        #expect(buffer.ready(
            [old], now: now.addingTimeInterval(OldSessionSweep.gracePeriod - 1)).isEmpty)
        #expect(buffer.ready(
            [old], now: now.addingTimeInterval(OldSessionSweep.gracePeriod)).map(\.id)
                == [old.id])

        buffer.remove(old.id)
        #expect(buffer.nextReadyAt == nil)
    }

    @Test func givesANewlyEligibleSessionAnHourWhileTheAppIsOpen() {
        let newlyOld = session(daysAgo: 7)
        var buffer = OldSessionSweep.EligibilityBuffer()

        #expect(buffer.ready([], now: now).isEmpty)
        #expect(buffer.ready(
            [newlyOld], now: now.addingTimeInterval(OldSessionSweep.gracePeriod)).isEmpty)
        #expect(buffer.ready(
            [newlyOld],
            now: now.addingTimeInterval(OldSessionSweep.gracePeriod * 2 - 1)).isEmpty)
        #expect(buffer.ready(
            [newlyOld],
            now: now.addingTimeInterval(OldSessionSweep.gracePeriod * 2)).map(\.id)
                == [newlyOld.id])
    }

    @Test func startsANewHourWhenASessionBecomesEligibleAgain() {
        let old = session(daysAgo: 8)
        var buffer = OldSessionSweep.EligibilityBuffer()

        #expect(buffer.ready([old], now: now).isEmpty)
        #expect(buffer.ready(
            [], now: now.addingTimeInterval(OldSessionSweep.gracePeriod / 2)).isEmpty)
        #expect(buffer.ready(
            [old], now: now.addingTimeInterval(OldSessionSweep.gracePeriod * 2)).isEmpty)
    }

    @Test func deletesAStillEligibleSessionAfterTheWarningHour() async throws {
        let store = ProjectStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-old-session-sweep-\(UUID().uuidString).json"))
        let project = try #require(store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)")))
        let old = store.newSession(in: project.id)
        store.append(ChatMessage(role: .user, text: "Old work",
                                 date: Date().addingTimeInterval(-8 * 86_400)),
                     to: old.id)
        _ = store.newSession(in: project.id)
        let firstSeen = Date()
        let runner = SessionRunner(paths: [:])
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

    @Test func keepsAnOldDesignSessionThatContainsGeneratedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-old-design-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))
        let project = try #require(store.addProject(at: projectURL))
        let old = store.newSession(in: project.id, seed: .init(mode: .design))
        store.append(ChatMessage(role: .user, text: "Old design",
                                 date: Date().addingTimeInterval(-8 * 86_400)),
                     to: old.id)
        _ = store.newSession(in: project.id)
        let artifact = try #require(store.designArtifactURL(for: old))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>kept</html>".utf8).write(to: artifact)
        let firstSeen = Date()
        let runner = SessionRunner(paths: [:])
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-old-design-delete-all-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))
        let project = try #require(store.addProject(at: projectURL))
        let old = store.newSession(in: project.id, seed: .init(mode: .design))
        store.append(ChatMessage(role: .user, text: "Old design",
                                 date: Date().addingTimeInterval(-8 * 86_400)),
                     to: old.id)
        _ = store.newSession(in: project.id)
        let artifact = try #require(store.designArtifactURL(for: old))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>deleted</html>".utf8).write(to: artifact)
        let firstSeen = Date()
        let runner = SessionRunner(paths: [:])
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-old-worktree-delete-all-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let worktree = try folderOnDisk()
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))
        let project = try #require(store.addProject(at: projectURL))
        let old = store.newSession(in: project.id, worktreePath: worktree)
        store.append(ChatMessage(role: .user, text: "Old work",
                                 date: Date().addingTimeInterval(-8 * 86_400)),
                     to: old.id)
        _ = store.newSession(in: project.id)
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
        let runner = SessionRunner(paths: [:])
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
        let store = ProjectStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-old-session-sweep-\(UUID().uuidString).json"))
        let project = try #require(store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)")))
        let worktree = try folderOnDisk()
        let old = store.newSession(in: project.id, worktreePath: worktree)
        store.append(ChatMessage(role: .user, text: "Old work",
                                 date: Date().addingTimeInterval(-8 * 86_400)),
                     to: old.id)
        _ = store.newSession(in: project.id)
        let firstSeen = Date()
        var buffer = OldSessionSweep.EligibilityBuffer()

        let duringWarning = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store,
            runner: SessionRunner(paths: [:]),
            buffer: &buffer, now: firstSeen) { _ in
                Issue.record("git should not be checked during the warning hour")
                return self.snapshot(changedFiles: 0)
            }

        let deleted = await OldSessionSweep.run(
            days: 7, policy: .deleteSafe, store: store,
            runner: SessionRunner(paths: [:]),
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
