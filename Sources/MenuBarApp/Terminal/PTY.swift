import Darwin
import Foundation
import SwiftTerm

// A shell running on a pseudo terminal. The child gets a real tty, so programs behave
// the way they do in Terminal.app: colours stay on, progress lines redraw, and job
// control works.
//
// SwiftTerm's launcher prepares the process arguments before forkpty and moves
// straight to exec in the child. forkpty is required here because the shell needs
// the slave to be its controlling terminal, not merely its standard input.
final class PTY: @unchecked Sendable {
    private let lock = NSLock()
    private var master: Int32 = -1
    // The shell by pid and start time, so a signal meant for it can never land on a
    // later process given the same number.
    private var child: ProcessIdentity?
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    // The children the shell keeps for itself, so the user's commands stand out.
    private var baselineChildren: Set<pid_t>?

    // Called from the pty's own queues; the owner hops to the main actor itself.
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private let registry: ShellRegistry

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(registry: ShellRegistry = .shared,
         onOutput: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) {
        self.registry = registry
        self.onOutput = onOutput
        self.onExit = onExit
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
    //
    // Each call folds what it sees into the baseline, which is the set of children the
    // shell has had *every* time it was looked at. A helper the shell keeps alive is in
    // all of them and so never counts; a command comes and goes and so drops out on its
    // own. That self-correction matters because a snapshot taken once could be taken
    // while a command happened to be running, and would then treat it as part of the
    // furniture forever. The first call only seeds the baseline and reports idle.
    @discardableResult
    func sampleBusy() -> Bool {
        let (pid, baseline) = lock.withLock { (child?.pid, baselineChildren) }
        guard let pid else { return false }

        let current = Self.children(of: pid)
        let busy = baseline.map { !current.subtracting($0).isEmpty } ?? false

        lock.withLock { baselineChildren = baseline.map { $0.intersection(current) } ?? current }
        return busy
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
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            throw Failure(message: "Could not start \(shell): the executable is not available.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue, access(directory, X_OK) == 0 else {
            throw Failure(message: "Could not start \(shell): \(directory) is not accessible.")
        }

        var size = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(columns, 1)),
                           ws_xpixel: 0, ws_ypixel: 0)
        var shellSignalMask = sigset_t()
        sigemptyset(&shellSignalMask)
        var appSignalMask = sigset_t()
        let maskStatus = pthread_sigmask(SIG_SETMASK, &shellSignalMask, &appSignalMask)
        guard maskStatus == 0 else {
            throw Failure(message: "Could not prepare signals for \(shell): \(String(cString: strerror(maskStatus))).")
        }
        defer { pthread_sigmask(SIG_SETMASK, &appSignalMask, nil) }

        guard let process = PseudoTerminalHelpers.fork(
            andExec: shell,
            args: [shell] + arguments,
            env: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: directory,
            desiredWindowSize: &size
        ) else {
            throw Failure(message: "Could not start \(shell) in a pseudo terminal.")
        }

        // Written down before anything else is set up: from here on the shell is a live
        // process that outlives this one unless something closes it.
        let shell = ProcessIdentity.of(process.pid)
        if let shell { registry.record(shell) }

        lock.withLock {
            master = process.masterFd
            child = shell
        }

        startReading(master: process.masterFd)
        startWatching(pid: process.pid)
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
        lock.withLock { readSource = source }
    }

    private func startWatching(pid: pid_t) {
        let queue = DispatchQueue(label: "pty.exit", qos: .utility)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        let handler = onExit
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            if let self, let shell = self.takeChild() {
                // A shell that exited on its own is nobody's to close, so the note goes
                // with it rather than waiting for whoever still holds this object.
                self.registry.forget(shell)
            }
            // A shell that exits normally reports its own status; a killed one reports
            // the signal, which is still "it is gone" as far as the UI cares.
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            handler(Int32(code))
        }
        source.resume()
        lock.withLock { exitSource = source }
    }

    private func finishReading() {
        lock.withLock {
            readSource?.cancel()
            readSource = nil
        }
    }

    // Hands the shell over and forgets it, so only one caller ever acts on its exit.
    private func takeChild() -> ProcessIdentity? {
        lock.withLock {
            let shell = child
            child = nil
            return shell
        }
    }

    // MARK: - Talking to the shell

    func write(_ data: Data) {
        let fd = lock.withLock { master }
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
        let fd = lock.withLock { master }
        guard fd >= 0 else { return }
        var size = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(columns, 1)),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

    // MARK: - Stopping

    // The registry hangs the shell up, which is what closing a terminal window does, and
    // waits for it in the background so the note on disk is only dropped once the shell
    // has really gone. Nothing here waits, so a tab closes at once.
    func stop() {
        let fd = lock.withLock {
            readSource?.cancel()
            exitSource?.cancel()
            readSource = nil
            exitSource = nil
            let fd = master
            master = -1
            return fd
        }
        if let shell = takeChild() { registry.retire(shell) }
        if fd >= 0 { close(fd) }
    }

    deinit { stop() }
}
