import Foundation
import Testing
@testable import CodeStationCore

// Syncing a checkout with its remote and moving it between branches, through the station
// commands façade: push, pull and fetch, and switching to or creating a branch, from a
// session's checkout or a project's folder. These run against a throwaway repository
// whose origin is a local bare one.
@MainActor
struct StationSyncTests {

    // One session in the project folder of a repository that tracks a bare origin, and a
    // client of its host.
    @MainActor
    private struct Fixture {
        let repo: GitRepo
        let origin: GitRepo
        let scratch: ScratchDirectory
        let station: StationCommands
        let commands: any StationInterface
        let sessionID: String
        let projectID: String

        init(_ kind: StationImplementation) throws {
            repo = try GitRepo()
            origin = try GitRepo.bare()
            try repo.addRemote(origin)
            try repo.git("push", "-q", "-u", "origin", "main")
            scratch = ScratchDirectory(prefix: "station-sync")
            let store = ProjectStore(storeURL: scratch.path("projects.json"))
            let project = try #require(store.addProject(at: repo.url))
            projectID = project.id.uuidString
            sessionID = try store.insertSession(in: project.id).get().id.uuidString
            station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()),
                                      refreshInterval: .milliseconds(50))
            station.changesRefreshInterval = .milliseconds(200)
            commands = kind.connect(to: station)
        }

        var checkout: String { repo.path }

        // Another clone pushes a commit to origin, as a teammate would.
        func teammatePushes(_ subject: String) throws {
            let other = try origin.clone()
            try other.write("\(UUID().uuidString).txt", subject)
            try other.commit(subject)
            try other.git("push", "-q", "origin", "HEAD:main")
        }
    }

    // A push sends the branch's new commits to its upstream and says how many went.
    @Test(arguments: StationImplementation.allCases)
    func pushSendsTheNewCommitsToOrigin(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.repo.write("app.txt", "one\n")
        try fixture.repo.commit("Add the app")

        let result = try await fixture.commands.sync(fixture.sessionID, checkout: fixture.checkout, .push)

        #expect(result.summary == "Pushed 1 commit to origin/main")
        #expect(result.commits.map(\.subject) == ["Add the app"])
        #expect(try fixture.origin.git("rev-parse", "main") == fixture.repo.head)
    }

    // A branch with no upstream is published to origin under its own name, and tracks it.
    @Test(arguments: StationImplementation.allCases)
    func pushPublishesABranchWithNoUpstream(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.repo.git("switch", "-q", "-c", "feature")
        try fixture.repo.write("feature.txt", "new\n")
        try fixture.repo.commit("Start the feature")

        let result = try await fixture.commands.sync(fixture.sessionID, checkout: fixture.checkout, .push)

        #expect(result.summary == "Published feature to origin")
        #expect(try fixture.origin.git("rev-parse", "feature") == fixture.repo.head)
        #expect(try fixture.repo.git("rev-parse", "--abbrev-ref", "@{u}") == "origin/feature")
    }

    // A branch that trails origin is refused before anything is sent, and says to pull.
    @Test(arguments: StationImplementation.allCases)
    func pushIsRefusedWhileOriginIsAhead(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.teammatePushes("Teammate's work")
        try fixture.repo.write("mine.txt", "mine\n")
        try fixture.repo.commit("My work")
        let originHead = try fixture.origin.git("rev-parse", "main")
        let commands = fixture.commands, id = fixture.sessionID, checkout = fixture.checkout

        await #expect(throws: StationRefusal("origin/main has 1 commit this branch does not, so origin would "
                                             + "refuse the push. Pull first, then push.")) {
            _ = try await commands.sync(id, checkout: checkout, .push)
        }
        #expect(try fixture.origin.git("rev-parse", "main") == originHead)
    }

    // A pull brings origin's new commits in and names them; a second one has nothing to do.
    @Test(arguments: StationImplementation.allCases)
    func pullBringsOriginsCommitsIn(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.teammatePushes("Teammate's work")

        let result = try await fixture.commands.sync(fixture.sessionID, checkout: fixture.checkout, .pull)

        #expect(result.summary == "Pulled 1 commit from origin/main")
        #expect(result.commits.map(\.subject) == ["Teammate's work"])
        #expect(try fixture.repo.git("log", "-1", "--format=%s") == "Teammate's work")

        let again = try await fixture.commands.sync(fixture.sessionID, checkout: fixture.checkout, .pull)
        #expect(again.summary == "Already up to date with origin/main")
    }

    // A fetch reads origin without moving the branch, and says how far apart they now are.
    @Test(arguments: StationImplementation.allCases)
    func fetchReadsOriginWithoutMovingTheBranch(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.teammatePushes("Teammate's work")
        try fixture.origin.git("branch", "topic", "main")
        let head = fixture.repo.head

        let result = try await fixture.commands.sync(fixture.sessionID, checkout: fixture.checkout, .fetch)

        #expect(result.summary == "Fetched origin · 0 ahead · 1 behind origin/main")
        #expect(fixture.repo.head == head)
        let branches = try await fixture.commands.readBranches(fixture.sessionID, checkout: fixture.checkout)
        #expect(branches.behind == 1)
        #expect(branches.local == ["main"])
        #expect(Set(branches.remote) == ["origin/main", "origin/topic"])
    }

    // A failure on the way to origin comes back as a refusal with git's own words.
    @Test(arguments: StationImplementation.allCases)
    func aSyncThatFailsSaysWhy(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.repo.git("remote", "set-url", "origin", fixture.scratch.path("gone").path)
        let commands = fixture.commands, id = fixture.sessionID, checkout = fixture.checkout

        do throws(StationRefusal) {
            _ = try await commands.sync(id, checkout: checkout, .fetch)
            Issue.record("The fetch went through.")
        } catch {
            #expect(error.message.contains("does not appear to be a git repository"), "\(error.message)")
        }
        try fixture.repo.git("remote", "remove", "origin")
        await #expect(throws: StationRefusal("This repository has no origin to fetch from.")) {
            _ = try await commands.sync(id, checkout: checkout, .fetch)
        }
    }

    // Creating a branch switches to it; switching goes back by name, and a remote branch
    // with no local one gets a local branch that tracks it.
    @Test(arguments: StationImplementation.allCases)
    func branchesAreCreatedAndSwitchedTo(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.origin.git("branch", "topic", "main")
        try fixture.repo.git("fetch", "-q", "origin")
        let commands = fixture.commands, id = fixture.sessionID, checkout = fixture.checkout

        try await commands.switchBranch(id, checkout: checkout, to: " feature ", creating: true)
        #expect(try await commands.readBranches(id, checkout: checkout).current == "feature")

        try await commands.switchBranch(id, checkout: checkout, to: "main", creating: false)
        #expect(try await commands.readBranches(id, checkout: checkout).current == "main")

        try await commands.switchBranch(id, checkout: checkout, to: "origin/topic", creating: false)
        let branches = try await commands.readBranches(id, checkout: checkout)
        #expect(branches.current == "topic")
        #expect(branches.upstream == "origin/topic")
        #expect(Set(branches.local) == ["main", "feature", "topic"])

        await #expect(throws: StationRefusal("A branch called main already exists.")) {
            try await commands.switchBranch(id, checkout: checkout, to: "main", creating: true)
        }
        await #expect(throws: StationRefusal("There is no branch called nowhere.")) {
            try await commands.switchBranch(id, checkout: checkout, to: "nowhere", creating: false)
        }
        await #expect(throws: StationRefusal("Name the branch first.")) {
            try await commands.switchBranch(id, checkout: checkout, to: "  ", creating: true)
        }
    }

    // A project's screen syncs its folder by the project's id; a folder that is not one of
    // the place's checkouts is refused.
    @Test(arguments: StationImplementation.allCases)
    func aProjectSyncsItsFolderAndNothingElse(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.repo.write("app.txt", "one\n")
        try fixture.repo.commit("Add the app")
        let commands = fixture.commands

        let result = try await commands.sync(fixture.projectID, checkout: fixture.checkout, .push)
        #expect(result.summary == "Pushed 1 commit to origin/main")

        let elsewhere = try GitRepo()
        await #expect(throws: StationRefusal("\(elsewhere.path) is not one of this place's checkouts.")) {
            _ = try await commands.sync(fixture.projectID, checkout: elsewhere.path, .fetch)
        }
        await #expect(throws: StationRefusal.self) {
            _ = try await commands.readBranches(UUID().uuidString, checkout: fixture.checkout)
        }
    }

    // A push or switch shows up in a live changes subscription straight away.
    @Test(arguments: StationImplementation.allCases)
    func aSwitchReachesTheLiveChanges(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        let stream = fixture.commands.changesUpdates(fixture.sessionID)
        let latest = Latest()
        let reading = Task { @MainActor in
            for await changes in stream { latest.branch = changes.checkouts.first?.branch }
        }
        defer { reading.cancel() }
        #expect(await waitUntil { latest.branch == "main" })

        try await fixture.commands.switchBranch(fixture.sessionID, checkout: fixture.checkout, to: "feature",
                                                creating: true)

        #expect(await waitUntil { latest.branch == "feature" }, "\(latest.branch ?? "nil")")
    }

    @MainActor
    private final class Latest {
        var branch: String?
    }
}
