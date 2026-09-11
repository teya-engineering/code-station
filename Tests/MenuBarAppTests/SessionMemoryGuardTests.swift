import Darwin
import Foundation
import Testing
@testable import MenuBarApp

struct SessionMemoryGuardTests {
    private func process(_ pid: pid_t, parent: pid_t, group: pid_t,
                         startedAt: Int64 = 1) -> SessionMemoryGuard.ProcessEntry {
        .init(identity: ProcessIdentity(pid: pid, startedAt: startedAt),
              parentPID: parent, group: group)
    }

    @Test func followsDescendantsAcrossGroupsAndKeepsKnownOrphans() {
        let root = process(100, parent: 1, group: 100)
        let child = process(101, parent: 100, group: 101)
        let grandchild = process(102, parent: 101, group: 102)
        let unrelated = process(900, parent: 1, group: 900)
        var tree = SessionMemoryGuard.ProcessTree(root: root.identity)
        #expect(Set(tree.members(in: [grandchild, unrelated, child, root])
            .map(\.identity.pid)) == [100, 101, 102])

        let orphan = process(102, parent: 1, group: 102)
        #expect(tree.members(in: [unrelated, orphan]).map(\.identity.pid) == [102])
        #expect(tree.members(in: [unrelated]).isEmpty)
    }

    @Test func findsReparentedGroupMembersButRejectsReusedProcessIDs() {
        let root = process(100, parent: 1, group: 100)
        let orphan = process(101, parent: 1, group: 100)
        var tree = SessionMemoryGuard.ProcessTree(root: root.identity)
        #expect(Set(tree.members(in: [root, orphan]).map(\.identity.pid)) == [100, 101])

        let replacementRoot = process(100, parent: 1, group: 100, startedAt: 2)
        let replacementChild = process(101, parent: 100, group: 100, startedAt: 2)
        #expect(tree.members(in: [replacementRoot, replacementChild]).isEmpty)
    }

    @Test func automaticBudgetLeavesRoomForTheRestOfTheMachine() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        #expect(SessionMemoryLimit.automatic.bytes(physicalMemory: 8 * gib) == 2 * gib)
        #expect(SessionMemoryLimit.automatic.bytes(physicalMemory: 16 * gib) == 4 * gib)
        #expect(SessionMemoryLimit.automatic.bytes(physicalMemory: 128 * gib) == 8 * gib)
    }

    @Test func chosenBudgetIsTheWholeGigabytes() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        #expect(SessionMemoryLimit.twelveGB.bytes(physicalMemory: 8 * gib) == 12 * gib)
        #expect(SessionMemoryLimit.resolved(12) == .twelveGB)
        #expect(SessionMemoryLimit.resolved(7) == .automatic)
    }

    @Test func choicesStopAtTheMemoryTheMachineHas() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        #expect(SessionMemoryLimit.choices(physicalMemory: 16 * gib)
            == [.automatic, .twoGB, .fourGB, .eightGB, .twelveGB, .sixteenGB])
        #expect(SessionMemoryLimit.choices(physicalMemory: 8 * gib)
            == [.automatic, .twoGB, .fourGB, .eightGB])
    }

    @Test func footprintRequiresTheSameProcessIdentity() throws {
        let current = try #require(ProcessIdentity.current)
        #expect(try #require(SessionMemoryGuard.footprint(of: current)) > 0)
        #expect(SessionMemoryGuard.footprint(of: .init(
            pid: current.pid, startedAt: current.startedAt + 1)) == nil)
    }

    // Blocking the main actor proves that stopping the process does not depend on the UI.
    @MainActor @Test func killsOnlyItsOwnGroupWithoutWaitingForTheMainActor() throws {
        let watched = try sleeper()
        defer { reap(watched) }
        let unrelated = try sleeper()
        defer { reap(unrelated) }
        let signalled = DispatchSemaphore(value: 0)
        let guardrail = try #require(SessionMemoryGuard(processGroup: watched.pid, limit: 1) { _ in
            signalled.signal()
        })
        defer { guardrail.stop() }

        #expect(signalled.wait(timeout: .now() + 5) == .success)
        #expect(guardrail.violation != nil)
        #expect(CommandRunner.waitForExit(of: watched.pid) != 0)
        #expect(!watched.isAlive)
        #expect(unrelated.isAlive)
    }

    @Test func stoppingMonitoringLeavesAnUnderBudgetProcessAlone() async throws {
        let watched = try sleeper()
        defer { reap(watched) }
        var guardrail: SessionMemoryGuard? = try #require(SessionMemoryGuard(
            processGroup: watched.pid, limit: 64 * 1_024 * 1_024) { _ in
                Issue.record("An idle process should stay below its memory budget")
            })
        weak var released: SessionMemoryGuard? = guardrail
        try await Task.sleep(for: .milliseconds(600))
        #expect(guardrail?.stop() == nil)
        #expect(watched.isAlive)
        // A stopped guard must release its timer and process history with the turn.
        guardrail = nil
        #expect(await waitUntil { released == nil })
    }

    private func sleeper() throws -> ProcessIdentity {
        let null = open("/dev/null", O_RDWR)
        defer { close(null) }
        let pid = try CommandRunner.spawnIsolatedProcess(
            executable: "/bin/sleep", arguments: ["15"], currentDirectory: nil,
            environment: ProcessInfo.processInfo.environment,
            standardInput: null, standardOutput: null, standardError: null,
            descriptorsToClose: [])
        return try #require(ProcessIdentity.of(pid))
    }

    private func reap(_ process: ProcessIdentity) {
        if process.isAlive { kill(process.pid, SIGKILL) }
        _ = waitpid(process.pid, nil, 0)
    }
}

