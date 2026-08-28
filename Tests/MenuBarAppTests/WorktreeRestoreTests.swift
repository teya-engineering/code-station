import Foundation
import Testing
@testable import MenuBarApp

// A session's checkout folder removed outside the app. The conversation is worth keeping and
// the folder is one the app made, so it offers to make it again - which is only worth
// offering if the work really comes back where the branch survived, and only honest if it
// says so plainly where the branch did not.
@MainActor
struct WorktreeRestoreTests {

    // The checkouts live in a folder of their own rather than inside the repository, so a
    // worktree can be parked out of git's sight.
    private let repo: GitRepo
    private let sandbox = ScratchDirectory(prefix: "restore")

    init() throws {
        repo = try GitRepo()
    }

    // MARK: - Rebuilding

    @Test func rebuildsTheFolderAndItsCommitsWhenTheBranchSurvived() async throws {
        let checkout = sandbox.path("checkout")

        try repo.git("worktree", "add", "-q", checkout.path, "-b", "code-station/abc")
        try "work".write(to: checkout.appendingPathComponent("note.txt"),
                         atomically: true, encoding: .utf8)
        try GitRepo.run(["add", "."], in: checkout)
        try GitRepo.run(["commit", "-qm", "the work"], in: checkout)

        // Removed the way a person removes it: the folder goes, git's registration and the
        // branch both stay behind.
        try FileManager.default.removeItem(at: checkout)

        let result = await GitWorktree.restore(worktreePath: checkout.path,
                                               branch: "code-station/abc",
                                               projectPath: repo.path, from: .localBranch)

        #expect(throwsNothing(result))
        // The point of keeping the branch: the commit is back, not just the folder.
        #expect(read("note.txt", in: checkout) == "work")
        #expect(try GitRepo.run(["log", "-1", "--pretty=%s"], in: checkout) == "the work")
        #expect(try GitRepo.run(["rev-parse", "--abbrev-ref", "HEAD"], in: checkout) == "code-station/abc")
    }

    // The regression `restore` exists for. Git keeps its registration when only the folder is
    // deleted and refuses to add a worktree onto a path it still knows about, so a rebuild
    // that does not clear it first fails on the most ordinary way of losing a folder.
    @Test func rebuildsOverTheRegistrationGitKeepsWhenOnlyTheFolderWasDeleted() async throws {
        let checkout = sandbox.path("checkout")

        try repo.git("worktree", "add", "-q", checkout.path, "-b", "code-station/ghi")
        try FileManager.default.removeItem(at: checkout)

        // What a plain `worktree add` would do here, and it does not work.
        #expect(throws: (any Error).self) {
            try repo.git("worktree", "add", checkout.path, "code-station/ghi")
        }

        let result = await GitWorktree.restore(worktreePath: checkout.path,
                                               branch: "code-station/ghi",
                                               projectPath: repo.path, from: .localBranch)

