import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ShortcutStoreTests {
    // The shortcuts a first run starts with come from the site file, and the tests run
    // without one, so a fresh store is empty and writes nothing until it is edited.
    @Test func startsFromTheSiteFileWhenNoFileExists() {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ShortcutStore(storageURL: url)

        #expect(store.shortcuts.map(\.name)
            == SiteDefaults.current.commandShortcuts.map(\.name))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func persistsAddsAndEdits() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShortcutStore(storageURL: url)

        let id = try #require(store.add(
            name: "  API server  ", command: "  ./gradlew bootRun  "))
        store.update(CommandShortcut(id: id, name: "Service", command: "./gradlew run"))

        let reloaded = ShortcutStore(storageURL: url)
        #expect(reloaded.shortcuts == [
            CommandShortcut(id: id, name: "Service", command: "./gradlew run")
        ])

        reloaded.remove(id)
        #expect(ShortcutStore(storageURL: url).shortcuts.isEmpty)
    }

    // A shortcut saved before shortcuts could belong to a project is the Mac's own.
    @Test func readsShortcutsSavedWithoutAnOwner() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        try Data("""
        { "shortcuts": [ { "id": "\(id.uuidString)", "name": "Prune", "command": "docker system prune" } ] }
        """.utf8).write(to: url)

        let store = ShortcutStore(storageURL: url)

        #expect(store.loadError == nil)
        #expect(store.shortcuts == [
            CommandShortcut(id: id, name: "Prune", command: "docker system prune")
        ])
        #expect(store.macShortcuts.count == 1)
    }

    // Who a shortcut belongs to is the only thing that decides where it runs, so the
    // Mac's own ignore every checkout it is offered.
    @Test func resolvesTheFolderFromWhoTheShortcutBelongsTo() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let mac = CommandShortcut(name: "Prune", command: "docker system prune")
        #expect(mac.directory(projectPath: "/repos/lantern", workspacePath: "/worktrees/a")
            == home)

        let owned = CommandShortcut(name: "Lint", command: "npm run lint",
                                    projectID: UUID())
        #expect(owned.directory(projectPath: "/repos/lantern", workspacePath: "/worktrees/a")
            == "/worktrees/a")
        // No worktree in front of you means the folder the worktrees come from.
        #expect(owned.directory(projectPath: "/repos/lantern") == "/repos/lantern")
        // And a project whose folder cannot be found is still somewhere runnable.
        #expect(owned.directory(projectPath: nil) == home)
    }

    @Test func groupsShortcutsByOwner() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShortcutStore(storageURL: url)
        let lantern = UUID()
        let other = UUID()

        let prune = try #require(store.add(name: "Prune", command: "docker system prune"))
        let lint = try #require(store.add(name: "Lint", command: "npm run lint",
                                          projectID: lantern))
        store.add(name: "Build", command: "make", projectID: other)

        #expect(store.macShortcuts.map(\.id) == [prune])
        #expect(store.shortcuts(for: lantern).map(\.id) == [lint])
        #expect(store.shortcuts(for: other).count == 1)

        store.removeAll(ownedBy: lantern)
        #expect(store.shortcuts(for: lantern).isEmpty)
        #expect(store.shortcuts.count == 2)
    }

    // The Mac's list and a project's are separate screens, so neither may report the
    // other's runs: a count on one that included the other would speak for runs its
    // reader cannot see.
    @Test func countsRunsOnlyForTheListDoingTheAsking() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShortcutStore(storageURL: url)
        let lantern = UUID()
        let owned = try #require(store.add(name: "Lint", command: "exit 1",
                                           projectID: lantern))
        let run = ShortcutRun(owned, in: FileManager.default.temporaryDirectory.path)

        store.start(run)
        try await settle(store, run)

        #expect(store.failureCount(of: store.shortcuts(for: lantern)) == 1)
        #expect(store.failureCount(of: store.macShortcuts) == 0)
    }

    @Test func refusesToOverwriteAnUnreadableFile() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not json".utf8)
        try original.write(to: url)

        let store = ShortcutStore(storageURL: url)
        #expect(store.loadError != nil)

        store.add(name: "Build", command: "swift build")

        #expect(store.saveError != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func runsACommandAndCapturesBothOutputStreams() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShortcutStore(storageURL: url)
        let id = try #require(store.add(
            name: "Output",
            command: "printf 'standard output'; printf 'error output' >&2"
        ))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)

        store.start(run)
        try await settle(store, run)

        #expect(store.state(run).since != nil)
        if case .finished = store.state(run) {} else { Issue.record("expected a clean exit") }
        #expect(store.log(run).contains("standard output"))
        #expect(store.log(run).contains("error output"))
    }

    @Test func reportsTheExitCodeOfACommandThatFails() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShortcutStore(storageURL: url)
        let id = try #require(store.add(name: "Lint", command: "exit 3"))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)

        store.start(run)
        try await settle(store, run)

        guard case .failed(_, let status, _) = store.state(run) else {
            Issue.record("expected a failure")
            return
        }
        #expect(status == 3)
        #expect(store.failureCount(of: store.macShortcuts) == 1)
    }

    // The same shortcut in two worktrees is two runs. Neither may report the other's
    // state, which is the whole reason a run is a shortcut and a folder together.
    @Test func keepsRunsInDifferentFoldersApart() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-runs-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ShortcutStore(storageURL: url)
        let id = try #require(store.add(name: "Where", command: "pwd"))
        let one = ShortcutRun(id, in: first.path)
        let two = ShortcutRun(id, in: second.path)

        store.start(one)
        try await settle(store, one)
        #expect(store.log(one).contains("first"))
        #expect(store.state(two) == .stopped)

        store.start(two)
        try await settle(store, two)
        #expect(store.log(two).contains("second"))
        #expect(!store.log(two).contains("/first"))
    }

    // Moving a shortcut to another folder leaves its old runs pointing at a command that
    // is no longer there, so the state they carry stops meaning anything.
    @Test func forgetsRunsWhenAShortcutIsEdited() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ShortcutStore(storageURL: url)
        let id = try #require(store.add(name: "Say", command: "echo hello"))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)

        store.start(run)
        try await settle(store, run)
        #expect(!store.log(run).isEmpty)

        store.update(CommandShortcut(id: id, name: "Say", command: "echo goodbye"))

        #expect(store.state(run) == .stopped)
        #expect(store.log(run).isEmpty)
    }

    private func settle(_ store: ShortcutStore, _ run: ShortcutRun) async throws {
        for _ in 0..<400 where store.state(run).isActive {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-store-tests-\(UUID().uuidString)")
            .appendingPathComponent("shortcuts.json")
    }
}
