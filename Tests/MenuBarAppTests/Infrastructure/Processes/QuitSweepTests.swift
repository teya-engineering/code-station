import Darwin
import Foundation
import Testing
@testable import MenuBarApp

// The real sweep runs below the app. Here it runs below a shell the test starts, which
// stands in for the app: it is never signalled itself, and nothing outside it is reached.
struct QuitSweepTests {

    // A shell that starts two sleeps and waits on them: one in the shell's group, which
    // stands in for the app's, the other in a group of its own. The shell then carries on,
    // as the app would. A trap of '' is inherited through exec, so `stubborn` gives both
    // sleeps the shell's habit of ignoring a hangup and a terminate.
    private func startStandIn(stubborn: Bool) async throws -> (root: ProcessIdentity, children: [pid_t]) {
        let trap = stubborn ? "trap '' HUP TERM; " : ""
        guard let null = FileHandle(forUpdatingAtPath: "/dev/null") else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { try? null.close() }
        let pid = try CommandRunner.spawnIsolatedProcess(
            executable: "/bin/sh",
            arguments: ["-c", "\(trap)sleep 60 & set -m; sleep 60 & wait; exec sleep 60"],
            currentDirectory: nil,
            environment: ProcessInfo.processInfo.environment,
            standardInput: null.fileDescriptor,
            standardOutput: null.fileDescriptor,
            standardError: null.fileDescriptor,
            descriptorsToClose: [])
        let root = try #require(ProcessIdentity.of(pid))
        var children: [pid_t] = []
        let started = await waitUntil(timeout: .seconds(5)) {
            children = (SessionMemoryGuard.processes() ?? [])
                .filter { $0.parentPID == pid }.map(\.identity.pid)
            return children.count == 2
        }
        try #require(started)
        return (root, children)
    }

    private func end(_ root: ProcessIdentity, _ children: [pid_t]) {
        for child in children { kill(child, SIGKILL) }
        kill(-root.pid, SIGKILL)
        _ = CommandRunner.waitForExit(of: root.pid)
    }

    @Test func processesThatStopWhenAskedAreNotKilled() async throws {
        let (root, children) = try await startStandIn(stubborn: false)
        defer { end(root, children) }

        let swept = QuitSweep.snapshot(below: root, registries: []).finish()

        #expect(swept.killed == 0)
        #expect(swept.left == 0)
        #expect(await waitUntil(timeout: .seconds(5)) { children.allSatisfy { ProcessIdentity.of($0) == nil } })
        #expect(root.isAlive)
    }

    @Test func processesThatIgnoreTheStopAreKilledAfterTheGracePeriod() async throws {
        let (root, children) = try await startStandIn(stubborn: true)
        defer { end(root, children) }

        let swept = QuitSweep.snapshot(below: root, registries: []).finish(grace: .milliseconds(300))

        #expect(swept.killed == 2)
        #expect(swept.left == 0)
        #expect(root.isAlive)
    }

    @Test func aSparedHelperOutlivesTheSweep() async throws {
        let (root, children) = try await startStandIn(stubborn: false)
        defer { end(root, children) }
        let helper = try #require(children.first)
        QuitSweep.spare(helper)

        QuitSweep.snapshot(below: root, registries: []).finish(grace: .milliseconds(300))

        #expect(ProcessIdentity.of(helper) != nil)
        #expect(await waitUntil(timeout: .seconds(5)) { ProcessIdentity.of(children[1]) == nil })
    }

    // A command that lost its parent belongs to launchd, so only the note the app wrote
    // for it still ties it to the app.
    @Test func aWrittenDownCommandIsSweptEvenOnceItHasLostItsParent() async throws {
        let (root, children) = try await startStandIn(stubborn: false)
        defer { end(root, children) }
        let orphan = try startOrphan()
        defer { kill(orphan.pid, SIGKILL) }
        let registry = ShellRegistry(directory: ShellNotes.scratch(), owner: root)
        registry.record(orphan)

        let swept = QuitSweep.snapshot(below: root, registries: [registry])
            .finish(grace: .milliseconds(300))

        #expect(swept.killed == 1)
        #expect(await waitUntil(timeout: .seconds(5)) { !orphan.isAlive })
    }

    // Nothing the app wrote down names it, but macOS still holds the app responsible for
    // it, and keeps the app in the Dock for as long as it runs.
    @Test func aProcessTheAppIsResponsibleForIsSweptOnceItHasLostItsParent() async throws {
        let (root, children) = try await startStandIn(stubborn: false)
        defer { end(root, children) }
        let orphan = try startOrphan()
        defer { kill(orphan.pid, SIGKILL) }

        let swept = QuitSweep.snapshot(below: root, registries: [],
                                       responsible: { $0 == orphan.pid ? root.pid : nil })
            .finish(grace: .milliseconds(300))

        #expect(swept.killed == 1)
        #expect(await waitUntil(timeout: .seconds(5)) { !orphan.isAlive })
        #expect(root.isAlive)
    }

    // A sleep in a group of its own that ignores a hangup and a terminate, whose parent has
    // already exited.
    private func startOrphan() throws -> ProcessIdentity {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' HUP TERM; set -m; sleep 120 >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let orphanPID = try #require(pid_t(printed.trimmingCharacters(in: .whitespacesAndNewlines)))
        return try #require(ProcessIdentity.of(orphanPID))
    }
}
