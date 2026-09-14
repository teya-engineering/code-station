import Darwin
import Foundation

// How much memory one turn's processes may hold together before the app stops it. The
// automatic choice leaves most of the machine to everything else, which is right for a
// turn that runs away; a fixed choice suits work that genuinely needs a large build.
enum SessionMemoryLimit: Int, CaseIterable, Identifiable, Sendable {
    case automatic = 0
    case twoGB = 2
    case fourGB = 4
    case eightGB = 8
    case twelveGB = 12
    case sixteenGB = 16
    case twentyFourGB = 24
    case thirtyTwoGB = 32
    case sixtyFourGB = 64

    static let fallback = SessionMemoryLimit.automatic

    // A limit the machine could never reach would never stop anything, so it is not
    // offered. Automatic is always there because it is a share of whatever RAM exists.
    static func choices(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory)
        -> [SessionMemoryLimit] {
        allCases.filter { $0 == .automatic || $0.bytes(physicalMemory: physicalMemory) <= physicalMemory }
    }

    static func resolved(_ rawValue: Int) -> SessionMemoryLimit {
        SessionMemoryLimit(rawValue: rawValue) ?? fallback
    }

    var id: Int { rawValue }

    var title: String {
        self == .automatic ? "Automatic" : "\(rawValue) GB"
    }

    func bytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> UInt64 {
        guard self != .automatic else {
            return min(8 * 1_024 * 1_024 * 1_024, physicalMemory / 4)
        }
        return UInt64(rawValue) * 1_024 * 1_024 * 1_024
    }

