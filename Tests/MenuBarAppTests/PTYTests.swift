import Foundation
import Testing
@testable import MenuBarApp

// The pty is the part that cannot be checked by reading the code: either a real shell
// starts on a real tty and answers what is typed at it, or it does not.
struct PTYTests {

    // Output arrives on a background queue, so it is collected behind a lock and waited
    // for rather than read straight after writing.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private(set) var exitCode: Int32?

        func append(_ data: Data) {
            lock.lock(); storage.append(data); lock.unlock()
        }

        func recordExit(_ code: Int32) {
            lock.lock(); exitCode = code; lock.unlock()
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: storage, as: UTF8.self)
        }

        // Polls instead of sleeping a fixed time, so a slow machine does not fail and a
        // fast one does not wait.
        func waitFor(_ needle: String, seconds: Double = 10) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if text.contains(needle) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
    }

    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        // A bare shell keeps the test independent of whatever is in the user's rc files.
        environment["ZDOTDIR"] = "/nonexistent"
        return environment
    }

    private func makePTY(_ collector: Collector) -> PTY {
        PTY(onOutput: { collector.append($0) }, onExit: { collector.recordExit($0) })
    }

    private func startShell(_ pty: PTY, columns: Int = 80, rows: Int = 24) throws {
        try pty.start(shell: "/bin/sh", arguments: ["-i"],
                      directory: FileManager.default.temporaryDirectory.path,
                      environment: environment(), columns: columns, rows: rows)
    }

    @Test func runsACommandAndReturnsItsOutput() async throws {
        let collector = Collector()
        let pty = makePTY(collector)
        defer { pty.stop() }

        try startShell(pty)

        pty.write(Data("echo conductor-was-here\r".utf8))
        #expect(await collector.waitFor("conductor-was-here"))
    }

    // The shell has to be on a real tty, not a pipe: that is what keeps colour on and
    // makes interactive programs behave.
    @Test func theChildIsOnARealTerminal() async throws {
        let collector = Collector()
        let pty = makePTY(collector)
        defer { pty.stop() }

        try startShell(pty)

        pty.write(Data("test -t 1 && echo is-a-tty\r".utf8))
        #expect(await collector.waitFor("is-a-tty"))
    }

    @Test func startsInTheDirectoryItWasGiven() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let collector = Collector()
        let pty = makePTY(collector)
        defer { pty.stop() }

        try pty.start(shell: "/bin/sh", arguments: ["-i"], directory: directory.path,
                      environment: environment(), columns: 80, rows: 24)

        pty.write(Data("pwd\r".utf8))
        #expect(await collector.waitFor(directory.lastPathComponent))
    }

    // A tty file descriptor alone is not enough. The shell needs a controlling
    // terminal so its foreground command receives terminal-generated signals.
    @Test func interruptsTheForegroundCommand() async throws {
        let collector = Collector()
        let pty = makePTY(collector)
        defer { pty.stop() }

        try startShell(pty)

        pty.write(Data("printf 'terminal-%s\\n' ready\r".utf8))
        #expect(await collector.waitFor("terminal-ready"))
        pty.captureIdleBaseline()

        pty.write(Data("printf 'command-%s\\n' started; sleep 30\r".utf8))
        #expect(await collector.waitFor("command-started"))
        #expect(await waitUntil(seconds: 3) { pty.isBusy })

        pty.write(Data([0x03]))
        pty.write(Data("printf 'command-%s\\n' interrupted\r".utf8))

        #expect(await collector.waitFor("command-interrupted", seconds: 3))
    }

    // The shell is told the window size, so anything that draws a full line wraps in
    // the right place.
    @Test func reportsTheWindowSizeItWasGiven() async throws {
        let collector = Collector()
        let pty = makePTY(collector)
        defer { pty.stop() }

        try startShell(pty, columns: 123, rows: 45)

        pty.write(Data("stty size\r".utf8))
        #expect(await collector.waitFor("45 123"))
    }

    @Test func noticesTheShellExiting() async throws {
        let collector = Collector()
        let pty = makePTY(collector)
        defer { pty.stop() }

        try startShell(pty)

        pty.write(Data("exit 3\r".utf8))
        let deadline = Date().addingTimeInterval(10)
        while collector.exitCode == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(collector.exitCode == 3)
        #expect(pty.isRunning == false)
    }

    // The dot on a terminal tab comes from this: the tty's foreground process group is
    // the shell itself when it is waiting at a prompt, and the command's group while
    // one is running. Nothing here guesses from output.
    @Test func knowsWhenACommandIsRunning() async throws {
        let collector = Collector()
        let pty = makePTY(collector)
        defer { pty.stop() }

        try startShell(pty)

        // Wait for the first prompt so the shell has settled before anything is judged.
        pty.write(Data("echo ready\r".utf8))
        #expect(await collector.waitFor("ready"))
        try? await Task.sleep(for: .milliseconds(200))
        pty.captureIdleBaseline()
        #expect(pty.isBusy == false, "a shell sitting at its prompt is not busy")

        pty.write(Data("sleep 3\r".utf8))
        #expect(await waitUntil(seconds: 5) { pty.isBusy }, "a running command makes it busy")

        #expect(await waitUntil(seconds: 10) { !pty.isBusy }, "it stops being busy when the command ends")
    }

    private func waitUntil(seconds: Double, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func failsClearlyWhenTheShellIsNotThere() {
        let pty = PTY(onOutput: { _ in }, onExit: { _ in })
        #expect(throws: PTY.Failure.self) {
            try pty.start(shell: "/definitely/not/a/shell", arguments: [],
                          directory: FileManager.default.temporaryDirectory.path,
                          environment: [:], columns: 80, rows: 24)
        }
    }
}

// The app launches the user's login shell, not /bin/sh, and shells differ enough about
// process groups and background helpers that the busy signal has to be proven against
// a real zsh as well.
extension PTYTests {
    @Test func busySignalWorksUnderZsh() async throws {
        let collector = Collector()
        let pty = makePTY(collector)
        defer { pty.stop() }

        try pty.start(shell: "/bin/zsh", arguments: ["-i"],
                      directory: FileManager.default.temporaryDirectory.path,
                      environment: ProcessInfo.processInfo.environment,
                      columns: 80, rows: 24)

        pty.write(Data("echo ready\r".utf8))
        #expect(await collector.waitFor("ready"))
        pty.captureIdleBaseline()
        #expect(pty.isBusy == false, "a zsh sitting at its prompt is not busy")

        pty.write(Data("sleep 3\r".utf8))
        #expect(await waitUntil(seconds: 5) { pty.isBusy }, "a running command lights the tab")
        #expect(await waitUntil(seconds: 10) { !pty.isBusy }, "and it goes quiet again")
    }
}
