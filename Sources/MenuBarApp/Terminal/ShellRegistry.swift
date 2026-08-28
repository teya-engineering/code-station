import Darwin
import Foundation

// A pid on its own does not name a process. Numbers are handed out again, and the process
// answering to one today may have nothing to do with the one that answered to it an hour
// ago. Pairing the pid with the moment it started is what makes "is this still the same
// process" answerable, which matters here because that answer decides what gets killed.
struct ProcessIdentity: Codable, Equatable {
    let pid: pid_t
    // Microseconds, exactly as the kernel reports them, so two readings of the same
    // process compare equal rather than nearly equal.
    let startedAt: Int64

    static var current: ProcessIdentity? { of(getpid()) }

    static func of(_ pid: pid_t) -> ProcessIdentity? {
        startTime(of: pid).map { ProcessIdentity(pid: pid, startedAt: $0) }
    }

    // False once the process has gone, and false again if its number has since been given
    // to something else.
    var isAlive: Bool { Self.startTime(of: pid) == startedAt }

    private static func startTime(of pid: pid_t) -> Int64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec)
    }
}

// A note on disk for every shell the app has running, so a later launch can find the ones
// nobody was left to close.
//
// A pty shell is a session leader in a process group of its own. Once the app is gone it
// belongs to launchd, holds its pty open, and waits at its prompt for as long as the
// machine stays up. A clean quit hangs it up and it goes; a crash, a force quit or a
// debug build killed from a terminal never reaches that code, and each one of those
// strands a shell for good. Nothing in the process table says which shells were ours, so
// it has to be written down while the app still can.
final class ShellRegistry: @unchecked Sendable {
    static let shared = ShellRegistry(directory: AppPaths.directory("shells", backedUp: false))

    // How long a shell is given to take its hangup before it is killed outright.
    private static let grace: Duration = .seconds(2)

    private let directory: URL
    private let owner: ProcessIdentity?

    init(directory: URL, owner: ProcessIdentity? = .current) {
        self.directory = directory
        self.owner = owner
    }

    private struct Marker: Codable {
        let shell: ProcessIdentity
        let owner: ProcessIdentity
    }

    // MARK: - Keeping track

    // Remembers a shell for as long as it runs.
    func record(_ shell: ProcessIdentity) {
        guard let owner,
              let data = try? JSONEncoder().encode(Marker(shell: shell, owner: owner)) else { return }
        try? PersistentFile.write(data, to: note(for: shell))
    }

    func forget(_ shell: ProcessIdentity) {
        try? PersistentFile.removeIfPresent(note(for: shell))
    }

    // The note carries the full identity in its name, so a note left by a shell that has
    // ended and one for a later shell given the same number never share a path.
    private func note(for shell: ProcessIdentity) -> URL {
        directory.appendingPathComponent("\(shell.pid)-\(shell.startedAt).json")
    }

    // MARK: - Closing

    // Hangs a shell up and drops its note once it has gone. The hangup is sent before this
    // returns, so a quit that ends the app straight afterwards still delivers it; the
    // wait, and the kill for a shell that ignores the hangup, run in the background and
    // block nobody.
    func retire(_ shell: ProcessIdentity) {
        guard shell.isAlive else {
            forget(shell)
            return
        }
        CommandRunner.signalProcessGroup(shell.pid, signal: SIGHUP)
        let note = note(for: shell)
        Task.detached(priority: .utility) { await self.forgetOnceGone(shell, note: note) }
    }

    // Closes the shells left behind by app runs that are over and drops the notes for
    // shells that have already gone. A shell whose app is still running is left where it
    // is, which is what stops a second copy of the app from closing the first one's
    // terminals. Returns what it closed, for the log.
    @discardableResult
    func reapOrphans() async -> [pid_t] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var orphans: [(shell: ProcessIdentity, note: URL)] = []

        for note in files where note.pathExtension == "json" {
            guard let data = try? PersistentFile.readIfPresent(note),
                  let entry = try? JSONDecoder().decode(Marker.self, from: data) else {
                // A note nothing can be read out of names no process, so it can only be
                // litter from an interrupted write.
                try? PersistentFile.removeIfPresent(note)
                continue
            }
            guard !entry.owner.isAlive else { continue }
            guard entry.shell.isAlive else {
                try? PersistentFile.removeIfPresent(note)
                continue
            }
            CommandRunner.signalProcessGroup(entry.shell.pid, signal: SIGHUP)
            orphans.append((entry.shell, note))
        }

        // Every orphan is waited on at once, so a few slow shells share one grace period
        // rather than each serving it in turn.
        return await withTaskGroup(of: pid_t?.self) { group in
            for orphan in orphans {
                group.addTask {
                    await self.forgetOnceGone(orphan.shell, note: orphan.note) ? orphan.shell.pid : nil
                }
            }
            var closed: [pid_t] = []
            for await pid in group {
                if let pid { closed.append(pid) }
            }
            return closed.sorted()
        }
    }

    // SIGHUP is the hangup a shell expects when its terminal goes away, and one that takes
    // it tears its own children down on the way out. A shell that ignores it is sitting in
    // something that traps hangups and will not answer anything gentler either, so the
    // wait is short and what follows it is not up for discussion. True once the shell is
    // gone and its note is dropped. A shell that outlives even the kill keeps its note,
    // so the next launch's reaper comes back for it.
    @discardableResult
    private func forgetOnceGone(_ shell: ProcessIdentity, note: URL) async -> Bool {
        var gone = await Self.isGone(shell, within: Self.grace)
        if !gone {
            CommandRunner.signalProcessGroup(shell.pid, signal: SIGKILL)
            gone = await Self.isGone(shell, within: .seconds(1))
        }
        guard gone else { return false }
        try? PersistentFile.removeIfPresent(note)
        return true
    }

    // Polls rather than blocks, so waiting on a slow shell costs no thread. The last look
    // is taken right before the answer is given, so a kill that follows a "no" never lands
    // on a number that has since been handed to some other process.
    private static func isGone(_ shell: ProcessIdentity, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if !isRunning(shell) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isRunning(shell)
    }

    // A shell the app started is its own child, so its exit has to be collected here or
    // it lingers as a zombie that still answers to its number. For a shell left by an
    // earlier run the call does nothing: that one belongs to launchd.
    private static func isRunning(_ shell: ProcessIdentity) -> Bool {
        guard shell.isAlive else { return false }
        _ = waitpid(shell.pid, nil, WNOHANG)
        return shell.isAlive
    }
}
