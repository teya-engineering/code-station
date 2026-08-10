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
}
