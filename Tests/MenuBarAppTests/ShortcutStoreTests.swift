import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ShortcutStoreTests {
    private let scratch = ScratchDirectory(prefix: "shortcut-store-tests")
    private var url: URL { scratch.path("shortcuts.json") }

    // The shortcuts a first run starts with come from the site file, and the tests run
    // without one, so a fresh store is empty and writes nothing until it is edited.
    @Test func startsFromTheSiteFileWhenNoFileExists() {
        let store = ShortcutStore(storageURL: url)

        #expect(store.shortcuts.map(\.name)
            == SiteDefaults.current.startingShortcuts.map(\.name))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func persistsAddsAndEdits() throws {
        let store = emptyStore(url)

        let id = try #require(store.add(
            name: "  API server  ", text: "  ./gradlew bootRun  "))
        store.update(Shortcut(id: id, name: "Service", text: "./gradlew run",
                                     availableInAllProjects: true))

        let reloaded = emptyStore(url)
        #expect(reloaded.shortcuts == [
            Shortcut(id: id, name: "Service", text: "./gradlew run",
                            availableInAllProjects: true)
        ])

        reloaded.remove(id)
        #expect(emptyStore(url).shortcuts.isEmpty)
    }

    // A shortcut saved before shortcuts could belong to a project is the Mac's own.
    @Test func readsShortcutsSavedWithoutAnOwner() throws {
        let id = UUID()
        try Data("""
        { "shortcuts": [ { "id": "\(id.uuidString)", "name": "Prune", "command": "docker system prune" } ] }
        """.utf8).write(to: url)

        let store = emptyStore(url)

        #expect(store.loadError == nil)
        #expect(store.shortcuts == [
            Shortcut(id: id, name: "Prune", text: "docker system prune")
        ])
        #expect(store.macShortcuts.count == 1)
    }

    // Private Mac shortcuts ignore every checkout, while project and shared shortcuts
    // use the project folder or session worktree they are offered.
    @Test func resolvesTheFolderFromWhoTheShortcutBelongsTo() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let mac = Shortcut(name: "Prune", text: "docker system prune")
        #expect(mac.directory(projectPath: "/repos/lantern", workspacePath: "/worktrees/a")
            == home)

        let owned = Shortcut(name: "Lint", text: "npm run lint",
                                    projectID: UUID())
        #expect(owned.directory(projectPath: "/repos/lantern", workspacePath: "/worktrees/a")
            == "/worktrees/a")
        // No worktree in front of you means the folder the worktrees come from.
        #expect(owned.directory(projectPath: "/repos/lantern") == "/repos/lantern")
        // And a project whose folder cannot be found is still somewhere runnable.
        #expect(owned.directory(projectPath: nil) == home)

        let shared = Shortcut(name: "Build", text: "make",
                                     availableInAllProjects: true)
        #expect(shared.directory(projectPath: "/repos/lantern",
                                 workspacePath: "/worktrees/a") == "/worktrees/a")
        #expect(shared.directory(projectPath: nil) == home)
    }

    @Test func groupsShortcutsByOwner() throws {
        let store = emptyStore(url)
        let lantern = UUID()
        let other = UUID()

        let prune = try #require(store.add(name: "Prune", text: "docker system prune"))
        let lint = try #require(store.add(name: "Lint", text: "npm run lint",
                                          projectID: lantern))
        let test = try #require(store.add(name: "Test", text: "swift test",
                                          projectID: lantern))
        let build = try #require(store.add(name: "Build", text: "make", projectID: other))
        let shared = try #require(store.add(name: "Format", text: "swift format",
                                            availableInAllProjects: true))

        #expect(store.macShortcuts.map(\.id) == [prune, shared])
        #expect(store.shortcuts(for: lantern).map(\.id) == [lint, test, shared])
        #expect(store.shortcuts(for: other).map(\.id) == [build, shared])

        store.removeAll(ownedBy: lantern)
        #expect(store.shortcuts(for: lantern).map(\.id) == [shared])
        #expect(store.shortcuts.count == 3)
    }

    @Test func placesASharedShortcutOnceInAWorkspace() throws {
        let store = emptyStore(url)
        let lead = UUID()
        let attached = UUID()

        let leadShortcut = try #require(store.add(name: "Lead", text: "make lead",
                                                   projectID: lead))
        let shared = try #require(store.add(name: "Shared", text: "make shared",
                                           availableInAllProjects: true))
        let attachedShortcut = try #require(store.add(name: "Attached", text: "make attached",
                                                       projectID: attached))

        let placements = store.shortcuts(for: [lead, attached])

        #expect(placements.map(\.shortcut.id) == [leadShortcut, shared, attachedShortcut])
        #expect(placements.map(\.projectID) == [lead, lead, attached])
    }

    // A count only considers the shortcuts in the list doing the asking.
    @Test func countsRunsOnlyForTheListDoingTheAsking() async throws {
        let store = emptyStore(url)
        let lantern = UUID()
        let owned = try #require(store.add(name: "Lint", text: "exit 1",
                                           projectID: lantern))
        let run = ShortcutRun(owned, in: FileManager.default.temporaryDirectory.path)

        store.start(run)
        #expect(await waitUntil { !store.state(run).isActive })

        #expect(store.failureCount(of: store.shortcuts(for: lantern)) == 1)
        #expect(store.failureCount(of: store.macShortcuts) == 0)
    }

    @Test func refusesToOverwriteAnUnreadableFile() throws {
        let original = Data("not json".utf8)
        try original.write(to: url)

        let store = emptyStore(url)
        #expect(store.loadError != nil)

        store.add(name: "Build", text: "swift build")

        #expect(store.saveError != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func runsACommandAndCapturesBothOutputStreams() async throws {
        let store = emptyStore(url)
        let id = try #require(store.add(
            name: "Output",
            text: "printf 'standard output'; printf 'error output' >&2"
        ))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)

        store.start(run)
        #expect(await waitUntil { !store.state(run).isActive })

        if case .finished = store.state(run) {} else { Issue.record("expected a clean exit") }
        #expect(store.log(run).contains("standard output"))
        #expect(store.log(run).contains("error output"))
    }

    @Test func reportsTheExitCodeOfACommandThatFails() async throws {
        let store = emptyStore(url)
        let id = try #require(store.add(name: "Lint", text: "exit 3"))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)

        store.start(run)
        #expect(await waitUntil { !store.state(run).isActive })

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
        let first = scratch.path("first")
        let second = scratch.path("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let store = emptyStore(url)
        let id = try #require(store.add(name: "Where", text: "pwd"))
        let one = ShortcutRun(id, in: first.path)
        let two = ShortcutRun(id, in: second.path)

        store.start(one)
        #expect(await waitUntil { !store.state(one).isActive })
        #expect(store.log(one).contains("first"))
        #expect(store.state(two) == .stopped)

        store.start(two)
        #expect(await waitUntil { !store.state(two).isActive })
        #expect(store.log(two).contains("second"))
        #expect(!store.log(two).contains("/first"))
    }

    // Moving a shortcut to another folder leaves its old runs pointing at a command that
    // is no longer there, so the state they carry stops meaning anything.
    @Test func forgetsRunsWhenAShortcutIsEdited() async throws {
        let store = emptyStore(url)
        let id = try #require(store.add(name: "Say", text: "echo hello"))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)
        let scope = ShortcutScope.session(UUID())

        store.start(run)
        store.showOutput(run, for: scope)
        #expect(await waitUntil { !store.state(run).isActive })
        #expect(!store.log(run).isEmpty)

        store.update(Shortcut(id: id, name: "Say", text: "echo goodbye"))

        #expect(store.state(run) == .stopped)
        #expect(store.log(run).isEmpty)
        // An edit can move the command to another folder, so the run the drawer is
        // pointed at is one nothing will write to again.
        #expect(store.output(for: scope) == nil)
    }

    // The pane a run was started from is thrown away and built again whenever the
    // sidebar moves, so the open drawer has to outlive it or a build started here is
    // out of sight the moment another session is read.
    @Test func keepsTheOpenOutputPerScreen() throws {
        let store = emptyStore(url)
        let id = try #require(store.add(name: "Build", text: "true"))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)
        let session = ShortcutScope.session(UUID())
        let project = ShortcutScope.project(UUID())

        store.showOutput(run, for: session)

        #expect(store.output(for: session) == run)
        // Another screen is not showing anything just because this one is.
        #expect(store.output(for: project) == nil)

        store.showOutput(nil, for: session)
        #expect(store.output(for: session) == nil)
    }

    // Removing a shortcut takes its output with it, wherever it is on screen, since the
    // drawer has no command left to name.
    @Test func closesTheOutputOfARemovedShortcut() throws {
        let store = emptyStore(url)
        let kept = try #require(store.add(name: "Test", text: "true"))
        let removed = try #require(store.add(name: "Build", text: "true"))
        let directory = FileManager.default.temporaryDirectory.path
        let first = ShortcutScope.session(UUID())
        let second = ShortcutScope.session(UUID())
        let third = ShortcutScope.project(UUID())

        store.showOutput(ShortcutRun(removed, in: directory), for: first)
        store.showOutput(ShortcutRun(removed, in: directory), for: second)
        store.showOutput(ShortcutRun(kept, in: directory), for: third)

        store.remove(removed)

        #expect(store.output(for: first) == nil)
        #expect(store.output(for: second) == nil)
        #expect(store.output(for: third) == ShortcutRun(kept, in: directory))
    }

    // A deleted project or session cannot be reached again, so nothing should stay
    // filed under it.
    @Test func discardsTheOutputOfADeletedScreen() throws {
        let store = emptyStore(url)
        let id = try #require(store.add(name: "Build", text: "true"))
        let sessionID = UUID()
        let scope = ShortcutScope.session(sessionID)
        store.showOutput(ShortcutRun(id, in: FileManager.default.temporaryDirectory.path),
                         for: scope)

        let owner = try #require(ShortcutScope(.session(sessionID)))
        store.discard(owner)

        #expect(store.output(for: scope) == nil)
        // A workspace screen has no chips, so there is no scope to discard for one.
        #expect(ShortcutScope(.workspace(UUID())) == nil)
    }

    // An icon is what the chip is read by, so it has to survive the round trip to disk.
    @Test func persistsTheIcon() throws {
        let store = emptyStore(url)

        let id = try #require(store.add(name: "Tests", text: "swift test", icon: "hammer"))

        #expect(emptyStore(url).shortcut(id)?.icon == "hammer")

        store.update(Shortcut(id: id, name: "Tests", text: "swift test",
                                     icon: "checkmark.seal"))
        #expect(emptyStore(url).shortcut(id)?.icon == "checkmark.seal")
    }

    // A file can name a symbol this build cannot draw, which would leave a gap on the
    // chip where an icon should be.
    @Test func dropsAnIconTheSystemCannotDraw() throws {
        let store = emptyStore(url)

        let id = try #require(store.add(name: "Tests", text: "swift test",
                                        icon: "not.a.real.symbol"))

        #expect(store.shortcut(id)?.icon == nil)
    }

    // Giving a shortcut an icon leaves the same command, so what the last run reported
    // still describes it and the drawer stays where it was.
    @Test func keepsRunsWhenOnlyTheIconChanges() async throws {
        let store = emptyStore(url)
        let id = try #require(store.add(name: "Say", text: "echo hello"))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)
        let scope = ShortcutScope.session(UUID())

        store.start(run)
        store.showOutput(run, for: scope)
        #expect(await waitUntil { !store.state(run).isActive })

        store.update(Shortcut(id: id, name: "Say", text: "echo hello",
                                     icon: "terminal"))

        #expect(store.log(run).contains("hello"))
        #expect(store.output(for: scope) == run)
    }

    // A shortcut saved before a shortcut could be anything but a command still is one,
    // and a prompt has to survive the round trip to disk with its kind intact.
    @Test func readsShortcutsSavedBeforePromptsExisted() throws {
        let id = UUID()
        try Data("""
        { "shortcuts": [ { "id": "\(id.uuidString)", "name": "Prune", "command": "docker system prune" } ] }
        """.utf8).write(to: url)

        let store = emptyStore(url)
        #expect(store.shortcut(id)?.kind == .command)

        let prompt = try #require(store.add(name: "Unfinished",
                                            text: "List what is left to do.",
                                            kind: .prompt))
        #expect(emptyStore(url).shortcut(prompt) == Shortcut(
            id: prompt, name: "Unfinished", text: "List what is left to do.", kind: .prompt))
    }

    // A prompt is sent by a session, which has a conversation to send it to. Nothing can
    // hand one to zsh, so asking for a run leaves it exactly where it was.
    @Test func neverRunsAPrompt() throws {
        let store = emptyStore(url)
        let id = try #require(store.add(name: "Recap", text: "Sum up this session.",
                                        kind: .prompt))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)

        store.start(run)

        #expect(store.state(run) == .stopped)
        #expect(store.log(run).isEmpty)
    }

    // The chip strip runs commands and the prompt rail sends prompts, so each asks for
    // the kind it can offer and neither ever sees the other's.
    @Test func splitsWhatAProjectOffersByKind() throws {
        let store = emptyStore(url)
        let project = UUID()
        _ = store.add(name: "Lint", text: "npm run lint", projectID: project)
        _ = store.add(name: "Review", text: "Review my working tree.", kind: .prompt,
                      projectID: project)
        _ = store.add(name: "Tidy", text: "Tidy what you just wrote.", kind: .prompt,
                      availableInAllProjects: true)

        #expect(store.shortcuts(for: project).map(\.name) == ["Lint", "Review", "Tidy"])
        #expect(store.shortcuts(for: project, kind: .command).map(\.name) == ["Lint"])
        #expect(store.shortcuts(for: project, kind: .prompt).map(\.name)
            == ["Review", "Tidy"])
        #expect(store.shortcuts(for: [project], kind: .prompt).map(\.shortcut.name)
            == ["Review", "Tidy"])
    }

    // A prompt is offered on a rail of glyphs with no room for a name, so one saved
    // without an icon still has something to draw.
    @Test func givesEveryPromptAGlyph() {
        #expect(Shortcut(name: "Recap", text: "Sum up.", kind: .prompt).glyph == "sparkles")
        #expect(Shortcut(name: "Recap", text: "Sum up.", kind: .prompt, icon: "book")
            .glyph == "book")
        #expect(Shortcut(name: "Lint", text: "npm run lint").glyph == nil)
    }

    // Rewriting what a shortcut does makes the last run stop describing it, and changing
    // a command into a prompt is the largest rewrite there is.
    @Test func forgetsRunsWhenTheKindChanges() async throws {
        let store = emptyStore(url)
        let id = try #require(store.add(name: "Say", text: "echo hello"))
        let run = ShortcutRun(id, in: FileManager.default.temporaryDirectory.path)

        store.start(run)
        #expect(await waitUntil { !store.state(run).isActive })

        store.update(Shortcut(id: id, name: "Say", text: "echo hello", kind: .prompt))

        #expect(store.log(run).isEmpty)
        #expect(store.state(run) == .stopped)
    }

    private func emptyStore(_ url: URL) -> ShortcutStore {
        ShortcutStore(storageURL: url, siteDefaults: SiteDefaults())
    }

}