@MainActor
struct SessionMemoryLimitRunnerTests {
    private static let start = """
    IFS= read -r input
    printf 'started\n' >> "$folder/starts"
    printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"session-1"}'
    """

    // At most 32 MiB of payload, with a deadline even if the test fails. A separate
    // process group exercises commands that escape the CLI's own group.
    private static let allocate = """
    /usr/bin/perl -e '
        use POSIX qw(setsid);
        setsid() != -1 or die "setsid failed";
        open(my $pid, ">", "$ARGV[0]/child-pid") or die $!;
        print $pid $$; close($pid);
        my $deadline = time() + 15;
        until (-e "$ARGV[0]/allocate") {
            exit 0 if time() >= $deadline;
            select(undef, undef, undef, 0.02);
        }
        my $memory = "x" x int($ARGV[1]);
        sleep 15;
        exit(length($memory) == 0);
    ' "$folder" 33554432 &
    wait
    """

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func stopsRunawayChildrenAndKeepsQueuedWorkPaused(agent: AgentKind) async throws {
        var recapChecks = 0
        let reply = """
        printf '%s\n' '{"type":"item.completed","item":{"id":"answer","item_type":"agent_message","text":"Tests started"}}'
        printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Tests started"}]}}'
        """
        let fixture = try RunnerHarness(agent: agent,
                                        script: Self.start + "\n" + reply + "\n" + Self.allocate,
                                        memoryLimit: 24 * 1_024 * 1_024,
                                        automaticRecapsEnabled: { recapChecks += 1; return true })
        defer { fixture.tearDown() }
        fixture.runner.send("Run the tests", sessionID: fixture.session.id, store: fixture.store)
        let child = try await child(in: fixture)
        defer { if child.isAlive { kill(child.pid, SIGKILL) } }
        #expect(getpgid(child.pid) == child.pid)
        fixture.runner.send("Next task", sessionID: fixture.session.id, store: fixture.store)
        try Data().write(to: fixture.scratch.path("allocate"))

        #expect(await waitUntil(timeout: .seconds(5)) {
            if case .failed = fixture.runner.state(fixture.session.id) { return true }
            return false
        })
        #expect(await waitUntil(timeout: .seconds(5)) { !child.isAlive })
        #expect(fixture.runner.queued(fixture.session.id).map(\.text) == ["Next task"])
        #expect(fixture.store.transcript(of: fixture.session.id).first?.text == "Run the tests")
        #expect(fixture.store.transcript(of: fixture.session.id)
            .contains { $0.role == .assistant && $0.text == "Tests started" })
        let note = try #require(fixture.store.transcript(of: fixture.session.id).last)
        #expect(note.role == .system)
        #expect(note.text.contains("Stopped to protect your Mac"))
        #expect(note.text.contains("24 MB"))
        #expect(recapChecks == 0)
        #expect(try String(contentsOf: fixture.scratch.path("starts"), encoding: .utf8) == "started\n")
    }

    @Test(arguments: [AgentKind.codex, .claudeCode])
    func aRecapMemoryStopDoesNotRunFallbacksOrQueuedPrompts(agent: AgentKind) async throws {
        let fixture = try RunnerHarness(agent: agent, script: Self.start + "\n" + Self.allocate,
                                        memoryLimit: 24 * 1_024 * 1_024)
        defer { fixture.tearDown() }
        fixture.store.setAgentSessionID("existing-session", agent: agent, for: fixture.session.id)
        #expect(fixture.runner.recap(fixture.session.id, store: fixture.store))
        let child = try await child(in: fixture)
        defer { if child.isAlive { kill(child.pid, SIGKILL) } }
        fixture.runner.send("Continue the work", sessionID: fixture.session.id, store: fixture.store)
        try Data().write(to: fixture.scratch.path("allocate"))

        #expect(await waitUntil(timeout: .seconds(5)) {
            if case .failed = fixture.runner.state(fixture.session.id) { return true }
            return false
        })
        #expect(await waitUntil(timeout: .seconds(5)) { !child.isAlive })
        #expect(!fixture.runner.isRecapping(fixture.session.id))
        #expect(fixture.store.recap(for: fixture.session.id) == nil)
        #expect(fixture.runner.queued(fixture.session.id).map(\.text) == ["Continue the work"])
        #expect(fixture.store.transcript(of: fixture.session.id).last?.text
            .contains("Stopped to protect your Mac") == true)
        #expect(try String(contentsOf: fixture.scratch.path("starts"), encoding: .utf8) == "started\n")
    }

    private func child(in fixture: RunnerHarness) async throws -> ProcessIdentity {
        let file = fixture.scratch.path("child-pid")
        try #require(await waitUntil {
            FileManager.default.fileExists(atPath: file.path)
                && fixture.store.session(fixture.session.id)?.hasAgentConversation == true
        })
        let pid = try #require(pid_t(String(contentsOf: file, encoding: .utf8)))
        return try #require(ProcessIdentity.of(pid))
    }
}
