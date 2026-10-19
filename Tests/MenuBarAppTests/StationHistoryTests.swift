import Foundation
import Testing
@testable import CodeStationCore

// A session's commit history and pull requests through the station commands façade: the
// commits each of its checkouts has, newest first, the pull requests it opened, and one
// commit's files with their diffs against its parent. These run against throwaway git
// repositories.
@MainActor
struct StationHistoryTests {

    // One session in the project folder of a fresh repository with two commits.
    @MainActor
    private struct Fixture {
        let repo: GitRepo
        let scratch: ScratchDirectory
        let store: ProjectStore
        let commands: any StationInterface
        let sessionID: String

        init(_ kind: StationImplementation) throws {
            repo = try GitRepo(initialCommit: false)
            try repo.write("app.txt", "one\ntwo\n")
            try repo.commit("Add the app")
            try repo.write("app.txt", "one\nTWO\nthree\n")
            try repo.write("notes.md", "new\n")
            try repo.commit("Shout two and add notes")
            scratch = ScratchDirectory(prefix: "station-history")
            store = ProjectStore(storeURL: scratch.path("projects.json"))
            let project = try #require(store.addProject(at: repo.url))
            sessionID = try store.insertSession(in: project.id).get().id.uuidString
            let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()),
                                          refreshInterval: .milliseconds(50))
            commands = kind.connect(to: station)
        }

        var checkout: String { repo.path }
    }

    // The history names each checkout and lists its commits newest first, each with its
    // subject, author and hashes, and the pull requests the session opened.
    @Test(arguments: StationImplementation.allCases)
    func theHistoryListsCommitsNewestFirstAndThePullRequests(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        let id = try #require(UUID(uuidString: fixture.sessionID))
        fixture.store.notePullRequest(PullRequest(number: 7, url: "https://github.com/teya/app/pull/7"), for: id)
        fixture.store.notePullRequest(PullRequest(number: 9, url: "https://github.com/teya/app/pull/9"), for: id)

        let history = try await fixture.commands.readHistory(fixture.sessionID)

        #expect(history.sessionID == fixture.sessionID)
        let log = try #require(history.checkouts.first)
        #expect(history.checkouts.count == 1)
        #expect(log.path == fixture.checkout)
        #expect(log.isWorktree == false)
        #expect(log.note == nil)
        #expect(log.commits.map(\.subject) == ["Shout two and add notes", "Add the app"])
        let newest = try #require(log.commits.first)
        #expect(newest.hash == fixture.repo.head)
        #expect(newest.hash.hasPrefix(newest.shortHash))
        #expect(newest.author == "Test")
        #expect(!newest.relativeDate.isEmpty)
        #expect(history.pullRequests.map(\.number) == [7, 9])
        #expect(history.pullRequests.first?.url == "https://github.com/teya/app/pull/7")
    }

    // A commit comes with the files it changed, each with its diff against its parent;
    // the first commit is compared with the empty tree.
    @Test(arguments: StationImplementation.allCases)
    func aCommitListsItsFilesWithTheirDiffs(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        let commits = try await fixture.commands.readHistory(fixture.sessionID).checkouts[0].commits

        let newest = try await fixture.commands.readCommit(fixture.sessionID, checkout: fixture.checkout,
                                                           hash: commits[0].hash)

        #expect(newest.hash == commits[0].hash)
        #expect(newest.parents == [commits[1].hash])
        #expect(newest.note == nil)
        #expect(newest.files.map(\.path) == ["app.txt", "notes.md"])
        #expect(newest.files.map(\.status) == ["modified", "added"])
        let app = try #require(newest.files.first)
        #expect(app.added == 2 && app.removed == 1)
        #expect(app.diff.lines.filter { $0.kind == .addition }.map(\.text) == ["+TWO", "+three"])
        #expect(app.diff.lines.filter { $0.kind == .deletion }.map(\.text) == ["-two"])

        let first = try await fixture.commands.readCommit(fixture.sessionID, checkout: fixture.checkout,
                                                          hash: commits[1].hash)
        #expect(first.parents == [])
        #expect(first.files.map(\.path) == ["app.txt"])
        #expect(first.files.first?.diff.lines.filter { $0.kind == .addition }.map(\.text) == ["+one", "+two"])
    }

    // A session that is gone, a folder it does not work in, and something that is not a
    // commit of the checkout are refused.
    @Test(arguments: StationImplementation.allCases)
    func historyThatCannotBeReadIsRefused(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        let commands = fixture.commands, id = fixture.sessionID, checkout = fixture.checkout
        let head = fixture.repo.head

        await #expect(throws: StationRefusal("That session is no longer available.")) {
            try await commands.readHistory(UUID().uuidString)
        }
        await #expect(throws: StationRefusal("That session is no longer available.")) {
            try await commands.readCommit(UUID().uuidString, checkout: checkout, hash: head)
        }
        await #expect(throws: StationRefusal("This session does not work in \(NSTemporaryDirectory()).")) {
            try await commands.readCommit(id, checkout: NSTemporaryDirectory(), hash: head)
        }
        await #expect(throws: StationRefusal("--output=/tmp/x is not a commit.")) {
            try await commands.readCommit(id, checkout: checkout, hash: "--output=/tmp/x")
        }
        await #expect(throws: StationRefusal("0123456789abcdef is not a commit.")) {
            try await commands.readCommit(id, checkout: checkout, hash: "0123456789abcdef")
        }
    }

    // A repository with no commits yet has an empty history, not a refusal.
    @Test(arguments: StationImplementation.allCases)
    func aRepositoryWithNoCommitsHasAnEmptyHistory(_ kind: StationImplementation) async throws {
        let repo = try GitRepo(initialCommit: false)
        let scratch = ScratchDirectory(prefix: "station-history")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: repo.url))
        let sessionID = try store.insertSession(in: project.id).get().id.uuidString
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()),
                                      refreshInterval: .milliseconds(50))
        let commands = kind.connect(to: station)

        let history = try await commands.readHistory(sessionID)

        #expect(history.checkouts.map(\.commits.count) == [0])
        #expect(history.checkouts.first?.note == nil)
        #expect(history.pullRequests == [])
    }
}
