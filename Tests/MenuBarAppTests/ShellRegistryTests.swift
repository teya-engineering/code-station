import Darwin
import Foundation
import Testing
@testable import MenuBarApp

// The registry exists for the one case nobody can stage by hand: the app dying without
// closing its shells. Both halves of it can still be checked - a note is kept while a
// shell runs and dropped when it ends, and a note left by an owner that is gone takes the
// shell with it.
struct ShellRegistryTests {

    private func scratch() -> URL { ShellNotes.scratch() }
    private func markers(in directory: URL) -> [URL] { ShellNotes.markers(in: directory) }

    // A process of our own to strand, so nothing here can reach one it did not start. It
    // is left in the background of a shell that exits, which is what an orphaned terminal
    // is: owned by launchd, and cleared away by the kernel the moment it ends rather than
    // left as a zombie for a parent that will never wait on it. Job control puts it in a
    // process group of its own, as a pty shell is, since that group is what gets signalled.
    private func startOrphan() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The background process gets its own output, or it would hold the pipe open and
        // the read below would wait for it to end - which is the one thing it will not do.
        process.arguments = ["-c", "set -m; sleep 120 >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        return try #require(pid_t(printed.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func waitUntilGone(_ pid: pid_t) async -> Bool {
        await waitUntil(timeout: .seconds(5)) { ProcessIdentity.of(pid) == nil }
    }

    private func identity(of pid: pid_t) throws -> ProcessIdentity {
        try #require(ProcessIdentity.of(pid))
    }

    @Test func aPidOnItsOwnDoesNotIdentifyAProcess() throws {
        let pid = try startOrphan()
        defer { kill(pid, SIGKILL) }

        let identity = try #require(ProcessIdentity.of(pid))
        #expect(identity.isAlive)

        // The same number with a start time that was never this process's is not it, and
        // that is the check keeping a reused pid from being killed on an old note's word.
        #expect(!ProcessIdentity(pid: pid, startedAt: identity.startedAt - 1).isAlive)
    }

    @Test func aRunningShellIsWrittenDownAndAClosedOneIsNot() throws {
        let directory = scratch()
        let registry = ShellRegistry(directory: directory)
        let pid = try startOrphan()
        defer { kill(pid, SIGKILL) }
        let shell = try identity(of: pid)

        registry.record(shell)
        #expect(markers(in: directory).count == 1)

        registry.forget(shell)
        #expect(markers(in: directory).isEmpty)
    }

    // Retiring is what closing a tab does: the shell is hung up at once and the note is
    // dropped in the background once the shell has really gone.
    @Test func aRetiredShellIsClosedAndThenForgotten() async throws {
        let directory = scratch()
        let registry = ShellRegistry(directory: directory)
        let pid = try startOrphan()
        defer { kill(pid, SIGKILL) }
        let shell = try identity(of: pid)
        registry.record(shell)

        registry.retire(shell)

        #expect(await waitUntilGone(pid))
        #expect(await waitUntil { markers(in: directory).isEmpty })
    }

    @Test func aShellWhoseOwnerIsGoneIsClosed() async throws {
        let directory = scratch()
        let pid = try startOrphan()
        defer { kill(pid, SIGKILL) }

        // An owner that has already ended. This test process is alive, so a note in its
        // own name would - rightly - be left where it is.
        let ended = ProcessIdentity(pid: getpid(), startedAt: 1)
        ShellRegistry(directory: directory, owner: ended).record(try identity(of: pid))

        #expect(await ShellRegistry(directory: directory).reapOrphans() == [pid])
        #expect(await waitUntilGone(pid), "the shell is closed, not merely noted")
        #expect(markers(in: directory).isEmpty, "and the note goes with it")
    }

    @Test func aShellWhoseOwnerIsStillRunningIsLeftAlone() async throws {
        let directory = scratch()
        let registry = ShellRegistry(directory: directory)
        let pid = try startOrphan()
        defer { kill(pid, SIGKILL) }
        registry.record(try identity(of: pid))

        // The owner here is this process, which stands in for a second copy of the app
        // coming across the first copy's terminals.
        #expect(await registry.reapOrphans().isEmpty)
        #expect(ProcessIdentity.of(pid) != nil, "somebody is still using it")
        #expect(markers(in: directory).count == 1)
    }

    @Test func aNoteForAShellThatHasAlreadyEndedIsCleared() async throws {
        let directory = scratch()
        let pid = try startOrphan()
        let ended = ProcessIdentity(pid: getpid(), startedAt: 1)
        ShellRegistry(directory: directory, owner: ended).record(try identity(of: pid))

        kill(pid, SIGKILL)
        #expect(await waitUntilGone(pid))

        #expect(await ShellRegistry(directory: directory).reapOrphans().isEmpty)
        #expect(markers(in: directory).isEmpty)
    }

    @Test func unreadableNotesAreThrownAway() async throws {
        let directory = scratch()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("half a write".utf8).write(to: directory.appendingPathComponent("123.json"))

        #expect(await ShellRegistry(directory: directory).reapOrphans().isEmpty)
        #expect(markers(in: directory).isEmpty)
    }
}
