import Darwin
import Foundation
import Testing
@testable import CodeStationCore

// The real registry goes by the coalition macOS filed each run under. Here a made-up
// coalition holds one sleep the test starts, so nothing outside the test is reached.
struct RunRegistryTests {
    private static let coalition: UInt64 = 7
    // Never the identity of anything running: process 1 started long before this.
    private static let endedApp = ProcessIdentity(pid: 1, startedAt: 1)

    private func registry(in directory: URL, owner: ProcessIdentity?, boot: String = "this-boot",
                          holding members: [pid_t]) -> RunRegistry {
        RunRegistry(directory: directory, owner: owner, boot: boot,
                    coalition: { members.contains($0) ? Self.coalition : nil })
    }

    // A sleep in a group of its own that ignores a hangup and a terminate, whose parent has
    // already exited.
    private func startLeftover() throws -> ProcessIdentity {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' HUP TERM; set -m; sleep 120 >/dev/null 2>&1 & echo $!"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try #require(pid_t(printed.trimmingCharacters(in: .whitespacesAndNewlines)))
        return try #require(ProcessIdentity.of(pid))
    }

    @Test func whatAnEndedRunLeftBehindIsStoppedAndItsNoteDropped() async throws {
        let leftover = try startLeftover()
        defer { kill(leftover.pid, SIGKILL) }
        let directory = ShellNotes.scratch()
        registry(in: directory, owner: Self.endedApp, holding: []).record(Self.coalition)

        let ended = registry(in: directory, owner: .current, holding: [leftover.pid])
            .reapEarlierRuns(grace: .milliseconds(300))

        #expect(ended == 1)
        #expect(await waitUntil(timeout: .seconds(5)) { !leftover.isAlive })
        #expect(ShellNotes.markers(in: directory).isEmpty)
    }

    @Test func aRunThatIsStillGoingKeepsItsProcesses() throws {
        let leftover = try startLeftover()
        defer { kill(leftover.pid, SIGKILL) }
        let directory = ShellNotes.scratch()
        registry(in: directory, owner: .current, holding: []).record(Self.coalition)

        let ended = registry(in: directory, owner: Self.endedApp, holding: [leftover.pid])
            .reapEarlierRuns(grace: .milliseconds(300))

        #expect(ended == 0)
        #expect(leftover.isAlive)
        #expect(ShellNotes.markers(in: directory).count == 1)
    }

    // The number in the note belongs to some other coalition once the machine has
    // restarted, so the note is dropped and nothing is stopped on its word.
    @Test func aNoteFromBeforeARestartStopsNothing() throws {
        let leftover = try startLeftover()
        defer { kill(leftover.pid, SIGKILL) }
        let directory = ShellNotes.scratch()
        registry(in: directory, owner: Self.endedApp, boot: "earlier-boot", holding: [])
            .record(Self.coalition)

        let ended = registry(in: directory, owner: .current, holding: [leftover.pid])
            .reapEarlierRuns(grace: .milliseconds(300))

        #expect(ended == 0)
        #expect(leftover.isAlive)
        #expect(ShellNotes.markers(in: directory).isEmpty)
    }

    @Test func theCoalitionTheAppIsInItselfIsNeverSwept() throws {
        let leftover = try startLeftover()
        defer { kill(leftover.pid, SIGKILL) }
        let directory = ShellNotes.scratch()
        registry(in: directory, owner: Self.endedApp, holding: []).record(Self.coalition)

        let ended = registry(in: directory, owner: .current, holding: [leftover.pid, getpid()])
            .reapEarlierRuns(grace: .milliseconds(300))

        #expect(ended == 0)
        #expect(leftover.isAlive)
    }

    @Test func aRunWithNoCoalitionOfItsOwnWritesNothingDown() {
        let directory = ShellNotes.scratch()

        registry(in: directory, owner: .current, holding: []).record(nil)

        #expect(ShellNotes.markers(in: directory).isEmpty)
    }

    // The test runner was started from a shell or an editor, so the coalition it is in
    // belongs to that app and is not its own to write down.
    @Test func aCopyStartedBySomethingElseOwnsNoCoalition() {
        #expect(RunRegistry.coalition(of: getpid()) != nil)
        #expect(RunRegistry.launchCoalition() == nil)
    }
}