        #expect(throwsNothing(result))
        #expect(FileManager.default.fileExists(atPath: checkout.path))
    }

    // A rebuild has to stay on its own checkout. `git worktree prune` would clear the stale
    // registration this needs gone and every other one whose folder is missing with it, so
    // rebuilding one session would deregister a session whose disk is merely unplugged, and
    // that one is an orphan the moment it comes back. The parked worktree stands in for it.
    @Test func leavesAnotherSessionsMissingCheckoutRegistered() async throws {
        let mine = sandbox.path("mine")
        let other = sandbox.path("other")

        try repo.git("worktree", "add", "-q", mine.path, "-b", "code-station/mine")
        try repo.git("worktree", "add", "-q", other.path, "-b", "code-station/other")
        try FileManager.default.removeItem(at: mine)
        // Moved rather than deleted, the way an unmounted volume leaves it: gone as far as
        // git can tell, and coming back later.
        try FileManager.default.moveItem(at: other,
                                         to: sandbox.path("parked"))

        let result = await GitWorktree.restore(worktreePath: mine.path,
                                               branch: "code-station/mine",
                                               projectPath: repo.path, from: .localBranch)

        #expect(throwsNothing(result))
        #expect(try repo.git("worktree", "list").contains("other"))
    }

    // A branch pushed and then deleted locally still has its commits on the remote, and
    // checking that ref out brings them back. Forking from the project instead would lose
    // work that was never lost.
    @Test func rebuildsFromTheRemoteWhenTheLocalBranchIsGone() async throws {
        let origin = try GitRepo.bare()
        try repo.addRemote(origin)
        let checkout = sandbox.path("checkout")

        try repo.git("worktree", "add", "-q", checkout.path, "-b", "code-station/pushed")
        try "work".write(to: checkout.appendingPathComponent("note.txt"),
                         atomically: true, encoding: .utf8)
        try GitRepo.run(["add", "."], in: checkout)
        try GitRepo.run(["commit", "-qm", "precious work"], in: checkout)
        try GitRepo.run(["push", "-q", "origin", "code-station/pushed"], in: checkout)

        try FileManager.default.removeItem(at: checkout)
        try repo.git("worktree", "prune")
        try repo.git("branch", "-qD", "code-station/pushed")

        let source = await GitWorktree.restoreSource(of: "code-station/pushed",
                                                     projectPath: repo.path)
        #expect(source == .remoteBranch("refs/remotes/origin/code-station/pushed"))

        let result = await GitWorktree.restore(worktreePath: checkout.path,
                                               branch: "code-station/pushed",
                                               projectPath: repo.path,
                                               from: try #require(source))

        #expect(throwsNothing(result))
        #expect(try GitRepo.run(["log", "-1", "--pretty=%s"], in: checkout) == "precious work")
        // Tracking the remote it came from, so the next push is not a diverged branch.
        #expect(try GitRepo.run(["rev-parse", "--abbrev-ref", "@{upstream}"], in: checkout)
            == "origin/code-station/pushed")
    }

    // The case the confirmation has to be honest about: the folder comes back, the work does
    // not.
    @Test func rebuildsFromTheProjectWhenTheBranchIsGoneEverywhere() async throws {
        let checkout = sandbox.path("checkout")

        try repo.git("worktree", "add", "-q", checkout.path, "-b", "code-station/def")
        try FileManager.default.removeItem(at: checkout)
        try repo.git("worktree", "prune")
        try repo.git("branch", "-qD", "code-station/def")

        let result = await GitWorktree.restore(worktreePath: checkout.path,
                                               branch: "code-station/def",
                                               projectPath: repo.path, from: .projectHead)

        #expect(throwsNothing(result))
        // Forked from the project's own checkout, so it holds the first commit and nothing
        // that was only ever on the branch.
        #expect(try GitRepo.run(["log", "-1", "--pretty=%s"], in: checkout) == "first")
        #expect(try GitRepo.run(["rev-parse", "--abbrev-ref", "HEAD"], in: checkout) == "code-station/def")
    }

    // `--force` waives two of git's checks and only one of them is ours to waive. A branch
    // checked out in a folder that still exists must not be checked out again: commits in
    // either one make the other look out of date.
    @Test func refusesWhenTheBranchIsCheckedOutInAFolderThatStillExists() async throws {
        let mine = sandbox.path("mine")
        let elsewhere = sandbox.path("elsewhere")

        try repo.git("worktree", "add", "-q", elsewhere.path, "-b", "code-station/shared")

        let result = await GitWorktree.restore(worktreePath: mine.path,
                                               branch: "code-station/shared",
                                               projectPath: repo.path, from: .localBranch)

        #expect(message(of: result)?.contains("already checked out") == true)
        #expect(!FileManager.default.fileExists(atPath: mine.path))
    }

    // Nothing to build the checkout out of. Reported rather than attempted, so the banner can
    // say so instead of the reader meeting a raw git error.
    @Test func refusesWhenTheProjectFolderIsGoneToo() async throws {
        let root = sandbox.path("no-project")

        let result = await GitWorktree.restore(
            worktreePath: root.appendingPathComponent("checkout").path,
            branch: "code-station/jkl",
            projectPath: root.appendingPathComponent("project").path, from: .localBranch)

        #expect(message(of: result)?.contains("project folder") == true)
    }

    // MARK: - Where the commits are

    @Test func readsWhereTheCommitsWouldComeFromWithoutChangingAnything() async throws {
        try repo.git("branch", "code-station/mno")

        #expect(await GitWorktree.restoreSource(of: "code-station/mno",
                                                projectPath: repo.path) == .localBranch)
        #expect(await GitWorktree.restoreSource(of: "code-station/nope",
                                                projectPath: repo.path) == .projectHead)
        // Not the same answer as "the branch is gone": there is no way to tell from here, and
        // saying it is gone would promise a fresh checkout this cannot make.
        #expect(await GitWorktree.restoreSource(of: "code-station/mno", projectPath: "/nowhere") == nil)
    }

    // A tag of the same name must not stand in for the branch: checking one out leaves a
    // detached head on a checkout whose session records a branch.
    @Test func doesNotMistakeATagForTheBranch() async throws {
        try repo.git("tag", "code-station/tagged")

        #expect(await GitWorktree.restoreSource(of: "code-station/tagged",
                                                projectPath: repo.path) == .projectHead)
    }

    // Git's own guesswork gives up when two remotes carry the name, which is exactly when
    // forking from the project instead would lose the commits most quietly.
    @Test func prefersOriginWhenTwoRemotesCarryTheBranch() async throws {
        let origin = try GitRepo.bare()
        try repo.addRemote(origin)
        try repo.git("branch", "code-station/two")
        try repo.git("push", "-q", "origin", "code-station/two")
        // Named "backup" so it sorts before origin: git lists refs by name, and picking the
        // first would land on the wrong remote without anyone noticing.
        let backup = try GitRepo.bare()
        try repo.addRemote(backup, named: "backup")
        try repo.git("push", "-q", "backup", "code-station/two")
        try repo.git("branch", "-qD", "code-station/two")

        #expect(await GitWorktree.restoreSource(of: "code-station/two", projectPath: repo.path)
            == .remoteBranch("refs/remotes/origin/code-station/two"))
    }

    // MARK: - What the session offers

    @Test func listsOnlyTheFoldersThatAreGone() throws {
        let scene = try Scene()
        let present = try scene.folder("checkout")
        let session = scene.store.newSession(in: scene.project.id, worktreePath: present.path,
                                             worktreeBranch: "code-station/stu")

        #expect(SessionLifecycle.missingDirectories(of: session, in: scene.store).isEmpty)

        try FileManager.default.removeItem(at: present)

        #expect(SessionLifecycle.missingDirectories(of: session, in: scene.store) == [present.path])
    }

    @Test func offersARebuildOnlyForCheckoutsItCanPutBack() throws {
        let scene = try Scene()
        let lost = scene.root.appendingPathComponent("gone").path

        let rebuildable = scene.store.newSession(in: scene.project.id, worktreePath: lost,
                                                 worktreeBranch: "code-station/pqr")
        #expect(SessionLifecycle.rebuildableCheckouts(of: rebuildable, in: scene.store)
            == [LostCheckout(path: lost, branch: "code-station/pqr",
                             projectPath: scene.project.path)])

        // No branch recorded is nothing to rebuild from.
        let branchless = scene.store.newSession(in: scene.project.id, worktreePath: lost,
                                                worktreeBranch: nil)
        #expect(SessionLifecycle.rebuildableCheckouts(of: branchless, in: scene.store).isEmpty)

        // The project the checkout came from has to be there to build it out of.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: scene.project.path))
        #expect(SessionLifecycle.rebuildableCheckouts(of: rebuildable, in: scene.store).isEmpty)
    }

    // A workspace member checked out in the project folder itself has no worktree of its own,
    // so there is nothing here the app could put back. Counting it would offer a rebuild that
    // did nothing, and describe folders it was never going to touch.
    @Test func doesNotOfferToRebuildAMemberWithNoWorktreeOfItsOwn() throws {
        let scene = try Scene()
        let member = try scene.addProject(named: "member")
        let workspace = try #require(scene.store.addWorkspace(
            name: "pair", projectIDs: [scene.project.id, member.id],
            leadProjectID: scene.project.id))
        let session = try #require(scene.store.newSession(
            in: workspace.id,
            projects: [SessionProject(projectID: scene.project.id, worktreePath: nil,
                                      worktreeBranch: nil),
                       SessionProject(projectID: member.id, worktreePath: nil,
                                      worktreeBranch: nil)]))

        try FileManager.default.removeItem(at: URL(fileURLWithPath: member.path))

        // The banner still reports it, because the folder really is gone.
        #expect(SessionLifecycle.missingDirectories(of: session, in: scene.store) == [member.path])
        #expect(SessionLifecycle.rebuildableCheckouts(of: session, in: scene.store).isEmpty)
    }

    @Test func pairsEachCheckoutWithWhereItsCommitsAre() async throws {
        let checkouts = [
            LostCheckout(path: "/gone/one", branch: "code-station/one", projectPath: "/repo"),
            LostCheckout(path: "/gone/two", branch: "code-station/two", projectPath: "/repo")
        ]

        let plan = await SessionLifecycle.planRebuild(checkouts) { branch, _ in
            branch == "code-station/one" ? .localBranch : .projectHead
        }

        #expect(plan == [PlannedRebuild(checkout: checkouts[0], source: .localBranch),
                         PlannedRebuild(checkout: checkouts[1], source: .projectHead)])
    }

    // "Cannot ask" is not "the branch is gone". Told as the latter, the confirmation promises
    // a fresh checkout that the rebuild then refuses to make.
    @Test func dropsACheckoutGitCannotAnswerFor() async throws {
        let checkouts = [LostCheckout(path: "/gone", branch: "code-station/yza", projectPath: "/repo")]

        #expect(await SessionLifecycle.planRebuild(checkouts) { _, _ in nil }.isEmpty)
    }

    @Test func rebuildsEveryPlannedCheckoutAndLeavesTheSessionRecordAlone() async throws {
        let scene = try Scene()
        let lost = scene.root.appendingPathComponent("gone").path
        let session = scene.store.newSession(in: scene.project.id, worktreePath: lost,
                                             worktreeBranch: "code-station/pqr")
        let plan = await SessionLifecycle.planRebuild(
            SessionLifecycle.rebuildableCheckouts(of: session, in: scene.store)) { _, _ in .localBranch }

        let asked = Recorder()
        let result = await SessionLifecycle.rebuild(plan, worktrees: .recording(asked))

        #expect(throwsNothing(result))
        #expect(asked.steps == plan)
        // The record was right all along, so nothing about it should have moved.
        let after = try #require(scene.store.session(session.id))
        #expect(after.worktreePath == lost)
        #expect(after.worktreeBranch == "code-station/pqr")
    }

    @Test func reportsAFailingRebuildRatherThanReadingAsDone() async throws {
        let plan = [PlannedRebuild(checkout: LostCheckout(path: "/gone", branch: "code-station/vwx",
                                                          projectPath: "/repo"),
                                   source: .localBranch)]

        let result = await SessionLifecycle.rebuild(plan, worktrees: .refusing("git said no"))

        guard case .failure(let failure) = result else {
            Issue.record("a failing rebuild should not read as done")
            return
        }
        #expect(failure.message.contains("git said no"))
    }

    // MARK: - What the confirmation says

    @Test func namesWhereTheCommitsAreComingFrom() {
        let checkout = LostCheckout(path: "/gone", branch: "code-station/abc", projectPath: "/repo")

        let local = SessionLifecycle.rebuildMessage(
            for: [PlannedRebuild(checkout: checkout, source: .localBranch)])
        #expect(local.contains("code-station/abc is still on this machine"))

        let remote = SessionLifecycle.rebuildMessage(
            for: [PlannedRebuild(checkout: checkout,
                                 source: .remoteBranch("refs/remotes/origin/code-station/abc"))])
        // The name git shows everywhere else, not the full ref.
        #expect(remote.contains("origin/code-station/abc"))
        #expect(!remote.contains("refs/remotes"))

        // The one case where work is lost has to say so rather than lead with the folder.
        let gone = SessionLifecycle.rebuildMessage(
            for: [PlannedRebuild(checkout: checkout, source: .projectHead)])
        #expect(gone.contains("gone from this machine and from every remote"))
        #expect(gone.contains("cannot be recovered"))
    }

    @Test func separatesWhatComesBackFromWhatStartsOverWhenThereAreSeveral() {
        let plan = ["one", "two", "three"].enumerated().map { index, name in
            PlannedRebuild(checkout: LostCheckout(path: "/gone/\(name)",
                                                  branch: "code-station/\(name)",
                                                  projectPath: "/repo"),
                           source: index == 2 ? .projectHead : .localBranch)
        }

        let message = SessionLifecycle.rebuildMessage(for: plan)

        #expect(message.contains("2 still have their branch"))
        // A group of one inside a plural message still has to read as English.
        #expect(message.contains("One has lost its branch everywhere and starts from"))
    }

    // MARK: - Helpers

    private func throwsNothing<E: Error>(_ result: Result<Void, E>) -> Bool {
        if case .failure(let failure) = result {
            Issue.record("expected success, got: \(failure)")
            return false
        }
        return true
    }

    private func message(of result: Result<Void, GitWorktree.Failure>) -> String? {
        guard case .failure(let failure) = result else {
            Issue.record("expected a refusal")
            return nil
        }
        return failure.message
    }

    private func read(_ name: String, in folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    // A store with one project, and a folder of its own for everything the test creates.
    @MainActor
    private struct Scene {
        let scratch: ScratchDirectory
        let store: ProjectStore
        let project: Project
        var root: URL { scratch.url }

        init() throws {
            let made = TestStore.make()
            store = made.store
            scratch = made.scratch
            project = try TestStore.project(in: store, named: "repo")
        }

        func folder(_ name: String) throws -> URL {
            let url = scratch.path(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func addProject(named name: String) throws -> Project {
            try TestStore.project(in: store, named: name)
        }
    }
}

// What the rebuild handed to git, so a test can check the steps without running one.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PlannedRebuild] = []

    var steps: [PlannedRebuild] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ step: PlannedRebuild) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(step)
    }
}

private extension WorktreeOperations {
    // Only `restore` is ever reached by a rebuild; the others answer so that a test asking
    // for one says so rather than quietly passing.
    static func recording(_ recorder: Recorder) -> WorktreeOperations {
        rebuildOnly { step in
            recorder.record(step)
            return .success(())
        }
    }

    static func refusing(_ message: String) -> WorktreeOperations {
        rebuildOnly { _ in .failure(GitWorktree.Failure(message: message)) }
    }

    private static func rebuildOnly(
        _ restore: @escaping @Sendable (PlannedRebuild) async -> Result<Void, GitWorktree.Failure>
    ) -> WorktreeOperations {
        WorktreeOperations(
            addProject: { _, _, _, _ in .failure(GitWorktree.Failure(message: "Unexpected add")) },
            addWorkspaceProject: { _, _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected add"))
            },
            remove: { _, _, _ in .failure(GitWorktree.Failure(message: "Unexpected removal")) },
            restore: restore)
    }
}
