import Foundation
import Testing
@testable import CodeStationCore

// Reading a session's changes through the station commands façade: the branch, the
// status and the changed files of every checkout the session works in, each file with
// its unified diff, all as plain Codable values. These run against throwaway git
// repositories.
@MainActor
struct StationChangesTests {

    // A session working in the project folder itself reads that folder's changes: an
    // edited file with its removed and added lines, and a new file shown whole.
    @Test(arguments: StationImplementation.allCases)
    func aSessionInTheProjectFolderReadsItsFilesAndDiffs(_ kind: StationImplementation) async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", "one\ntwo\nthree\n")
        try repo.commit("add app")
        try repo.write("app.txt", "one\nTWO\nthree\n")
        try repo.write("notes/new.md", "fresh\nnotes\n")

        let scratch = ScratchDirectory(prefix: "station-changes")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: repo.url))
        let session = try store.insertSession(in: project.id).get()
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()))
        let commands = kind.connect(to: station)

        let changes = try #require(try await commands.readChanges(session.id.uuidString))

        #expect(changes.sessionID == session.id.uuidString)
        let checkout = try #require(changes.checkouts.first)
        #expect(changes.checkouts.count == 1)
        #expect(checkout.project == project.name)
        #expect(checkout.isWorktree == false)
        #expect(checkout.branch == "main")
        #expect(checkout.state == "ready")
        #expect(checkout.status == "No upstream branch")
        #expect(checkout.files.map(\.path) == ["app.txt", "notes/new.md"])
        #expect(checkout.files.map(\.status) == ["modified", "untracked"])
        #expect(checkout.files.map(\.added) == [1, 2])
        #expect(checkout.files.map(\.removed) == [1, 0])

        let edited = checkout.files[0].diff
        #expect(edited.lines.filter { $0.kind == .deletion }.map(\.text) == ["-two"])
        #expect(edited.lines.filter { $0.kind == .addition }.map(\.text) == ["+TWO"])
        #expect(edited.lines.filter { $0.kind == .context }.map(\.text) == [" one", " three"])
        #expect(edited.lines.first?.kind == .hunk)

        let added = checkout.files[1].diff
        #expect(added.lines.filter { $0.kind == .addition }.map(\.text) == ["+fresh", "+notes"])
        #expect(!added.lines.contains { $0.kind == .deletion })
    }

    // A session in a worktree of its own reads that worktree, on its own branch, and
    // not whatever is going on in the project folder beside it.
    @Test(arguments: StationImplementation.allCases)
    func aWorktreeSessionReadsItsWorktreeAndNotTheProjectFolder(_ kind: StationImplementation) async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", "one\n")
        try repo.commit("add app")
        let scratch = ScratchDirectory(prefix: "station-changes")
        let tree = scratch.path("tree").path
        try repo.git("worktree", "add", "-q", "-b", "code-station/fix", tree)
        try "one\ntwo\n".write(toFile: tree + "/app.txt", atomically: true, encoding: .utf8)
        try repo.write("elsewhere.txt", "not this session's\n")

        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: repo.url))
        let session = try store.insertSession(in: project.id, worktreePath: tree,
                                              worktreeBranch: "code-station/fix").get()
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()))
        let commands = kind.connect(to: station)

        let changes = try #require(try await commands.readChanges(session.id.uuidString))

        let checkout = try #require(changes.checkouts.first)
        #expect(checkout.isWorktree)
        #expect(checkout.path == tree)
        #expect(checkout.branch == "code-station/fix")
        #expect(checkout.files.map(\.path) == ["app.txt"])
        #expect(checkout.files[0].diff.lines.filter { $0.kind == .addition }.map(\.text) == ["+two"])
    }

    // Once git has been asked, an open session's header counts git's lines rather than
    // the transcript's running total. The answer also has to survive being written out
    // and read back, with its type and version on the wire.
    @Test(arguments: StationImplementation.allCases)
    func readChangesFeedsTheHeaderAndRoundTripsThroughJSON(_ kind: StationImplementation) async throws {
        let repo = try GitRepo()
        try repo.write("app.txt", "one\ntwo\nthree\n")
        try repo.commit("add app")
        try repo.write("app.txt", "uno\ndos\nthree\nfour\n")

        let scratch = ScratchDirectory(prefix: "station-changes")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let project = try #require(store.addProject(at: repo.url))
        let session = try store.insertSession(in: project.id).get()
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()))
        let commands = kind.connect(to: station)
        let before = try #require(try await commands.openSession(session.id.uuidString)).snapshot.header
        #expect(before.added == 0 && before.removed == 0)
        await commands.closeSession(session.id.uuidString)

        let changes = try #require(try await commands.readChanges(session.id.uuidString))

        let header = try #require(try await commands.openSession(session.id.uuidString)).snapshot.header
        #expect(header.added == 3)
        #expect(header.removed == 2)
        #expect(header.branch == "main")

        let data = try JSONEncoder().encode(changes)
        #expect(try JSONDecoder().decode(RemoteChanges.self, from: data) == changes)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "changes")
        #expect(object["version"] as? Int == 1)
        let checkouts = try #require(object["checkouts"] as? [[String: Any]])
        let files = try #require(checkouts.first?["files"] as? [[String: Any]])
        let diff = try #require(files.first?["diff"] as? [String: Any])
        #expect(diff["type"] as? String == "diff")
        #expect((diff["lines"] as? [[String: Any]])?.first?["kind"] as? String == "hunk")
    }

    @Test(arguments: StationImplementation.allCases)
    func anUnknownSessionHasNoChanges(_ kind: StationImplementation) async throws {
        let scratch = ScratchDirectory(prefix: "station-changes")
        let store = ProjectStore(storeURL: scratch.path("projects.json"))
        let station = StationCommands(store: store, runner: SessionRunner(host: RecordingHost()))
        let commands = kind.connect(to: station)
        #expect(try await commands.readChanges(UUID().uuidString) == nil)
        #expect(try await commands.readChanges("not an id") == nil)
    }
}
