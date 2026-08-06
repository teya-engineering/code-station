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
            session.lines.contains { $0.text.contains("hello-from-session") }
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
            session.lines.contains { $0.text.contains("ready") }
        })
        #expect(await waitUntil(seconds: 3) { session.isBusy == false })

        session.send("sleep 3\r")
        #expect(await waitUntil(seconds: 5) { session.isBusy }, "a running command lights the tab")
        #expect(await waitUntil(seconds: 10) { !session.isBusy }, "the tab goes quiet again")
    }

    @Test func clearingEmptiesTheScreen() async {
        let session = makeSession()
        session.start()
        defer { session.stop() }

        session.send("echo something\r")
        #expect(await waitUntil(seconds: 10) {
            session.lines.contains { $0.text.contains("something") }
        })
        session.clear()
        #expect(session.lines.allSatisfy { $0.text.isEmpty })
    }
}
