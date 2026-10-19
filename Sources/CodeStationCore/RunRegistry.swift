import Darwin
import Foundation

// A note on disk for every run of the app, so a later launch can find what that run left
// behind.
//
// macOS files an app and everything it starts under one coalition, and keeps the app in
// the Dock, marked "Running in Background", for as long as any coalition of an earlier
// launch still has a process in it. A clean quit sweeps its own. A crash or a force quit
// sweeps nothing, and a daemon stranded that way holds the Dock icon after every later
// quit as well. By then it belongs to launchd and answers for itself, so the coalition is
// the only thing that still ties it to the app, and that number has to be written down
// while the run that owns it still can.
public struct RunRegistry: Sendable {
    public static let shared = RunRegistry(directory: AppPaths.directory("runs", backedUp: false))

    private let directory: URL
    private let owner: ProcessIdentity?
    private let boot: String?
    private let coalition: @Sendable (pid_t) -> UInt64?

    public init(directory: URL,
         owner: ProcessIdentity? = .current,
         boot: String? = RunRegistry.bootSession,
         coalition: @escaping @Sendable (pid_t) -> UInt64? = RunRegistry.coalition(of:)) {
        self.directory = directory
        self.owner = owner
        self.boot = boot
        self.coalition = coalition
    }

    private struct Marker: Codable {
        public let owner: ProcessIdentity
        public let coalition: UInt64
        // Coalition numbers start again when the machine does, so a number from an
        // earlier boot names something else by now.
        public let boot: String
    }

    // The coalition macOS made for this launch. A copy started from a terminal has none of
    // its own: it shares the terminal's, and sweeping that later would take the terminal
    // and everything in it. Only an app that launchd started, and that answers for itself,
    // owns the coalition it is in. Asked once, as the app starts, because a parent that
    // exits later makes any process look like one launchd started.
    public static func launchCoalition() -> UInt64? {
        let pid = getpid()
        guard getppid() == 1, QuitSweep.responsibleProcess(of: pid) == pid else { return nil }
        return coalition(of: pid)
    }

    // The SDK has no name for this request. It fills in the two coalitions a process is
    // in, and the second is the one the Dock goes by.
    public static func coalition(of pid: pid_t) -> UInt64? {
        var info = [UInt64](repeating: 0, count: 5)
        let size = Int32(MemoryLayout<UInt64>.stride * info.count)
        let filled = info.withUnsafeMutableBytes { proc_pidinfo(pid, 20, 0, $0.baseAddress, size) }
        return filled == size ? info[1] : nil
    }

    public static var bootSession: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    public func record(_ coalition: UInt64?) {
        guard let owner, let boot, let coalition,
              let data = try? JSONEncoder().encode(Marker(owner: owner, coalition: coalition, boot: boot))
        else { return }
        try? PersistentFile.write(data, to: directory.appendingPathComponent("\(coalition).json"))
    }

    // Stops what runs that are over left behind. A run whose app is still going is left
    // alone, which is what stops a second copy of the app from ending the first one's
    // work. Blocks while the processes take their signals, so it belongs off the main
    // actor. Returns how many processes it stopped, for the log.
    @discardableResult
    public func reapEarlierRuns(grace: Duration = QuitSweep.grace) -> Int {
        guard let boot else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var ended: [(coalition: UInt64, note: URL)] = []

        for note in files where note.pathExtension == "json" {
            guard let data = try? PersistentFile.readIfPresent(note),
                  let entry = try? JSONDecoder().decode(Marker.self, from: data),
                  entry.boot == boot else {
                try? PersistentFile.removeIfPresent(note)
                continue
            }
            guard !entry.owner.isAlive else { continue }
            ended.append((entry.coalition, note))
        }

        var coalitions = Set(ended.map(\.coalition))
        // Whatever a note says, the coalition this process is in is never one to sweep.
        if let own = coalition(getpid()) { coalitions.remove(own) }
        let sweep = QuitSweep.leftovers(in: coalitions, coalition: coalition)
        let swept = sweep.finish(grace: grace)

        // A note stays for as long as anything is left in its coalition, so the next
        // launch comes back for it.
        guard let table = SessionMemoryGuard.processes() else { return sweep.count - swept.left }
        let occupied = Set(table.compactMap { coalition($0.identity.pid) })
        for run in ended where !occupied.contains(run.coalition) {
            try? PersistentFile.removeIfPresent(run.note)
        }
        return sweep.count - swept.left
    }
}
