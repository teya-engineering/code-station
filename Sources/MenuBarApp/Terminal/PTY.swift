import Darwin
import Foundation

// A shell running on a pseudo terminal. The child gets a real tty, so programs behave
// the way they do in Terminal.app: colours stay on, progress lines redraw, and job
// control works.
//
// posix_spawn is used rather than fork: this process is multithreaded, and only
// async-signal-safe calls are allowed between fork and exec, which Swift cannot
// promise. Opening the slave as the child's stdin, with the child made a session
// leader, is what gives it a controlling terminal.
final class PTY: @unchecked Sendable {
    private let lock = NSLock()
    private var master: Int32 = -1
    private var child: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    // The children the shell keeps for itself, so the user's commands stand out.
    private var baselineChildren: Set<pid_t>?

    // Both run on the main actor.
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(onOutput: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) {
        self.onOutput = onOutput
        self.onExit = onExit
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return child > 0
    }

    // Whether a command is running in this shell, which is what puts the dot on a tab.
    //
    // This compares the shell's children against the ones it had when it first settled.
    // Two other signals were tried and are wrong: the terminal's foreground process
    // group says "nobody is running" under zsh even while a command plainly is, because
    // shells disagree about putting a foreground command in a group of its own; and a
    // plain "has any child" is always true for anyone whose shell keeps a helper alive
    // (a prompt's git status daemon, for one). What is left after the baseline is a
    // process the shell started for the user.
    var isBusy: Bool {
        lock.lock()
        let pid = child
        let baseline = baselineChildren
        lock.unlock()
        // Until the shell has settled there is nothing to compare against, and calling
        // its startup work "running" would light every tab for a moment.
        guard pid > 0, let baseline else { return false }
        return !Self.children(of: pid).subtracting(baseline).isEmpty
    }

    // Reads the current state and folds it into the baseline, which is the set of
    // children the shell has had *every* time it was looked at. A helper the shell
    // keeps alive is in all of them and so never counts; a command comes and goes and
    // so drops out on its own. That self-correction matters because a snapshot taken
    // once could be taken while a command happened to be running, and would then treat
    // it as part of the furniture forever.
    @discardableResult
    func sampleBusy() -> Bool {
        lock.lock()
        let pid = child
        let baseline = baselineChildren
        lock.unlock()
        guard pid > 0 else { return false }

        let current = Self.children(of: pid)
        let busy = baseline.map { !current.subtracting($0).isEmpty } ?? false

        lock.lock()
        baselineChildren = baseline.map { $0.intersection(current) } ?? current
        lock.unlock()
        return busy
    }

    // Seeds the baseline with whatever the shell has running for itself right now.
    func captureIdleBaseline() {
        lock.lock()
        let pid = child
        lock.unlock()
        guard pid > 0 else { return }
        let current = Self.children(of: pid)
        lock.lock()
        baselineChildren = current
        lock.unlock()
    }

    private static func children(of pid: pid_t) -> Set<pid_t> {
        // The buffer is sized in bytes, but the return is a count of pids.
        var buffer = [pid_t](repeating: 0, count: 64)
        let found = proc_listchildpids(pid, &buffer,
                                       Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        return Set(buffer.prefix(min(Int(found), buffer.count)).filter { $0 > 0 })
    }

    // MARK: - Starting

    func start(shell: String, arguments: [String], directory: String,
               environment: [String: String], columns: Int, rows: Int) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw Failure(message: "Could not open a pseudo terminal.") }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            close(master)
            throw Failure(message: "Could not set up the pseudo terminal.")
        }
        let slavePath = String(cString: name)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opening the tty as fd 0 in a fresh session is what makes it the controlling
        // terminal; 1 and 2 are then the same tty.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argv = ([shell] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
        guard status == 0 else {
            close(master)
            throw Failure(message: "Could not start \(shell): \(String(cString: strerror(status))).")
        }

        lock.lock()
        self.master = master
        self.child = pid
        lock.unlock()

        resize(columns: columns, rows: rows)
        startReading(master: master)
        startWatching(pid: pid)
    }

    private func startReading(master: Int32) {
        let queue = DispatchQueue(label: "pty.read", qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        let handler = onOutput
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(master, &buffer, buffer.count)
            // 0 is the child closing the tty; EIO is what a pty master reports once the
            // last slave is gone, which is the normal way a shell exit shows up here.
            guard count > 0 else {
                if count == 0 || errno != EAGAIN { self?.finishReading() }
                return
            }
            handler(Data(buffer[0..<count]))
        }
        source.resume()
        lock.lock()
        readSource = source
        lock.unlock()
    }

    private func startWatching(pid: pid_t) {
        let queue = DispatchQueue(label: "pty.exit", qos: .utility)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        let handler = onExit
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self?.lock.lock()
            self?.child = -1
            self?.lock.unlock()
            // A shell that exits normally reports its own status; a killed one reports
            // the signal, which is still "it is gone" as far as the UI cares.
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            handler(Int32(code))
        }
        source.resume()
        lock.lock()
        exitSource = source
        lock.unlock()
    }

    private func finishReading() {
        lock.lock()
        readSource?.cancel()
        readSource = nil
        lock.unlock()
    }

    // MARK: - Talking to the shell

    func write(_ data: Data) {
        lock.lock()
        let fd = master
        lock.unlock()
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    // The shell needs the real size or anything that draws a full line - progress
    // bars, wrapped prompts - wraps in the wrong place.
    func resize(columns: Int, rows: Int) {
        lock.lock()
        let fd = master
        lock.unlock()
        guard fd >= 0 else { return }
        var size = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(columns, 1)),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

    // MARK: - Stopping

    // SIGHUP is what closing a terminal window sends, so a shell tears itself and its
    // children down the way it normally would.
    func stop() {
        lock.lock()
        let pid = child
        let fd = master
        readSource?.cancel()
        exitSource?.cancel()
        readSource = nil
        exitSource = nil
        child = -1
        master = -1
        lock.unlock()

        if pid > 0 {
            // Signal the whole process group so a running build goes too.
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
        }
        if fd >= 0 { close(fd) }
    }

    deinit { stop() }
}
