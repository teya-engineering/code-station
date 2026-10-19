import Darwin
import Foundation

// Only one process owns the station's files at a time. The owner holds an exclusive
// advisory lock on a file in Application Support, and the file says who the owner is, so
// a second front end can name it rather than refuse with a shrug.
//
// The lock is a `flock`, so the kernel drops it the moment the owner dies, however it dies.
public final class StationLock: @unchecked Sendable {
    // What kind of front end holds the station.
    public enum Kind: String, Codable, Sendable {
        case gui, tui, daemon

        // How the person is told about a front end of this kind, as the owner of the
        // station or the host it is moving to.
        public var title: String {
            switch self {
            case .gui: "the Code Station app"
            case .tui: "Code Station in a terminal"
            case .daemon: "the Code Station background service"
            }
        }
    }

    // The record written into the lock file. It is JSON so it can grow, and a reader that
    // predates a field simply ignores it.
    public struct Holder: Codable, Equatable, Sendable {
        public let pid: pid_t
        public let kind: Kind
        // The socket the holder serves the station on, once it listens (see
        // `StationSocketServer`). A front end that finds it connects there.
        public var endpoint: String?

        public init(pid: pid_t, kind: Kind, endpoint: String? = nil) {
            self.pid = pid
            self.kind = kind
            self.endpoint = endpoint
        }

        // How a refused front end names the owner to the person who started it.
        public var name: String { "\(kind.title) (pid \(pid))" }
    }

    public enum Outcome: Sendable {
        case claimed(StationLock)
        // The holder is nil only when it took the lock but has not yet said who it is.
        case refused(Holder?)

        public var lock: StationLock? {
            if case .claimed(let lock) = self { return lock }
            return nil
        }

        public var refusal: Holder? {
            if case .refused(let holder) = self { return holder }
            return nil
        }
    }

    public static var defaultFile: URL { AppPaths.supportFile("station.lock") }

    public private(set) var holder: Holder
    private var descriptor: Int32

    private init(holder: Holder, descriptor: Int32) {
        self.holder = holder
        self.descriptor = descriptor
    }

    deinit { release() }

    public static func claim(_ kind: Kind, at file: URL = defaultFile) -> Outcome {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let holder = Holder(pid: getpid(), kind: kind)
        // Each pass either settles the claim or clears something out of its way, so a few
        // are plenty even with another claimant racing this one.
        for _ in 0..<5 {
            // Close-on-exec, so the agents and shells the owner starts do not inherit the
            // lock and keep it held after the owner is gone.
            let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return .refused(nil) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let current = readHolder(from: fd)
                defer { close(fd) }
                // Held in the name of a process that no longer exists: something it left
                // behind still has the file open. A fresh file takes its place, and the
                // old lock goes on guarding nothing. A claimant that has only just taken
                // the lock has not yet replaced the old record, so the record must still
                // name the dead process a moment later, and the path must still be the
                // file that was read, before it is thrown away.
                if let current, !isAlive(current.pid) {
                    usleep(50_000)
                    if readHolder(from: fd) == current, names(file, fd) {
                        unlink(file.path)
                    }
                    continue
                }
                return .refused(current)
            }
            // Another claimant may have replaced the file between the open and the lock,
            // in which case this lock is on a file nobody else will ever look at.
            guard names(file, fd) else {
                close(fd)
                continue
            }
            write(holder, to: fd)
            return .claimed(StationLock(holder: holder, descriptor: fd))
        }
        return .refused(nil)
    }

    // Claims the station once its holder has let go, as the host taking over from a
    // handover does: the host handing over releases the lock after it has saved and swept,
    // which takes a moment. Answers with the last outcome once `timeout` runs out.
    public static func claimOnceReleased(_ kind: Kind, at file: URL = defaultFile,
                                         waitingUpTo timeout: Duration = .seconds(30)) async -> Outcome {
        let deadline = ContinuousClock.now + timeout
        while true {
            let outcome = claim(kind, at: file)
            if outcome.lock != nil || ContinuousClock.now >= deadline { return outcome }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // Stops a holder that cannot be asked to hand over, such as a daemon from another
    // build that refuses this one's handshake: SIGTERM to the pid in its record, which a
    // daemon answers as it answers `kill` (save, sweep, release), then claims the station
    // once it has let go.
    @MainActor
    public static func stopHolder(at file: URL = defaultFile, claiming kind: Kind,
                                  terminate: @MainActor (pid_t) -> Void = { _ = kill($0, SIGTERM) },
                                  waitingUpTo timeout: Duration = .seconds(30)) async -> Outcome {
        if let holder = holder(at: file) { terminate(holder.pid) }
        return await claimOnceReleased(kind, at: file, waitingUpTo: timeout)
    }

    // Who holds the station now, read without trying to take it, so a front end can find
    // the host's socket. Nil when nobody does: the file is empty or missing, or names a
    // process that has gone.
    public static func holder(at file: URL = defaultFile) -> Holder? {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0,
              let holder = try? JSONDecoder().decode(Holder.self, from: Data(buffer[0..<count])),
              isAlive(holder.pid) else { return nil }
        return holder
    }

    // Records the socket this holder now serves the station on.
    public func advertise(_ endpoint: String?) {
        guard descriptor >= 0 else { return }
        holder.endpoint = endpoint
        Self.write(holder, to: descriptor)
    }

    private static func names(_ file: URL, _ fd: Int32) -> Bool {
        var opened = stat(), current = stat()
        guard fstat(fd, &opened) == 0, stat(file.path, &current) == 0 else { return false }
        return opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }

    // A process that exists but belongs to someone else answers EPERM, and is still alive.
    private static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // The owner writes its record straight after taking the lock, so an empty file means
    // a claim is in flight. It gets a moment to finish before the refusal goes without
    // a name.
    private static func readHolder(from fd: Int32) -> Holder? {
        for attempt in 0..<5 {
            if attempt > 0 { usleep(20_000) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = pread(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            if let holder = try? JSONDecoder().decode(Holder.self, from: Data(buffer[0..<count])) {
                return holder
            }
        }
        return nil
    }

    // Unlocked explicitly rather than by closing alone: a process being spawned at that
    // moment may briefly share the open file, and the lock would last as long as its copy.
    // The record is cleared so the file names nobody once the station is free.
    public func release() {
        guard descriptor >= 0 else { return }
        ftruncate(descriptor, 0)
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    private static func write(_ holder: Holder, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(holder) else { return }
        ftruncate(fd, 0)
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }
}
