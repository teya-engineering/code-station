import Foundation
import Testing
@testable import CodeStationCore

// Only one process may write the station's files at a time: two front ends saving the same
// projects.json would each overwrite what the other wrote. The lock is what keeps a second
// GUI, or the TUI, from starting on top of a running one.
struct StationLockTests {

    @Test func aFreeLockIsClaimed() throws {
        let scratch = ScratchDirectory(prefix: "station-lock")
        let file = scratch.path("station.lock")

        let lock = try #require(StationLock.claim(.gui, at: file).lock)
        defer { lock.release() }

        #expect(lock.holder == StationLock.Holder(pid: getpid(), kind: .gui))
    }

    // A flock belongs to an open file, not to a process, so a second claim from the same
    // test process meets the lock exactly as a second app would.
    @Test func aSecondClaimIsRefusedAndNamesTheHolder() throws {
        let scratch = ScratchDirectory(prefix: "station-lock")
        let file = scratch.path("station.lock")
        let first = try #require(StationLock.claim(.gui, at: file).lock)
        defer { first.release() }

        let second = StationLock.claim(.tui, at: file)

        #expect(second.lock == nil)
        #expect(second.refusal == StationLock.Holder(pid: getpid(), kind: .gui))
    }

    // The record grows: a front end that predates a field must still name the holder
    // rather than see a nameless lock.
    @Test func aRecordWithFieldsFromANewerVersionStillNamesTheHolder() throws {
        let scratch = ScratchDirectory(prefix: "station-lock")
        let file = scratch.path("station.lock")
        try #"{"pid":\#(getpid()),"kind":"daemon","endpoint":"/tmp/station.sock","colour":"teal"}"#
            .write(to: file, atomically: false, encoding: .utf8)
        let held = open(file.path, O_RDWR)
        defer { close(held) }
        #expect(flock(held, LOCK_EX | LOCK_NB) == 0)

        #expect(StationLock.claim(.gui, at: file).refusal
                == StationLock.Holder(pid: getpid(), kind: .daemon, endpoint: "/tmp/station.sock"))
    }

    // A host records the socket it serves on, and a front end reads it without taking
    // the lock. Once the host lets go, nobody is named.
    @Test func aHolderAdvertisesItsEndpointUntilItLetsGo() throws {
        let scratch = ScratchDirectory(prefix: "station-lock")
        let file = scratch.path("station.lock")
        let lock = try #require(StationLock.claim(.daemon, at: file).lock)
        #expect(StationLock.holder(at: file) == StationLock.Holder(pid: getpid(), kind: .daemon))

        lock.advertise("/tmp/station.sock")

        #expect(StationLock.holder(at: file)?.endpoint == "/tmp/station.sock")
        #expect(StationLock.claim(.tui, at: file).refusal?.endpoint == "/tmp/station.sock")
        lock.release()
        #expect(StationLock.holder(at: file) == nil)
    }

    // A crashed app leaves its record behind. The kernel has already dropped its lock, so
    // the next launch takes over without asking anyone.
    @Test func aRecordLeftByADeadProcessIsReclaimed() throws {
        let scratch = ScratchDirectory(prefix: "station-lock")
        let file = scratch.path("station.lock")
        let dead = try deadPID()
        try JSONEncoder().encode(StationLock.Holder(pid: dead, kind: .gui)).write(to: file)

        let lock = try #require(StationLock.claim(.tui, at: file).lock)
        defer { lock.release() }

        #expect(lock.holder == StationLock.Holder(pid: getpid(), kind: .tui))
    }

    // A dead owner can still leave the lock held, by a child that inherited the open file.
    // The record names a process that no longer exists, so the claim takes over anyway.
    @Test func aLockStillHeldInTheNameOfADeadProcessIsReclaimed() throws {
        let scratch = ScratchDirectory(prefix: "station-lock")
        let file = scratch.path("station.lock")
        let dead = try deadPID()
        try JSONEncoder().encode(StationLock.Holder(pid: dead, kind: .gui)).write(to: file)
        let inherited = open(file.path, O_RDWR)
        defer { close(inherited) }
        #expect(flock(inherited, LOCK_EX | LOCK_NB) == 0)

        let lock = try #require(StationLock.claim(.tui, at: file).lock)
        defer { lock.release() }

        #expect(lock.holder == StationLock.Holder(pid: getpid(), kind: .tui))
        #expect(StationLock.claim(.gui, at: file).refusal == lock.holder)
    }

    // A normal quit hands the station back, so the next front end starts straight away
    // while the one that quit may still be winding down.
    @Test func aReleasedLockCanBeClaimedAgain() throws {
        let scratch = ScratchDirectory(prefix: "station-lock")
        let file = scratch.path("station.lock")
        let first = try #require(StationLock.claim(.gui, at: file).lock)
        #expect(StationLock.claim(.tui, at: file).lock == nil)

        first.release()

        let second = try #require(StationLock.claim(.tui, at: file).lock)
        defer { second.release() }
        #expect(StationLock.claim(.gui, at: file).refusal == second.holder)
    }

    // Releasing twice, as an explicit release followed by the lock going away, must not
    // close a descriptor that has since been handed to something else.
    @Test func releasingTwiceLeavesALaterClaimAlone() throws {
        let scratch = ScratchDirectory(prefix: "station-lock")
        let file = scratch.path("station.lock")
        let first = try #require(StationLock.claim(.gui, at: file).lock)
        first.release()
        let second = try #require(StationLock.claim(.tui, at: file).lock)
        defer { second.release() }

        first.release()

        #expect(StationLock.claim(.gui, at: file).refusal == second.holder)
    }

    // The pid of a process that has run and been reaped, so nothing answers to it.
    private func deadPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
