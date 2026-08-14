import Foundation
import Testing
@testable import MenuBarApp

// The git commands behind the changes screen's header: commit, switch, push and pull.
// They act on the user's real repository, so each one is checked against a throwaway
// repo rather than trusted to pass its arguments through correctly.
struct GitActionsTests {

    @Test func commitsEverythingInOneGo() async throws {
        let repo = try Repo()
        try repo.write("README.md", "changed")
        try repo.write("notes.txt", "untracked too")

        let error = await GitActions.commitAll(message: "Keep the lot", at: repo.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.files.isEmpty)
    }

    @Test func discardPutsAModifiedFileBack() async throws {
        let repo = try Repo()
        try repo.write("README.md", "changed")

        let file = try #require(await GitInspector.snapshot(at: repo.path).files.first)
        #expect(await GitActions.discard(file, at: repo.path) == nil)

        #expect(repo.read("README.md") == "hello")
        #expect(await GitInspector.snapshot(at: repo.path).files.isEmpty)
    }

    // Staging half a file and leaving the rest is normal while a session works, and a
    // discard that only cleared the working tree would leave the staged half behind.
    @Test func discardClearsBothTheIndexAndTheWorkingTree() async throws {
        let repo = try Repo()
        try repo.write("README.md", "staged")
        repo.git("add", "README.md")
        try repo.write("README.md", "and then some more")

        let file = try #require(await GitInspector.snapshot(at: repo.path).files.first)
        #expect(file.isStaged && file.isUnstaged)
        #expect(await GitActions.discard(file, at: repo.path) == nil)

        #expect(repo.read("README.md") == "hello")
        #expect(await GitInspector.snapshot(at: repo.path).files.isEmpty)
    }

    // A rename is one row on the screen and two paths in git, so undoing it has to bring
    // the old name back as well as take the new one away.
    @Test func discardUndoesARename() async throws {
        let repo = try Repo()
        repo.git("mv", "README.md", "NOTES.md")

        let file = try #require(await GitInspector.snapshot(at: repo.path).files.first)
        #expect(file.originalPath == "README.md")
        #expect(await GitActions.discard(file, at: repo.path) == nil)

        #expect(repo.read("README.md") == "hello")
        #expect(await GitInspector.snapshot(at: repo.path).files.isEmpty)
    }

    @Test func discardBringsBackADeletedFile() async throws {
        let repo = try Repo()
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("README.md"))

        let file = try #require(await GitInspector.snapshot(at: repo.path).files.first)
        #expect(await GitActions.discard(file, at: repo.path) == nil)

