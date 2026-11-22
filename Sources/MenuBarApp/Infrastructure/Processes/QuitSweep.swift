import Darwin
import Foundation
import Synchronization

// Every process the app started has to be gone by the time the app is. macOS treats them
// as the app's own work after it quits and keeps the app in the Dock, marked "Running in
// Background", until the last one exits.
//
// Each part of the app asks its own processes to stop on the way out, but most of those
// asks are only the first step of a ladder: a hangup or a terminate now, a kill on a timer
// later. The app is gone before any timer fires, so a shell or a CLI that ignores the
// first signal lives on. Some asks never reach far enough either: stopping a server
// signals the server and not the processes it started.
//
// So the quit takes one picture of everything below the app before anything is stopped,
// lets each part stop its own the gentle way, then gives the whole picture a moment to
// go and kills what is left.
struct QuitSweep {
    // How long everything gets to take the gentle signals before it is killed.
    static let grace: Duration = .milliseconds(1500)

    // A helper that is meant to outlive the app, like the one that starts the updated
    // copy once this one has gone.
    private static let spared = Mutex<Set<pid_t>>([])

    static func spare(_ pid: pid_t) {
        spared.withLock { _ = $0.insert(pid) }
    }

    private let processes: [ProcessIdentity]
    // Signalled as a whole, so whatever a process starts after the picture is taken still
    // goes with it.
    private let groups: Set<pid_t>

    // `root` is the app itself outside tests. It is never signalled, nor is anything in
    // its process group as a group, since that group is the app's own.
    static func snapshot(below root: ProcessIdentity? = .current,
                         registries: [ShellRegistry] = [.shared, .tasks],
                         responsible: (pid_t) -> pid_t? = responsibleProcess(of:)) -> QuitSweep {
        guard let root, let table = SessionMemoryGuard.processes() else {
            return QuitSweep(processes: [], groups: [])
        }
        let spared = Self.spared.withLock { $0 }
        let ownGroup = table.first { $0.identity == root }?.group ?? getpgrp()

        var tree = SessionMemoryGuard.ProcessTree(root: root)
        var members = tree.members(in: table).filter { $0.identity != root }
        // A command that has lost its parent is no longer below the app, but its note
        // still names it, and the rest of its group goes with it.
        let written = Set(registries.flatMap { $0.running() }.map(\.pid))
        members += table.filter { written.contains($0.group) }
        // Something the app started and then let go of, like a daemon, a command sent off
        // with nohup, or a server a finished turn left running, belongs to launchd and has
        // left the tree. macOS still counts it as the app's, and that is the link the Dock
        // follows. XPC services count as well, but launchd ends those with the app.
        members += table.filter { entry in
            entry.identity != root && responsible(entry.identity.pid) == root.pid
                && !isXPCService(entry.identity.pid)
        }

        var groups = Set(members.map(\.group))
        groups.remove(ownGroup)
        let sparedGroups = Set(members.filter { spared.contains($0.identity.pid) }.map(\.group))
        groups.subtract(sparedGroups)
        groups.remove(0)
        groups.remove(1)

        var seen = Set<pid_t>()
        let processes = members
            .filter { !spared.contains($0.identity.pid) && !sparedGroups.contains($0.group) }
            .map(\.identity)
            .filter { seen.insert($0.pid).inserted }
        return QuitSweep(processes: processes, groups: groups)
    }

    // Everything still running in the coalitions of app runs that are over. Those runs
    // stopped nothing on their way out, or not enough, and nobody else is left to.
    static func leftovers(in coalitions: Set<UInt64>, coalition: (pid_t) -> UInt64?) -> QuitSweep {
        guard !coalitions.isEmpty, let table = SessionMemoryGuard.processes() else {
            return QuitSweep(processes: [], groups: [])
        }
        let members = table.filter { entry in
            let pid = entry.identity.pid
            guard pid != getpid(), let home = coalition(pid) else { return false }
            return coalitions.contains(home) && !isXPCService(pid)
        }
        var groups = Set(members.map(\.group))
        groups.remove(getpgrp())
        groups.remove(0)
        groups.remove(1)
        return QuitSweep(processes: members.map(\.identity), groups: groups)
    }

    var count: Int { processes.count }

    // A private call, so it is looked up while the app runs. A system without it only loses
    // this part of the sweep.
    private static let responsibility: (@convention(c) (pid_t) -> pid_t)? = {
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(everywhere, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func responsibleProcess(of pid: pid_t) -> pid_t? {
        guard let responsibility else { return nil }
        let responsible = responsibility(pid)
        return responsible > 0 ? responsible : nil
    }

    private static func isXPCService(_ pid: pid_t) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self).contains(".xpc/")
    }

    // Blocks for at most the grace period and a second on top. Returns how many processes
    // had to be killed and how many were still there after that, for the log.
    @discardableResult
    func finish(grace: Duration = Self.grace) -> (killed: Int, left: Int) {
        guard !processes.isEmpty else { return (0, 0) }
        // A shell takes a hangup and ignores a terminate, and most other things are the
        // other way round, so both are sent.
        signal(SIGHUP)
        signal(SIGTERM)
        let stubborn = Self.waitForExit(of: processes, within: grace)
        guard !stubborn.isEmpty else { return (0, 0) }
        let stubbornGroups = Set(stubborn.compactMap { process in
            let group = getpgid(process.pid)
            return groups.contains(group) ? group : nil
        })
        for group in stubbornGroups { kill(-group, SIGKILL) }
        for process in stubborn where process.isAlive { kill(process.pid, SIGKILL) }
        let left = Self.waitForExit(of: stubborn, within: .seconds(1))
        return (stubborn.count, left.count)
    }

    private func signal(_ signal: Int32) {
        for group in groups { kill(-group, signal) }
        for process in processes where process.isAlive && !groups.contains(getpgid(process.pid)) {
            kill(process.pid, signal)
        }
    }

    private static func waitForExit(of processes: [ProcessIdentity],
                                    within limit: Duration) -> [ProcessIdentity] {
        let deadline = ContinuousClock.now + limit
        var running = processes.filter(isRunning)
        while !running.isEmpty, ContinuousClock.now < deadline {
            usleep(20_000)
            running = running.filter(isRunning)
        }
        return running
    }

    // A child that has exited but not yet been waited on still has an entry in the
    // process table. It is already finished, and only the app's exit will clear it.
    private static func isRunning(_ process: ProcessIdentity) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process.pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        let started = info.kp_proc.p_starttime
        let startedAt = Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec)
        return startedAt == process.startedAt && Int32(info.kp_proc.p_stat) != SZOMB
    }
}
