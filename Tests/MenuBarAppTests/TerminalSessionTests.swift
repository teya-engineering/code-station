import Foundation
import Testing
@testable import MenuBarApp

// TerminalSession is the layer the tab strip reads: it owns the pty and turns its
// state into the properties the view draws.
@MainActor
struct TerminalSessionTests {

    // Every shell here is noted in a scratch registry, never in the folder the real app
    // reaps from.
    private func registry() -> ShellRegistry {
        ShellRegistry(directory: ShellNotes.scratch())
    }

    private func makeSession() -> TerminalSession {
        TerminalSession(directory: FileManager.default.temporaryDirectory.path, name: "Terminal",
                        registry: registry())
    }

    private func makeStore() -> TerminalStore {
        TerminalStore(registry: registry())
    }

    @Test func startsAShellAndShowsItsOutput() async {
        let session = makeSession()
        session.start()
        defer { session.stop() }

        #expect(session.isRunning)
        session.send("echo hello-from-session\r")
        #expect(await waitUntil {
            session.screenText().contains("hello-from-session")
        })
    }

    // This is what puts the green dot on a tab. It failed the first time round: the
    // property was never published because the poll returned early.
    @Test func reportsWhenACommandIsRunning() async {
        let session = makeSession()
        session.start()
        defer { session.stop() }

        session.send("echo ready\r")
        #expect(await waitUntil {
            session.screenText().contains("ready")
        })
        #expect(await waitUntil(timeout: .seconds(3)) { session.isBusy == false })

        session.send("sleep 3\r")
        #expect(await waitUntil(timeout: .seconds(5)) { session.isBusy }, "a running command lights the tab")
        #expect(await waitUntil { !session.isBusy }, "the tab goes quiet again")
    }

    @Test func stopsCheckingForCommandsWhileItsDrawerIsHidden() async {
        let session = makeSession()
        session.start()
        defer { session.stop() }

        session.send("echo ready\r")
        #expect(await waitUntil {
            session.screenText().contains("ready")
        })

        session.setBusyMonitoring(false)
        session.send("sleep 3\r")
        try? await Task.sleep(for: .milliseconds(1_200))
        #expect(!session.isBusy, "a hidden drawer does not poll its shell")

        session.setBusyMonitoring(true)
        #expect(await waitUntil(timeout: .seconds(2)) { session.isBusy },
                "showing the drawer refreshes the command state")
        #expect(await waitUntil { !session.isBusy })
    }

    @Test func clearingEmptiesTheScreen() async {
        let session = makeSession()
        session.start()
        defer { session.stop() }

        session.send("echo something\r")
        #expect(await waitUntil {
            session.screenText().contains("something")
        })
        session.clear()
        #expect(session.screenText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func exitingTheOnlyShellClosesTheDrawer() async throws {
        let store = makeStore()
        let scope = TerminalScope.session(UUID())
        store.setOpen(true, for: scope, directory: FileManager.default.temporaryDirectory.path)

        let session = try #require(store.selection(for: scope))
        session.send("exit\r")

        #expect(await waitUntil { store.sessions(for: scope).isEmpty })
        #expect(!store.isOpen(scope))
    }

    @Test func exitingOneShellKeepsTheOtherShellOpen() async throws {
        let store = makeStore()
        let scope = TerminalScope.session(UUID())
        let directory = FileManager.default.temporaryDirectory.path
        store.setOpen(true, for: scope, directory: directory)

        let first = try #require(store.selection(for: scope))
        let second = store.add(to: scope, directory: directory)
        first.send("exit\r")

        #expect(await waitUntil {
            store.sessions(for: scope).map(\.id) == [second.id]
        })
        #expect(store.isOpen(scope))
        #expect(store.selection(for: scope)?.id == second.id)

        store.close(second, in: scope)
    }

    // Deleting a project or a session takes away the only screen its terminals could be
    // closed from, so the store has to close them itself or they run until the app quits.
    @Test func discardingAScopeClosesEveryShellUnderIt() throws {
        let store = makeStore()
        let scope = TerminalScope.project(UUID())
        let directory = FileManager.default.temporaryDirectory.path
        store.setOpen(true, for: scope, directory: directory)
        let first = try #require(store.selection(for: scope))
        let second = store.add(to: scope, directory: directory)
        #expect(first.isRunning && second.isRunning)

        store.discard(scope)

        #expect(!first.isRunning)
        #expect(!second.isRunning)
        #expect(store.sessions(for: scope).isEmpty)
        #expect(!store.isOpen(scope))
    }

    @Test func discardingOneScopeLeavesAnotherAlone() throws {
        let store = makeStore()
        let directory = FileManager.default.temporaryDirectory.path
        let kept = TerminalScope.session(UUID())
        store.setOpen(true, for: kept, directory: directory)
        let survivor = try #require(store.selection(for: kept))

        store.discard(.project(UUID()))

        #expect(survivor.isRunning)
        #expect(store.sessions(for: kept).count == 1)
        store.close(survivor, in: kept)
    }

    // The two stores as the app wires them together at launch. Deleting either end of a
    // scope has to reach the shells, and the store holding the projects knows nothing
    // about terminals, so the connection is worth having a test of its own.
    private func wiredStores() -> (ProjectStore, TerminalStore, ScratchDirectory) {
        let (projects, scratch) = TestStore.make()
        let terminals = makeStore()
        projects.onRemoved = { terminals.discard(TerminalScope($0)) }
        return (projects, terminals, scratch)
    }

    @Test func deletingASessionClosesItsShells() throws {
        let (projects, terminals, _) = wiredStores()
        let session = projects.newSession(in: try TestStore.project(in: projects).id)
        terminals.setOpen(true, for: .session(session.id),
                          directory: FileManager.default.temporaryDirectory.path)
        let shell = try #require(terminals.selection(for: .session(session.id)))

        projects.removeSession(session.id)

        #expect(!shell.isRunning)
        #expect(terminals.sessions(for: .session(session.id)).isEmpty)
    }

    @Test func deletingAProjectClosesItsShells() throws {
        let (projects, terminals, _) = wiredStores()
        let project = try TestStore.project(in: projects)
        terminals.setOpen(true, for: .project(project.id),
                          directory: FileManager.default.temporaryDirectory.path)
        let shell = try #require(terminals.selection(for: .project(project.id)))

        projects.removeProject(project.id)

        #expect(!shell.isRunning)
        #expect(terminals.sessions(for: .project(project.id)).isEmpty)
    }

    // A prepared removal takes the session out of the app for good, so its shells go at
    // that point rather than waiting for the cleanup that follows.
    @Test func preparingASessionRemovalClosesItsShells() throws {
        let (projects, terminals, _) = wiredStores()
        let session = projects.newSession(in: try TestStore.project(in: projects).id)
        terminals.setOpen(true, for: .session(session.id),
                          directory: FileManager.default.temporaryDirectory.path)
        let shell = try #require(terminals.selection(for: .session(session.id)))

        _ = projects.prepareSessionRemoval(session.id)

        #expect(!shell.isRunning)
        #expect(terminals.sessions(for: .session(session.id)).isEmpty)
    }
}
