import Foundation
import Testing
@testable import MenuBarApp

// A session's checkout folder removed outside the app. The conversation is worth keeping and
// the folder is one the app made, so it offers to make it again - which is only worth
// offering if the work really comes back where the branch survived, and only honest if it
// says so plainly where the branch did not.
@MainActor
struct WorktreeRestoreTests {

    // MARK: - Rebuilding

    @Test func rebuildsTheFolderAndItsCommitsWhenTheBranchSurvived() async throws {
        let repo = try Repo()
        let checkout = repo.sandbox.appendingPathComponent("checkout")

        repo.git("worktree", "add", "-q", checkout.path, "-b", "conductor/abc")
        try "work".write(to: checkout.appendingPathComponent("note.txt"),
                         atomically: true, encoding: .utf8)
        Repo.run(in: checkout, ["add", "."])
        Repo.run(in: checkout, ["commit", "-qm", "the work"])

        // Removed the way a person removes it: the folder goes, git's registration and the
        // branch both stay behind.
        try FileManager.default.removeItem(at: checkout)

        let result = await GitWorktree.restore(worktreePath: checkout.path,
                                               branch: "conductor/abc",
                                               projectPath: repo.path, from: .localBranch)

        #expect(throwsNothing(result))
        // The point of keeping the branch: the commit is back, not just the folder.
        #expect(repo.read("note.txt", in: checkout) == "work")
        #expect(Repo.output(in: checkout, ["log", "-1", "--pretty=%s"]) == "the work")
        #expect(Repo.output(in: checkout, ["rev-parse", "--abbrev-ref", "HEAD"]) == "conductor/abc")
    }

    // The regression `restore` exists for. Git keeps its registration when only the folder is
    // deleted and refuses to add a worktree onto a path it still knows about, so a rebuild
    // that does not clear it first fails on the most ordinary way of losing a folder.
    @Test func rebuildsOverTheRegistrationGitKeepsWhenOnlyTheFolderWasDeleted() async throws {
        let repo = try Repo()
        let checkout = repo.sandbox.appendingPathComponent("checkout")

        repo.git("worktree", "add", "-q", checkout.path, "-b", "conductor/ghi")
        try FileManager.default.removeItem(at: checkout)

        // What a plain `worktree add` would do here, and it does not work.
        #expect(Repo.status(in: repo.url, ["worktree", "add", checkout.path, "conductor/ghi"]) != 0)

        let result = await GitWorktree.restore(worktreePath: checkout.path,
                                               branch: "conductor/ghi",
                                               projectPath: repo.path, from: .localBranch)

        #expect(throwsNothing(result))
        #expect(FileManager.default.fileExists(atPath: checkout.path))
    }

    // A rebuild has to stay on its own checkout. `git worktree prune` would clear the stale
    // registration this needs gone and every other one whose folder is missing with it, so
    // rebuilding one session would deregister a session whose disk is merely unplugged, and
    // that one is an orphan the moment it comes back. The parked worktree stands in for it.
    @Test func leavesAnotherSessionsMissingCheckoutRegistered() async throws {
        let repo = try Repo()
        let mine = repo.sandbox.appendingPathComponent("mine")
        let other = repo.sandbox.appendingPathComponent("other")

        repo.git("worktree", "add", "-q", mine.path, "-b", "conductor/mine")
        repo.git("worktree", "add", "-q", other.path, "-b", "conductor/other")
        try FileManager.default.removeItem(at: mine)
        // Moved rather than deleted, the way an unmounted volume leaves it: gone as far as
        // git can tell, and coming back later.
        try FileManager.default.moveItem(at: other,
                                         to: repo.sandbox.appendingPathComponent("parked"))

        let result = await GitWorktree.restore(worktreePath: mine.path,
                                               branch: "conductor/mine",
                                               projectPath: repo.path, from: .localBranch)

        #expect(throwsNothing(result))
        #expect(Repo.output(in: repo.url, ["worktree", "list"]).contains("other"))
    }

