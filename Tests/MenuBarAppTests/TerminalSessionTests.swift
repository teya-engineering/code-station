import Foundation
import Testing
@testable import MenuBarApp

// TerminalSession is the layer the tab strip reads: it owns the pty and turns its
// state into the properties the view draws.
@MainActor
struct TerminalSessionTests {

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func makeSession() -> TerminalSession {
        TerminalSession(directory: FileManager.default.temporaryDirectory.path, name: "Terminal")
    }

    @Test func startsAShellAndShowsItsOutput() async {
        let session = makeSession()
        session.start()
        defer { session.stop() }

        #expect(session.isRunning)
        session.send("echo hello-from-session\r")
        #expect(await waitUntil(seconds: 10) {
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
        #expect(await waitUntil(seconds: 10) {
            session.screenText().contains("ready")
        })
        #expect(await waitUntil(seconds: 3) { session.isBusy == false })

        session.send("sleep 3\r")
        #expect(await waitUntil(seconds: 5) { session.isBusy }, "a running command lights the tab")
        #expect(await waitUntil(seconds: 10) { !session.isBusy }, "the tab goes quiet again")
    }

    @Test func stopsCheckingForCommandsWhileItsDrawerIsHidden() async {
        let session = makeSession()
        session.start()
        defer { session.stop() }

        session.send("echo ready\r")
        #expect(await waitUntil(seconds: 10) {
            session.screenText().contains("ready")
        })

        session.setBusyMonitoring(false)
        session.send("sleep 3\r")
        try? await Task.sleep(for: .milliseconds(1_200))
        #expect(!session.isBusy, "a hidden drawer does not poll its shell")

        session.setBusyMonitoring(true)
        #expect(await waitUntil(seconds: 2) { session.isBusy },
                "showing the drawer refreshes the command state")
        #expect(await waitUntil(seconds: 10) { !session.isBusy })
    }

    @Test func clearingEmptiesTheScreen() async {
        let session = makeSession()
        session.start()
        defer { session.stop() }

        session.send("echo something\r")
        #expect(await waitUntil(seconds: 10) {
            session.screenText().contains("something")
        })
        session.clear()
        #expect(session.screenText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func exitingTheOnlyShellClosesTheDrawer() async throws {
        let store = TerminalStore()
        let scope = TerminalScope.session(UUID())
        store.setOpen(true, for: scope, directory: FileManager.default.temporaryDirectory.path)

        let session = try #require(store.selection(for: scope))
        session.send("exit\r")

        #expect(await waitUntil(seconds: 10) { store.sessions(for: scope).isEmpty })
        #expect(!store.isOpen(scope))
    }

    @Test func exitingOneShellKeepsTheOtherShellOpen() async throws {
        let store = TerminalStore()
        let scope = TerminalScope.session(UUID())
        let directory = FileManager.default.temporaryDirectory.path
        store.setOpen(true, for: scope, directory: directory)

        let first = try #require(store.selection(for: scope))
        let second = store.add(to: scope, directory: directory)
        first.send("exit\r")

        #expect(await waitUntil(seconds: 10) {
            store.sessions(for: scope).map(\.id) == [second.id]
        })
        #expect(store.isOpen(scope))
        #expect(store.selection(for: scope)?.id == second.id)

        store.close(second, in: scope)
    }

    // Deleting a project or a session takes away the only screen its terminals could be
    // closed from, so the store has to close them itself or they run until the app quits.
    @Test func discardingAnIdClosesEveryShellUnderIt() throws {
        let store = TerminalStore()
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.path
        store.setOpen(true, for: .project(id), directory: directory)
        let first = try #require(store.selection(for: .project(id)))
        let second = store.add(to: .project(id), directory: directory)
        #expect(first.isRunning && second.isRunning)

        store.discard(id)

        #expect(!first.isRunning)
        #expect(!second.isRunning)
        #expect(store.sessions(for: .project(id)).isEmpty)
        #expect(!store.isOpen(.project(id)))
    }

    // A project and a session never share an id, so an unrelated screen keeps its shell.
    @Test func discardingAnIdLeavesOtherScreensAlone() throws {
        let store = TerminalStore()
        let directory = FileManager.default.temporaryDirectory.path
        let kept = TerminalScope.session(UUID())
        store.setOpen(true, for: kept, directory: directory)
        let survivor = try #require(store.selection(for: kept))

        store.discard(UUID())

        #expect(survivor.isRunning)
        #expect(store.sessions(for: kept).count == 1)
        store.close(survivor, in: kept)
    }

    // The two stores as the app wires them together at launch. Deleting either end of a
    // scope has to reach the shells, and the store holding the projects knows nothing
    // about terminals, so the connection is worth having a test of its own.
    private func wiredStores() -> (ProjectStore, TerminalStore) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-tests-\(UUID().uuidString).json").path
        setenv("CODE_STATION_STORE", path, 1)
        let projects = ProjectStore()
        let terminals = TerminalStore()
        projects.onRemoved = { terminals.discard($0) }
        return (projects, terminals)
    }

    private func newProject(in store: ProjectStore) throws -> Project {
        try #require(store.addProject(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)")))
    }

    @Test func deletingASessionClosesItsShells() throws {
        let (projects, terminals) = wiredStores()
        let session = projects.newSession(in: try newProject(in: projects).id)
        terminals.setOpen(true, for: .session(session.id),
                          directory: FileManager.default.temporaryDirectory.path)
        let shell = try #require(terminals.selection(for: .session(session.id)))

        projects.removeSession(session.id)

        #expect(!shell.isRunning)
        #expect(terminals.sessions(for: .session(session.id)).isEmpty)
    }

    @Test func deletingAProjectClosesItsShells() throws {
        let (projects, terminals) = wiredStores()
        let project = try newProject(in: projects)
        terminals.setOpen(true, for: .project(project.id),
                          directory: FileManager.default.temporaryDirectory.path)
        let shell = try #require(terminals.selection(for: .project(project.id)))

        projects.removeProject(project.id)

        #expect(!shell.isRunning)
        #expect(terminals.sessions(for: .project(project.id)).isEmpty)
    }

    // A removal that has only been prepared can still be called off, and a shell closed
    // by mistake cannot be put back.
    @Test func aSessionRemovalThatIsCalledOffKeepsItsShells() throws {
        let (projects, terminals) = wiredStores()
        let session = projects.newSession(in: try newProject(in: projects).id)
        terminals.setOpen(true, for: .session(session.id),
                          directory: FileManager.default.temporaryDirectory.path)
        let shell = try #require(terminals.selection(for: .session(session.id)))

        _ = projects.prepareSessionRemoval(session.id)
        _ = projects.cancelSessionRemoval(session.id)

        #expect(shell.isRunning)
        terminals.discard(session.id)
    }
}