        #expect(repo.read("README.md") == "hello")
    }

    // Git has no copy of an untracked file, so the trash is the only version left of it.
    @Test func discardTrashesAnUntrackedFile() async throws {
        let repo = try Repo()
        try repo.write("scratch.txt", "never committed")

        let file = try #require(await GitInspector.snapshot(at: repo.path).files.first)
        #expect(file.isUntracked)
        #expect(await GitActions.discard(file, at: repo.path) == nil)

        #expect(repo.read("scratch.txt") == nil)
        #expect(await GitInspector.snapshot(at: repo.path).files.isEmpty)
    }

    @Test func switchesBetweenBranches() async throws {
        let repo = try Repo()
        repo.git("branch", "feature")

        let error = await GitActions.switchBranch("feature", at: repo.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.branch == "feature")
        #expect(after.onBranch)
    }

    @Test func reportsWhyASwitchFailed() async throws {
        let repo = try Repo()
        let error = await GitActions.switchBranch("no-such-branch", at: repo.path)
        #expect(error?.isEmpty == false)
    }

    @Test func pushPublishesABranchWithNoUpstream() async throws {
        let repo = try Repo()
        let remote = try Bare()
        repo.git("remote", "add", "origin", remote.path)

        let before = await GitInspector.snapshot(at: repo.path)
        #expect(before.upstream == nil)

        let error = await GitActions.push(hasUpstream: false, at: repo.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.upstream == "origin/main")
        #expect(after.ahead == 0)
    }

    @Test func listsCommitsAheadOfTheUpstreamBeforePushing() async throws {
        let repo = try Repo()
        let remote = try Bare()
        repo.git("remote", "add", "origin", remote.path)
        repo.git("push", "-q", "-u", "origin", "HEAD")
        try repo.write("README.md", "ahead now")
        repo.git("commit", "-qam", "second")

        let preview = await GitActions.commitsToPush(hasUpstream: true, at: repo.path)
        guard case .commits(let commits) = preview else {
            #expect(Bool(false))
            return
        }

        #expect(commits.map(\.subject) == ["second"])
        #expect(commits[0].shortID.count == 8)
    }

    @Test func listsUnpublishedCommitsBeforeTheFirstPush() async throws {
        let repo = try Repo()
        let remote = try Bare()
        repo.git("remote", "add", "origin", remote.path)

        let preview = await GitActions.commitsToPush(hasUpstream: false, at: repo.path)
        guard case .commits(let commits) = preview else {
            #expect(Bool(false))
            return
        }

        #expect(commits.map(\.subject) == ["first"])
    }

    @Test func listsOnlyTheNewCommitsForAnUnpublishedBranch() async throws {
        let repo = try Repo()
        let remote = try Bare()
        repo.git("remote", "add", "origin", remote.path)
        repo.git("push", "-q", "-u", "origin", "HEAD")
        repo.git("switch", "-qc", "session-branch")
        try repo.write("session.txt", "new work")
        repo.git("add", "session.txt")
        repo.git("commit", "-qm", "session work")

        let preview = await GitActions.commitsToPush(hasUpstream: false, at: repo.path)
        guard case .commits(let commits) = preview else {
            #expect(Bool(false))
            return
        }

        #expect(commits.map(\.subject) == ["session work"])
    }

    @Test func pullBringsInTheRemoteCommits() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        // The behind count reads the tracking ref, so it only moves once a fetch has
        // seen what the remote gained.
        second.git("fetch", "-q")
        let behind = await GitInspector.snapshot(at: second.path)
        #expect(behind.behind == 1)

        #expect(await GitActions.pull(at: second.path) == .updated)

        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.behind == 0)
    }

    // Nothing fetches before the button is pressed, so a pull that trusted the tracking
    // ref would decide there was nothing to do and quietly do nothing.
    @Test func pullReadsOriginBeforeDecidingThereIsNothingToDo() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        // As far as this clone knows, it is level with origin.
        #expect(await GitInspector.snapshot(at: second.path).behind == 0)

        #expect(await GitActions.pull(at: second.path) == .updated)
        #expect(second.read("README.md") == "moved on")
    }

    @Test func pullSaysSoWhenThereIsNothingToBringIn() async throws {
        let remote = try Bare()
        let repo = try Repo()
        repo.git("remote", "add", "origin", remote.path)
        repo.git("push", "-q", "-u", "origin", "HEAD")

        #expect(await GitActions.pull(at: repo.path) == .upToDate)
    }

    // The failure this whole path exists for: git will not guess between a merge and a
    // rebase, so a diverged branch used to stop at a hint about pull.rebase. Nothing here
    // sets that config, which is the point.
    @Test func pullRebasesLocalCommitsOntoADivergedUpstream() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try second.write("mine.txt", "local work")
        second.git("add", ".")
        second.git("commit", "-qm", "local work")
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        #expect(await GitActions.pull(at: second.path) == .updated)

        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.behind == 0)
        // The local commit is kept, replayed on top of what origin gained.
        #expect(after.ahead == 1)
        #expect(second.read("README.md") == "moved on")
        #expect(second.read("mine.txt") == "local work")
    }

    // Sessions leave trees dirty, and a pull that refused to run until the folder was
    // clean would be turned away most of the time it is pressed.
    @Test func pullKeepsUncommittedWorkThroughTheUpdate() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try second.write("scratch.txt", "half finished")
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        #expect(await GitActions.pull(at: second.path) == .updated)
        #expect(second.read("scratch.txt") == "half finished")
        #expect(second.read("README.md") == "moved on")
    }

    // A rebase that cannot finish leaves the branch parked halfway onto origin, which no
    // part of this screen can carry on from, so the press has to undo itself.
    @Test func pullPutsTheBranchBackWhenTheRebaseCannotFinish() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try second.write("README.md", "my version")
        second.git("commit", "-qam", "local edit")
        let before = second.head
        try first.write("README.md", "their version")
        first.git("commit", "-qam", "their edit")
        first.git("push", "-q")

        guard case .failed(let message) = await GitActions.pull(at: second.path) else {
            #expect(Bool(false), "a conflicting rebase has to report a failure")
            return
        }
        #expect(message.contains("README.md"))

        #expect(second.head == before)
        #expect(second.read("README.md") == "my version")
        // No half-finished rebase and no stash left behind to find later.
        #expect(!FileManager.default.fileExists(
            atPath: second.url.appendingPathComponent(".git/rebase-merge").path))
        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.files.isEmpty)
    }

    // Pushing from behind the upstream is refused by origin every time, so the screen is
    // told before it sends one.
    @Test func pushPreviewReportsABranchThatTrailsOrigin() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try second.write("mine.txt", "local work")
        second.git("add", ".")
        second.git("commit", "-qm", "local work")
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        let preview = await GitActions.commitsToPush(hasUpstream: true, at: second.path)
        guard case .behindUpstream(let behind, let commits) = preview else {
            #expect(Bool(false), "a trailing branch has to be reported as behind")
            return
        }
        #expect(behind == 1)
        #expect(commits.map(\.subject) == ["local work"])
    }

    @Test func updateCheckoutMovesUpToTheRemoteTip() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        let error = await GitActions.updateCheckout(to: "main", at: second.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.behind == 0)
    }

    // A checkout parked on a feature branch has to land on the default branch and on its
    // latest revision; either half on its own leaves a session forking from stale code.
    @Test func updateCheckoutSwitchesBranchesAndCatchesUp() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        second.git("switch", "-qc", "feature")
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        let error = await GitActions.updateCheckout(to: "main", at: second.path)
        #expect(error == nil)

        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.branch == "main")
        #expect(after.behind == 0)
        #expect(after.ahead == 0)
    }

    @Test func updateCheckoutRefusesToMerge() async throws {
        let remote = try Bare()
        let first = try Repo()
        first.git("remote", "add", "origin", remote.path)
        first.git("push", "-q", "-u", "origin", "HEAD")

        let second = try Repo(cloneOf: remote)
        try second.write("local.txt", "diverged")
        second.git("add", ".")
        second.git("commit", "-qm", "local work")
        try first.write("README.md", "moved on")
        first.git("commit", "-qam", "second")
        first.git("push", "-q")

        let error = await GitActions.updateCheckout(to: "main", at: second.path)
        #expect(error?.isEmpty == false)

        // The diverged branch is left exactly as it was.
        let after = await GitInspector.snapshot(at: second.path)
        #expect(after.ahead == 1)
    }

    @Test func snapshotListsBranchesAndCountsDrift() async throws {
        let repo = try Repo()
        let remote = try Bare()
        repo.git("remote", "add", "origin", remote.path)
        repo.git("push", "-q", "-u", "origin", "HEAD")
        repo.git("branch", "feature")
        try repo.write("README.md", "ahead now")
        repo.git("commit", "-qam", "second")

        let snapshot = await GitInspector.snapshot(at: repo.path)
        #expect(Set(snapshot.branches) == ["main", "feature"])
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.ahead == 1)
        #expect(snapshot.behind == 0)
    }

    // MARK: - Selective commits

    @Test func commitsOnlyTheSelectedFiles() async throws {
        let repo = try Repo()
        try repo.write("README.md", "chosen")
        try repo.write("later.txt", "not yet")

        let snapshot = await GitInspector.snapshot(at: repo.path)
        let chosen = snapshot.files.filter { $0.path == "README.md" }
        let error = await GitActions.commitSelected(message: "Just the pick", files: chosen,
                                                    at: repo.path)
        #expect(error == nil)

        #expect(repo.committedFiles == ["README.md"])
        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.files.map(\.path) == ["later.txt"])
        #expect(repo.read("later.txt") == "not yet")
    }

    @Test func selectedUntrackedFilesMakeItIntoTheCommit() async throws {
        let repo = try Repo()
        try repo.write("fresh.txt", "brand new")

        let snapshot = await GitInspector.snapshot(at: repo.path)
        let chosen = snapshot.files.filter { $0.path == "fresh.txt" }
        #expect(chosen.first?.kind == .untracked)

        let error = await GitActions.commitSelected(message: "Add fresh", files: chosen,
                                                    at: repo.path)
        #expect(error == nil)
        #expect(repo.committedFiles == ["fresh.txt"])
    }

    // The trap in a partial commit: git add stages the picked paths next to whatever was
    // staged before, and a plain git commit would then sweep the lot in.
    @Test func stagedButUnselectedFilesStayOutOfTheCommitAndStayStaged() async throws {
        let repo = try Repo()
        try repo.write("staged.txt", "staged earlier")
        repo.git("add", "staged.txt")
        try repo.write("chosen.txt", "picked")

        let snapshot = await GitInspector.snapshot(at: repo.path)
        let chosen = snapshot.files.filter { $0.path == "chosen.txt" }
        let error = await GitActions.commitSelected(message: "Only the pick", files: chosen,
                                                    at: repo.path)
        #expect(error == nil)

        #expect(repo.committedFiles == ["chosen.txt"])
        // The unselected file is exactly where it was: staged, uncommitted, unchanged.
        #expect(repo.stagedFiles == ["staged.txt"])
        #expect(repo.read("staged.txt") == "staged earlier")
    }

    @Test func renameTravelsAsOnePairThroughASelectiveCommit() async throws {
        let repo = try Repo()
        repo.git("mv", "README.md", "MANUAL.md")
        try repo.write("other.txt", "left behind")

        let snapshot = await GitInspector.snapshot(at: repo.path)
        let renamed = snapshot.files.filter { $0.kind == .renamed }
        #expect(renamed.first?.originalPath == "README.md")

        let error = await GitActions.commitSelected(message: "Rename the readme",
                                                    files: renamed, at: repo.path)
        #expect(error == nil)

        let record = Repo.output(in: repo.url,
                                 ["show", "--name-status", "--format=", "-M", "HEAD"])
        #expect(record.contains("R"))
        #expect(record.contains("README.md"))
        #expect(record.contains("MANUAL.md"))
        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.files.map(\.path) == ["other.txt"])
    }

    // MARK: - Amend

    @Test func amendFoldsTheChangesIntoTheLastCommit() async throws {
        let repo = try Repo()
        try repo.write("work.txt", "first pass")
        #expect(await GitActions.commitAll(message: "Add work", at: repo.path) == nil)
        try repo.write("work.txt", "second pass")

        let error = await GitActions.commitAll(message: "Add finished work", amend: true,
                                               at: repo.path)
        #expect(error == nil)

        #expect(repo.commitCount == 2)
        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.lastCommitSubject == "Add finished work")
        #expect(after.files.isEmpty)
    }

    @Test func selectiveAmendKeepsUnselectedWorkOutOfTheFoldedCommit() async throws {
        let repo = try Repo()
        try repo.write("done.txt", "done")
        #expect(await GitActions.commitAll(message: "Add done", at: repo.path) == nil)
        try repo.write("extra.txt", "fold me in")
        try repo.write("pending.txt", "still cooking")

        let snapshot = await GitInspector.snapshot(at: repo.path)
        let chosen = snapshot.files.filter { $0.path == "extra.txt" }
        let error = await GitActions.commitSelected(message: "Add done and extra",
                                                    files: chosen, amend: true, at: repo.path)
        #expect(error == nil)

        #expect(repo.commitCount == 2)
        // The amended commit holds its original file and the folded one, nothing else.
        #expect(Set(repo.committedFiles) == ["done.txt", "extra.txt"])
        let after = await GitInspector.snapshot(at: repo.path)
        #expect(after.lastCommitSubject == "Add done and extra")
        #expect(after.files.map(\.path) == ["pending.txt"])
    }

    // MARK: - History

    @Test func historyListsRecentCommitsNewestFirst() async throws {
        let repo = try Repo()
        try repo.write("README.md", "two")
        repo.git("commit", "-qam", "second")
        try repo.write("README.md", "three")
        repo.git("commit", "-qam", "third")

        let history = await GitInspector.recentCommits(at: repo.path)
        #expect(history.note == nil)
        #expect(history.commits.map(\.subject) == ["third", "second", "first"])

        let newest = history.commits[0]
        #expect(newest.hash.count == 40)
        #expect(newest.hash.hasPrefix(newest.shortHash))
        #expect(newest.author == "Test")
        #expect(!newest.relativeDate.isEmpty)
    }

    @Test func historyHonoursItsLimit() async throws {
        let repo = try Repo()
        try repo.write("README.md", "two")
        repo.git("commit", "-qam", "second")
        try repo.write("README.md", "three")
        repo.git("commit", "-qam", "third")

        let history = await GitInspector.recentCommits(at: repo.path, limit: 2)
        #expect(history.commits.map(\.subject) == ["third", "second"])
    }

    @Test func historyIsEmptyBeforeTheFirstCommit() async throws {
        let repo = try Repo(empty: true)
        let history = await GitInspector.recentCommits(at: repo.path)
        #expect(history.commits.isEmpty)
        #expect(history.note == nil)
    }

    @Test func commitDiffShowsEachFileUnderItsOwnHeading() async throws {
        let repo = try Repo()
        try repo.write("README.md", "hello\nagain")
        try repo.write("notes.txt", "fresh")
        #expect(await GitActions.commitAll(message: "second", at: repo.path) == nil)

        let history = await GitInspector.recentCommits(at: repo.path)
        let diff = await GitInspector.commitDiff(history.commits[0].hash, root: repo.path)
        #expect(diff.note == nil)

        let sections = diff.lines.filter { $0.kind == .section }.map(\.text)
        #expect(sections == ["README.md", "notes.txt"])
        #expect(diff.lines.contains { $0.kind == .addition && $0.text == "+again" })
        #expect(diff.lines.contains { $0.kind == .addition && $0.text == "+fresh" })
    }

    @Test func commitDiffRecordsARename() async throws {
        let repo = try Repo()
        repo.git("mv", "README.md", "MANUAL.md")
        repo.git("commit", "-qm", "rename")

        let history = await GitInspector.recentCommits(at: repo.path)
        let diff = await GitInspector.commitDiff(history.commits[0].hash, root: repo.path)
        #expect(diff.lines.contains { $0.kind == .meta && $0.text == "rename from README.md" })
        #expect(diff.lines.contains { $0.kind == .meta && $0.text == "rename to MANUAL.md" })
    }

    @Test func commitDiffReportsAnUnknownHash() async throws {
        let repo = try Repo()
        let diff = await GitInspector.commitDiff("0000000000000000000000000000000000000000",
                                                 root: repo.path)
        #expect(diff.note?.isEmpty == false)
    }

    // A repository with one commit and an identity of its own, so the actions under test
    // can commit without leaning on the machine's git config. Thrown away with the test.
    private final class Repo {
        let url: URL
        var path: String { url.path }

        // An empty repo has been initialised but never committed to, which is how a
        // brand new project folder looks.
        init(empty: Bool = false) throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("actions-repo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            git("init", "-q", "-b", "main")
            configureIdentity()
            guard !empty else { return }
            try write("README.md", "hello")
            git("add", ".")
            git("commit", "-qm", "first")
        }

        init(cloneOf remote: Bare) throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("actions-clone-" + UUID().uuidString)
            Self.run(in: FileManager.default.temporaryDirectory,
                     ["clone", "-q", remote.path, url.path])
            configureIdentity()
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func read(_ name: String) -> String? {
            try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
        }

        var head: String {
            Self.output(in: url, ["rev-parse", "HEAD"])
        }

        // The files the newest commit touched, straight from git rather than a snapshot.
        var committedFiles: [String] {
            Self.output(in: url, ["show", "--name-only", "--format=", "HEAD"])
                .split(separator: "\n").map(String.init)
        }

        var commitCount: Int {
            Int(Self.output(in: url, ["rev-list", "--count", "HEAD"])) ?? 0
        }

        var stagedFiles: [String] {
            Self.output(in: url, ["diff", "--cached", "--name-only"])
                .split(separator: "\n").map(String.init)
        }

        func git(_ arguments: String...) {
            Self.run(in: url, arguments)
        }

        private func configureIdentity() {
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "Test")
            git("config", "commit.gpgsign", "false")
        }

        static func run(in directory: URL, _ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
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

    // A bare repository standing in for the remote, so push and pull never leave the
    // machine.
    private final class Bare {
        let url: URL
        var path: String { url.path }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("actions-remote-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            Repo.run(in: url, ["init", "-q", "--bare", "-b", "main"])
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }
}