    // A branch pushed and then deleted locally still has its commits on the remote, and
    // checking that ref out brings them back. Forking from the project instead would lose
    // work that was never lost.
    @Test func rebuildsFromTheRemoteWhenTheLocalBranchIsGone() async throws {
        let repo = try Repo(withRemote: true)
        let checkout = repo.sandbox.appendingPathComponent("checkout")

        repo.git("worktree", "add", "-q", checkout.path, "-b", "conductor/pushed")
        try "work".write(to: checkout.appendingPathComponent("note.txt"),
                         atomically: true, encoding: .utf8)
        Repo.run(in: checkout, ["add", "."])
        Repo.run(in: checkout, ["commit", "-qm", "precious work"])
        Repo.run(in: checkout, ["push", "-q", "origin", "conductor/pushed"])

        try FileManager.default.removeItem(at: checkout)
        repo.git("worktree", "prune")
        repo.git("branch", "-qD", "conductor/pushed")

        let source = await GitWorktree.restoreSource(of: "conductor/pushed",
                                                     projectPath: repo.path)
        #expect(source == .remoteBranch("refs/remotes/origin/conductor/pushed"))

        let result = await GitWorktree.restore(worktreePath: checkout.path,
                                               branch: "conductor/pushed",
                                               projectPath: repo.path,
                                               from: try #require(source))

        #expect(throwsNothing(result))
        #expect(Repo.output(in: checkout, ["log", "-1", "--pretty=%s"]) == "precious work")
        // Tracking the remote it came from, so the next push is not a diverged branch.
        #expect(Repo.output(in: checkout, ["rev-parse", "--abbrev-ref", "@{upstream}"])
            == "origin/conductor/pushed")
    }

    // The case the confirmation has to be honest about: the folder comes back, the work does
    // not.
    @Test func rebuildsFromTheProjectWhenTheBranchIsGoneEverywhere() async throws {
        let repo = try Repo()
        let checkout = repo.sandbox.appendingPathComponent("checkout")

        repo.git("worktree", "add", "-q", checkout.path, "-b", "conductor/def")
        try FileManager.default.removeItem(at: checkout)
        repo.git("worktree", "prune")
        repo.git("branch", "-qD", "conductor/def")

        let result = await GitWorktree.restore(worktreePath: checkout.path,
                                               branch: "conductor/def",
                                               projectPath: repo.path, from: .projectHead)

        #expect(throwsNothing(result))
        // Forked from the project's own checkout, so it holds the first commit and nothing
        // that was only ever on the branch.
        #expect(Repo.output(in: checkout, ["log", "-1", "--pretty=%s"]) == "first")
        #expect(Repo.output(in: checkout, ["rev-parse", "--abbrev-ref", "HEAD"]) == "conductor/def")
    }

    // `--force` waives two of git's checks and only one of them is ours to waive. A branch
    // checked out in a folder that still exists must not be checked out again: commits in
    // either one make the other look out of date.
    @Test func refusesWhenTheBranchIsCheckedOutInAFolderThatStillExists() async throws {
        let repo = try Repo()
        let mine = repo.sandbox.appendingPathComponent("mine")
        let elsewhere = repo.sandbox.appendingPathComponent("elsewhere")

        repo.git("worktree", "add", "-q", elsewhere.path, "-b", "conductor/shared")

        let result = await GitWorktree.restore(worktreePath: mine.path,
                                               branch: "conductor/shared",
                                               projectPath: repo.path, from: .localBranch)

        #expect(message(of: result)?.contains("already checked out") == true)
        #expect(!FileManager.default.fileExists(atPath: mine.path))
    }

    // Nothing to build the checkout out of. Reported rather than attempted, so the banner can
    // say so instead of the reader meeting a raw git error.
    @Test func refusesWhenTheProjectFolderIsGoneToo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-no-project-\(UUID().uuidString)")

        let result = await GitWorktree.restore(
            worktreePath: root.appendingPathComponent("checkout").path,
            branch: "conductor/jkl",
            projectPath: root.appendingPathComponent("project").path, from: .localBranch)

