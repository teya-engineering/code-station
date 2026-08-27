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
    private static let graceSeconds: TimeInterval = 2

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

    // Remembers a shell for as long as it runs. The file is named after the shell's pid,
    // which is unique among the shells alive at any one moment.
    @discardableResult
    func record(shell pid: pid_t) -> URL? {
        guard let owner, let shell = ProcessIdentity.of(pid),
              let data = try? JSONEncoder().encode(Marker(shell: shell, owner: owner)) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("\(pid).json")
        guard (try? data.write(to: marker)) != nil else { return nil }
        return marker
    }

    func forget(_ marker: URL?) {
        guard let marker else { return }
        try? FileManager.default.removeItem(at: marker)
    }

    // MARK: - Clearing up after a run that never finished

    // Closes the shells left behind by app runs that are over and drops the notes for
    // shells that have already gone. A shell whose app is still running is left where it
    // is, which is what stops a second copy of the app from closing the first one's
    // terminals. Returns what it closed, for the log.
    @discardableResult
    func reapOrphans() -> [pid_t] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var closed: [pid_t] = []

        for marker in files where marker.pathExtension == "json" {
            guard let data = try? Data(contentsOf: marker),
                  let entry = try? JSONDecoder().decode(Marker.self, from: data) else {
                // A note nothing can be read out of names no process, so it can only be
                // litter from an interrupted write.
                forget(marker)
                continue
            }
            guard !entry.owner.isAlive else { continue }
            if entry.shell.isAlive {
                Self.close(entry.shell)
                closed.append(entry.shell.pid)
            }
            forget(marker)
        }
        return closed
    }

    // SIGHUP is the hangup a shell expects when its terminal goes away, and one that takes
    // it tears its own children down on the way out. A shell that ignores it is sitting in
    // something that traps hangups and will not answer anything gentler either, so the
    // wait is short and what follows it is not up for discussion.
    private static func close(_ shell: ProcessIdentity) {
        // The group as well as the shell, so a command it left running goes too.
        kill(-shell.pid, SIGHUP)
        kill(shell.pid, SIGHUP)

        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if !shell.isAlive { return }
            usleep(50_000)
        }
        kill(-shell.pid, SIGKILL)
        kill(shell.pid, SIGKILL)
    }
}