    func detail(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String? {
        guard self == .automatic else { return nil }
        let bytes = Int64(bytes(physicalMemory: physicalMemory))
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

// The CLI can start builds in other process groups. Remember their identities while
// they belong to the turn so that changing groups or losing a parent does not hide them.
final class SessionMemoryGuard: @unchecked Sendable {
    struct Violation: Sendable {
        let bytes: UInt64
        let limit: UInt64
        let largestPID: pid_t
        let largestBytes: UInt64
        let largestProcessName: String?

        var message: String {
            let used = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
            let allowed = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .memory)
            let largestUsed = ByteCountFormatter.string(fromByteCount: Int64(largestBytes),
                                                       countStyle: .memory)
            let process = largestProcessName.map { "\($0) (PID \(largestPID))" }
                ?? "PID \(largestPID)"
            return "Stopped to protect your Mac: this session's agent and child processes used "
                + "\(used), exceeding the \(allowed) memory limit. "
                + "Largest process: \(process) used \(largestUsed). Review this process before trying again."
        }
    }

    struct ProcessEntry {
        let identity: ProcessIdentity
        let parentPID: pid_t
        let group: pid_t
    }

    struct ProcessTree {
        let root: ProcessIdentity
        private var tracked: [pid_t: ProcessIdentity]

        init(root: ProcessIdentity) {
            self.root = root
            tracked = [root.pid: root]
        }

        mutating func members(in processes: [ProcessEntry]) -> [ProcessEntry] {
            var owned = Dictionary(uniqueKeysWithValues: processes.compactMap { process in
                tracked[process.identity.pid] == process.identity
                    ? (process.identity.pid, process) : nil
            })
            // A child can be reparented between samples. The isolated group still names
            // our work, but only while a known member proves that the group is still ours.
            if owned.values.contains(where: { $0.group == root.pid }) {
                for process in processes where process.group == root.pid {
                    owned[process.identity.pid] = process
                }
            }
            var added = true
            while added {
                added = false
                for process in processes where owned[process.identity.pid] == nil {
                    guard let parent = owned[process.parentPID],
                          parent.identity.startedAt <= process.identity.startedAt else { continue }
                    owned[process.identity.pid] = process
                    added = true
                }
            }
            tracked = owned.mapValues(\.identity)
            return Array(owned.values)
        }
    }

    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let byteLimit: UInt64
    private let onLimit: @Sendable (Violation) -> Void
    private var stopped = false
    private var recordedViolation: Violation?
    // Only the timer's serial queue touches the tree.
    private var tree: ProcessTree

    init?(processGroup: pid_t, limit: UInt64,
          onLimit: @escaping @Sendable (Violation) -> Void) {
        guard processGroup > 1, processGroup != getpgrp(),
              let root = ProcessIdentity.of(processGroup) else { return nil }
        tree = ProcessTree(root: root)
        byteLimit = limit
        self.onLimit = onLimit
        timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "session-memory-\(processGroup)", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(250),
                       leeway: .milliseconds(25))
        timer.setEventHandler { @Sendable [weak self] in self?.sample() }
        timer.resume()
    }

    deinit { timer.cancel() }

    var violation: Violation? { lock.withLock { recordedViolation } }

    // Synchronizes with a limit crossing, so exit handling cannot mistake a memory stop
    // for a normal completion and start another turn before the UI callback arrives.
    @discardableResult
    func stop() -> Violation? {
        lock.withLock {
            stopped = true
            timer.cancel()
            return recordedViolation
        }
    }

    private func sample() {
        guard !lock.withLock({ stopped }), let processes = Self.processes() else { return }
        let members = tree.members(in: processes)
        var total: UInt64 = 0
        var largest: (identity: ProcessIdentity, bytes: UInt64) = (tree.root, 0)
        for process in members {
            guard let bytes = Self.footprint(of: process.identity) else { continue }
            total += bytes
            if bytes > largest.bytes { largest = (process.identity, bytes) }
        }
        guard total > byteLimit else { return }
        let violation = Violation(bytes: total, limit: byteLimit,
                                  largestPID: largest.identity.pid, largestBytes: largest.bytes,
                                  largestProcessName: Self.processName(of: largest.identity))
        let shouldReport = lock.withLock {
            guard !stopped else { return false }
            recordedViolation = violation
            stopped = true
            timer.cancel()
            // Do this off the main actor: memory can grow fast enough that waiting for
            // the UI, or allowing a graceful shutdown, exhausts the machine first.
            if members.contains(where: {
                $0.group == tree.root.pid && $0.identity.isAlive
                    && getpgid($0.identity.pid) == tree.root.pid
            }) {
                CommandRunner.signalProcessGroup(tree.root.pid, signal: SIGKILL)
            }
            for process in members where process.identity.pid > 1 && process.identity.isAlive {
                kill(process.identity.pid, SIGKILL)
            }
            return true
        }
        if shouldReport { onLimit(violation) }
    }

    static func footprint(of process: ProcessIdentity) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0, process.isAlive else { return nil }
        // Footprint includes compressed memory, which disappears from an RSS reading
        // just when the machine is struggling to free RAM.
        return usage.ri_phys_footprint
    }

    // Capture the executable before stopping it; a PID alone cannot identify it afterward.
    static func processName(of process: ProcessIdentity) -> String? {
        // Swift cannot import PROC_PIDPATHINFO_MAXSIZE, which is four times MAXPATHLEN.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let size = UInt32(buffer.count)
        let hasPath = proc_pidpath(process.pid, &buffer, size) > 0
        if !hasPath {
            buffer = [UInt8](repeating: 0, count: buffer.count)
            guard proc_name(process.pid, &buffer, size) > 0 else { return nil }
        }
        guard process.isAlive else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        let name = hasPath ? URL(fileURLWithPath: value).lastPathComponent : value
        return name.isEmpty ? nil : name
    }

    private static func processes() -> [ProcessEntry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // Process creation can outgrow the buffer between the size query and the read.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
            var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = entries.count * stride
            let result = entries.withUnsafeMutableBytes {
                sysctl(&mib, 4, $0.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            return entries.prefix(size / stride).map { entry in
                let started = entry.kp_proc.p_starttime
                return ProcessEntry(identity: ProcessIdentity(
                    pid: entry.kp_proc.p_pid,
                    startedAt: Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec)),
                    parentPID: entry.kp_eproc.e_ppid, group: entry.kp_eproc.e_pgid)
            }
        }
        return nil
    }
}