        #expect(message(of: result)?.contains("project folder") == true)
    }

    // MARK: - Where the commits are

    @Test func readsWhereTheCommitsWouldComeFromWithoutChangingAnything() async throws {
        let repo = try Repo()
        repo.git("branch", "conductor/mno")

        #expect(await GitWorktree.restoreSource(of: "conductor/mno",
                                                projectPath: repo.path) == .localBranch)
        #expect(await GitWorktree.restoreSource(of: "conductor/nope",
                                                projectPath: repo.path) == .projectHead)
        // Not the same answer as "the branch is gone": there is no way to tell from here, and
        // saying it is gone would promise a fresh checkout this cannot make.
        #expect(await GitWorktree.restoreSource(of: "conductor/mno", projectPath: "/nowhere") == nil)
    }

    // A tag of the same name must not stand in for the branch: checking one out leaves a
    // detached head on a checkout whose session records a branch.
    @Test func doesNotMistakeATagForTheBranch() async throws {
        let repo = try Repo()
        repo.git("tag", "conductor/tagged")

        #expect(await GitWorktree.restoreSource(of: "conductor/tagged",
                                                projectPath: repo.path) == .projectHead)
    }

    // Git's own guesswork gives up when two remotes carry the name, which is exactly when
    // forking from the project instead would lose the commits most quietly.
    @Test func prefersOriginWhenTwoRemotesCarryTheBranch() async throws {
        let repo = try Repo(withRemote: true)
        repo.git("branch", "conductor/two")
        repo.git("push", "-q", "origin", "conductor/two")
        // Named "backup" so it sorts before origin: git lists refs by name, and picking the
        // first would land on the wrong remote without anyone noticing.
        repo.git("remote", "add", "backup", try repo.addBare(named: "backup"))
        repo.git("push", "-q", "backup", "conductor/two")
        repo.git("branch", "-qD", "conductor/two")

        #expect(await GitWorktree.restoreSource(of: "conductor/two", projectPath: repo.path)
            == .remoteBranch("refs/remotes/origin/conductor/two"))
    }

    // MARK: - What the session offers

    @Test func listsOnlyTheFoldersThatAreGone() throws {
        let scene = try Scene()
        let present = try scene.folder("checkout")
        let session = scene.store.newSession(in: scene.project.id, worktreePath: present.path,
                                             worktreeBranch: "conductor/stu")

        #expect(SessionLifecycle.missingDirectories(of: session, in: scene.store).isEmpty)

        try FileManager.default.removeItem(at: present)

        #expect(SessionLifecycle.missingDirectories(of: session, in: scene.store) == [present.path])
    }

    @Test func offersARebuildOnlyForCheckoutsItCanPutBack() throws {
        let scene = try Scene()
        let lost = scene.root.appendingPathComponent("gone").path

        let rebuildable = scene.store.newSession(in: scene.project.id, worktreePath: lost,
                                                 worktreeBranch: "conductor/pqr")
        #expect(SessionLifecycle.rebuildableCheckouts(of: rebuildable, in: scene.store)
            == [LostCheckout(path: lost, branch: "conductor/pqr",
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
            LostCheckout(path: "/gone/one", branch: "conductor/one", projectPath: "/repo"),
            LostCheckout(path: "/gone/two", branch: "conductor/two", projectPath: "/repo")
        ]

        let plan = await SessionLifecycle.planRebuild(checkouts) { branch, _ in
            branch == "conductor/one" ? .localBranch : .projectHead
        }

        #expect(plan == [PlannedRebuild(checkout: checkouts[0], source: .localBranch),
                         PlannedRebuild(checkout: checkouts[1], source: .projectHead)])
    }

    // "Cannot ask" is not "the branch is gone". Told as the latter, the confirmation promises
    // a fresh checkout that the rebuild then refuses to make.
    @Test func dropsACheckoutGitCannotAnswerFor() async throws {
        let checkouts = [LostCheckout(path: "/gone", branch: "conductor/yza", projectPath: "/repo")]

        #expect(await SessionLifecycle.planRebuild(checkouts) { _, _ in nil }.isEmpty)
    }

    @Test func rebuildsEveryPlannedCheckoutAndLeavesTheSessionRecordAlone() async throws {
        let scene = try Scene()
        let lost = scene.root.appendingPathComponent("gone").path
        let session = scene.store.newSession(in: scene.project.id, worktreePath: lost,
                                             worktreeBranch: "conductor/pqr")
        let plan = await SessionLifecycle.planRebuild(
            SessionLifecycle.rebuildableCheckouts(of: session, in: scene.store)) { _, _ in .localBranch }

        let asked = Recorder()
        let result = await SessionLifecycle.rebuild(plan, worktrees: .recording(asked))

        #expect(throwsNothing(result))
        #expect(asked.steps == plan)
        // The record was right all along, so nothing about it should have moved.
        let after = try #require(scene.store.session(session.id))
        #expect(after.worktreePath == lost)
        #expect(after.worktreeBranch == "conductor/pqr")
    }

    @Test func reportsAFailingRebuildRatherThanReadingAsDone() async throws {
        let plan = [PlannedRebuild(checkout: LostCheckout(path: "/gone", branch: "conductor/vwx",
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
        let checkout = LostCheckout(path: "/gone", branch: "conductor/abc", projectPath: "/repo")

        let local = SessionLifecycle.rebuildMessage(
            for: [PlannedRebuild(checkout: checkout, source: .localBranch)])
        #expect(local.contains("conductor/abc is still on this machine"))

        let remote = SessionLifecycle.rebuildMessage(
            for: [PlannedRebuild(checkout: checkout,
                                 source: .remoteBranch("refs/remotes/origin/conductor/abc"))])
        // The name git shows everywhere else, not the full ref.
        #expect(remote.contains("origin/conductor/abc"))
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
                                                  branch: "conductor/\(name)",
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

    // A store with one project, and a folder of its own for everything the test creates.
    @MainActor
    private struct Scene {
        let root: URL
        let store: ProjectStore
        let project: Project

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("restore-scene-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            setenv("CONDUCTOR_STORE", root.appendingPathComponent("projects.json").path, 1)
            store = ProjectStore()
            project = try Scene.add(named: "repo", root: root, store: store)
        }

        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func addProject(named name: String) throws -> Project {
            try Scene.add(named: name, root: root, store: store)
        }

        private static func add(named name: String, root: URL,
                                store: ProjectStore) throws -> Project {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            guard let project = store.addProject(at: url) else {
                throw GitWorktree.Failure(message: "could not add \(name)")
            }
            return project
        }
    }

    // A repository with one commit and an identity of its own, inside a folder that holds
    // everything the test makes so worktrees can be parked out of git's sight.
    private final class Repo {
        let sandbox: URL
        let url: URL
        var path: String { url.path }

        init(withRemote: Bool = false) throws {
            sandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("restore-repo-\(UUID().uuidString)", isDirectory: true)
            url = sandbox.appendingPathComponent("repo", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            git("init", "-q", "-b", "main")
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "Test")
            git("config", "commit.gpgsign", "false")
            try "hello".write(to: url.appendingPathComponent("README.md"),
                              atomically: true, encoding: .utf8)
            git("add", ".")
            git("commit", "-qm", "first")
            if withRemote {
                let origin = try addBare(named: "origin")
                git("remote", "add", "origin", origin)
            }
        }

        deinit { try? FileManager.default.removeItem(at: sandbox) }

        // Added by path rather than by name, so a second one can be pushed to without being
        // a remote this repository tracks.
        @discardableResult
        func addBare(named name: String) throws -> String {
            let bare = sandbox.appendingPathComponent("\(name).git", isDirectory: true)
            try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
            Self.run(in: bare, ["init", "-q", "--bare", "-b", "main"])
            return bare.path
        }

        func read(_ name: String, in folder: URL) -> String? {
            try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }

        func git(_ arguments: String...) { Self.run(in: url, arguments) }

        static func run(in directory: URL, _ arguments: [String]) {
            _ = status(in: directory, arguments)
        }

        static func status(in directory: URL, _ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        static func output(in directory: URL, _ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
