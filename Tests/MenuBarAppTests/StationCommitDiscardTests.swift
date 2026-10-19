import Foundation
import Testing
@testable import CodeStationCore

// A session's changes kept live, and the commands that act on them, through the station
// commands façade: the changes subscription pushes what the agent edits, a commit takes
// every change or a chosen set of files with a message, and a discard puts a file back
// the way the last commit has it. These run against throwaway git repositories.
@MainActor
struct StationCommitDiscardTests {

    // The live changes are read with git on a queue the whole test process shares, which
    // other suites' git work can keep busy for a long while. A wait returns as soon as
    // what it waits for shows, so a generous one costs nothing when the machine is idle.
    static let liveWait: Duration = .seconds(120)

    // One session in the project folder of a fresh repository, and a client of its host.
    @MainActor
    private struct Fixture {
        let repo: GitRepo
        let scratch: ScratchDirectory
        let station: StationCommands
        let commands: any StationInterface
        let sessionID: String

        init(_ kind: StationImplementation, files: [String: String] = ["app.txt": "one\ntwo\n"]) throws {
            repo = try GitRepo()
            for (path, contents) in files { try repo.write(path, contents) }
            try repo.commit("add files")
            scratch = ScratchDirectory(prefix: "station-commit")
            let store = ProjectStore(storeURL: scratch.path("projects.json"))
            let project = try #require(store.addProject(at: repo.url))
            sessionID = try store.insertSession(in: project.id).get().id.uuidString
            station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()),
                                      refreshInterval: .milliseconds(50))
            station.changesRefreshInterval = .milliseconds(200)
            station.trash = TestTrash().move
            commands = kind.connect(to: station)
        }

        var checkout: String { repo.path }
    }

    // What a changes subscription has pushed so far.
    @MainActor
    private final class Live {
        private(set) var pushed: [RemoteChanges] = []
        private var reading: Task<Void, Never>?
        var latest: RemoteChanges? { pushed.last }
        var paths: [String] { latest?.checkouts.flatMap { $0.files.map(\.path) } ?? [] }

        init(_ stream: AsyncStream<RemoteChanges>) {
            reading = Task { @MainActor [weak self] in
                for await changes in stream { self?.pushed.append(changes) }
            }
        }

        func stop() { reading?.cancel() }
    }

    // The subscription starts with the changes as they stand, then pushes a fresh copy
    // as files are edited, with each file's diff, and nothing while the tree stands still.
    @Test(arguments: StationImplementation.allCases)
    func theChangesSubscriptionPushesEditsAsTheyHappen(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        let live = Live(fixture.commands.changesUpdates(fixture.sessionID))
        defer { live.stop() }
        #expect(await waitUntil(timeout: Self.liveWait) { live.latest != nil })
        #expect(live.paths == [])

        try fixture.repo.write("app.txt", "one\nTWO\n")

        #expect(await waitUntil(timeout: Self.liveWait) { live.paths == ["app.txt"] }, "\(live.paths)")
        let diff = try #require(live.latest?.checkouts.first?.files.first?.diff)
        #expect(diff.lines.filter { $0.kind == .addition }.map(\.text) == ["+TWO"])

        // The same line counts, but other text: still a change worth sending.
        try fixture.repo.write("app.txt", "one\nTwo\n")
        #expect(await waitUntil(timeout: Self.liveWait) {
            live.latest?.checkouts.first?.files.first?.diff.lines.contains { $0.text == "+Two" } == true
        })

        let sent = live.pushed.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(live.pushed.count == sent)
    }

    // Committing everything takes every changed file, new ones too, in one commit with
    // the message given, and the live changes come back empty.
    @Test(arguments: StationImplementation.allCases)
    func committingEverythingLeavesNoChanges(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.repo.write("app.txt", "one\ntwo\nthree\n")
        try fixture.repo.write("notes.md", "new\n")
        let live = Live(fixture.commands.changesUpdates(fixture.sessionID))
        defer { live.stop() }
        #expect(await waitUntil(timeout: Self.liveWait) { live.paths == ["app.txt", "notes.md"] }, "\(live.paths)")

        try await fixture.commands.commitChanges(fixture.sessionID, checkout: fixture.checkout,
                                                 message: "  Add three and notes  ", paths: nil)

        #expect(try fixture.repo.git("log", "-1", "--format=%s") == "Add three and notes")
        #expect(try fixture.repo.git("show", "--name-only", "--format=", "HEAD") == "app.txt\nnotes.md")
        #expect(try fixture.repo.git("status", "--porcelain") == "")
        #expect(await waitUntil(timeout: Self.liveWait) { live.latest != nil && live.paths.isEmpty }, "\(live.paths)")
    }

    // Committing chosen files takes only those, and leaves the others changed.
    @Test(arguments: StationImplementation.allCases)
    func committingChosenFilesLeavesTheRest(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind, files: ["app.txt": "one\n", "other.txt": "a\n"])
        try fixture.repo.write("app.txt", "one\ntwo\n")
        try fixture.repo.write("other.txt", "a\nb\n")
        try fixture.repo.write("notes.md", "new\n")

        try await fixture.commands.commitChanges(fixture.sessionID, checkout: fixture.checkout,
                                                 message: "Only the app and notes",
                                                 paths: ["notes.md", "app.txt"])

        #expect(try fixture.repo.git("log", "-1", "--format=%s") == "Only the app and notes")
        #expect(try fixture.repo.git("show", "--name-only", "--format=", "HEAD") == "app.txt\nnotes.md")
        #expect(try fixture.repo.git("status", "--porcelain") == "M other.txt")
        let changes = try #require(try await fixture.commands.readChanges(fixture.sessionID))
        #expect(changes.checkouts.first?.files.map(\.path) == ["other.txt"])
    }

    // A commit with nothing to say, nothing chosen, a file no longer changed or a folder
    // the session does not work in is refused, and nothing is committed.
    @Test(arguments: StationImplementation.allCases)
    func aCommitThatCannotGoAheadIsRefused(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        try fixture.repo.write("app.txt", "changed\n")
        let head = fixture.repo.head
        let commands = fixture.commands, id = fixture.sessionID, checkout = fixture.checkout

        await #expect(throws: StationRefusal("Write a commit message first.")) {
            try await commands.commitChanges(id, checkout: checkout, message: "  ", paths: nil)
        }
        await #expect(throws: StationRefusal("Choose at least one file.")) {
            try await commands.commitChanges(id, checkout: checkout, message: "m", paths: [])
        }
        await #expect(throws: StationRefusal("README.md has no changes any more.")) {
            try await commands.commitChanges(id, checkout: checkout, message: "m", paths: ["README.md"])
        }
        await #expect(throws: StationRefusal.self) {
            try await commands.commitChanges(id, checkout: NSTemporaryDirectory(), message: "m", paths: nil)
        }
        await #expect(throws: StationRefusal.self) {
            try await commands.commitChanges(UUID().uuidString, checkout: checkout, message: "m", paths: nil)
        }
        #expect(fixture.repo.head == head)
    }

    // Discarding puts a file back the way the last commit has it, and leaves the other
    // changed files alone. The live changes drop it at once.
    @Test(arguments: StationImplementation.allCases)
    func discardingAFilePutsItBackAsCommitted(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind, files: ["app.txt": "one\n", "other.txt": "a\n"])
        try fixture.repo.write("app.txt", "one\ntwo\n")
        try fixture.repo.write("other.txt", "a\nb\n")
        let live = Live(fixture.commands.changesUpdates(fixture.sessionID))
        defer { live.stop() }
        #expect(await waitUntil(timeout: Self.liveWait) { live.paths == ["app.txt", "other.txt"] }, "\(live.paths)")

        try await fixture.commands.discardChanges(fixture.sessionID, checkout: fixture.checkout,
                                                  paths: ["app.txt"])

        let app = try String(contentsOf: fixture.repo.url.appendingPathComponent("app.txt"), encoding: .utf8)
        #expect(app == "one\n")
        #expect(try fixture.repo.git("status", "--porcelain") == "M other.txt")
        #expect(await waitUntil(timeout: Self.liveWait) { live.paths == ["other.txt"] }, "\(live.paths)")
        await #expect(throws: StationRefusal("app.txt has no changes any more.")) {
            try await fixture.commands.discardChanges(fixture.sessionID, checkout: fixture.checkout,
                                                      paths: ["app.txt"])
        }
    }

    // A session that goes away ends its changes stream.
    @Test(arguments: StationImplementation.allCases)
    func theChangesStreamEndsWhenTheSessionGoesAway(_ kind: StationImplementation) async throws {
        let fixture = try Fixture(kind)
        let stream = fixture.commands.changesUpdates(fixture.sessionID)
        let ended = Ended()
        let reading = Task { @MainActor in
            for await _ in stream {}
            ended.value = true
        }
        defer { reading.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ended.value)

        let id = try #require(UUID(uuidString: fixture.sessionID))
        _ = fixture.station.store.removeSession(id)

        #expect(await waitUntil(timeout: Self.liveWait) { ended.value })
    }

    @MainActor
    private final class Ended {
        var value = false
    }
}

