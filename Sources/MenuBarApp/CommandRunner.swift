import Darwin
import Foundation

// Runs a command in its own process group so cancellation and timeouts also stop any
// children it creates. Most callers consume captured output after exit; callers that
// show live output can receive chunks while the command is still running.
enum CommandRunner {
    struct Output: Sendable, Equatable {
        let output: String
        let errorOutput: String
        let status: Int32
        let outputTruncated: Bool
        let errorOutputTruncated: Bool

        var succeeded: Bool { status == 0 }
    }

    enum OutputLineAction: Sendable {
        case none
        case write(Data)
        case finishProcess
    }

    enum RunError: LocalizedError, Sendable, Equatable {
        case launch(String)
        case read(String)
        case write(String)
        case termination(String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .launch(let message): "Could not start command: \(message)"
            case .read(let message): "Could not read command output: \(message)"
            case .write(let message): "Could not write command input: \(message)"
            case .termination(let message): "Could not stop command: \(message)"
            case .timedOut: "Command timed out."
            case .cancelled: "Command was cancelled."
            }
        }
    }

    static func run(
        executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil,
        outputLineHandler: (@Sendable (String) -> OutputLineAction)? = nil,
        // For output that is not framed by newlines: sees every chunk as it arrives and
        // can answer or stop the process the way the line handler can.
        outputChunkAction: (@Sendable (Data) -> OutputLineAction)? = nil,
        outputChunkHandler: (@Sendable (Data) -> Void)? = nil,
        errorOutputChunkHandler: (@Sendable (Data) -> Void)? = nil,
        timeout: Duration?,
        outputByteLimit: Int = 1_048_576
    ) async throws -> Output {
        precondition(outputByteLimit > 0)

        let controller = ProcessController()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw RunError.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try execute(
                            executable: executable,
                            arguments: arguments,
                            currentDirectory: currentDirectory,
                            environment: environment,
                            input: input,
                            outputLineHandler: outputLineHandler,
                            outputChunkAction: outputChunkAction,
                            outputChunkHandler: outputChunkHandler,
                            errorOutputChunkHandler: errorOutputChunkHandler,
                            timeout: timeout,
                            outputByteLimit: outputByteLimit,
                            controller: controller
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            controller.stop(because: .cancelled)
        }
    }

    // Synchronous callers must already be off the main thread. This shares every
    // launch, capture, timeout, and cleanup guarantee with the async entry point.
    static func runBlocking(
        executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil,
        outputLineHandler: (@Sendable (String) -> OutputLineAction)? = nil,
        outputChunkHandler: (@Sendable (Data) -> Void)? = nil,
        errorOutputChunkHandler: (@Sendable (Data) -> Void)? = nil,
        timeout: Duration? = nil,
        outputByteLimit: Int = 1_048_576
    ) throws -> Output {
        precondition(outputByteLimit > 0)
        return try execute(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            input: input,
            outputLineHandler: outputLineHandler,
            outputChunkAction: nil,
            outputChunkHandler: outputChunkHandler,
            errorOutputChunkHandler: errorOutputChunkHandler,
            timeout: timeout,
            outputByteLimit: outputByteLimit,
            controller: ProcessController()
        )
    }

    private static func execute(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        input: Data?,
        outputLineHandler: (@Sendable (String) -> OutputLineAction)?,
        outputChunkAction: (@Sendable (Data) -> OutputLineAction)?,
        outputChunkHandler: (@Sendable (Data) -> Void)?,
        errorOutputChunkHandler: (@Sendable (Data) -> Void)?,
        timeout: Duration?,
        outputByteLimit: Int,
        controller: ProcessController
    ) throws -> Output {
        if let error = controller.error {
            throw error
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        closeOnExec(outputPipe, errorPipe)
        let readHandles = [outputPipe.fileHandleForReading, errorPipe.fileHandleForReading]
        for handle in readHandles {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw RunError.read(String(cString: strerror(errno)))
            }
        }

        let answersOutput = outputLineHandler != nil || outputChunkAction != nil
        let inputPipe: Pipe?
        if input != nil || answersOutput {
            let pipe = Pipe()
            closeOnExec(pipe)
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            inputPipe = pipe
        } else {
            inputPipe = nil
        }
        let nullInput = inputPipe == nil ? FileHandle(forReadingAtPath: "/dev/null") : nil
        guard let standardInput = inputPipe?.fileHandleForReading.fileDescriptor
            ?? nullInput?.fileDescriptor else {
            throw RunError.launch("Could not open /dev/null.")
        }

        let processID: pid_t
        var childCloseDescriptors = [outputPipe.fileHandleForReading.fileDescriptor,
                                     errorPipe.fileHandleForReading.fileDescriptor]
        if let inputPipe {
            childCloseDescriptors.append(inputPipe.fileHandleForWriting.fileDescriptor)
        }
        processID = try spawnIsolatedProcess(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment ?? ProcessInfo.processInfo.environment,
            standardInput: standardInput,
            standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
            standardError: errorPipe.fileHandleForWriting.fileDescriptor,
            descriptorsToClose: childCloseDescriptors
        )
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        if let inputPipe { try? inputPipe.fileHandleForReading.close() }
        try? nullInput?.close()

        controller.started(processGroup: processID)
        let timeoutItem = timeout.map { timeout in
            let item = DispatchWorkItem { controller.stop(because: .timedOut) }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout.timeInterval,
                execute: item
            )
            return item
        }

        let outputBox = CaptureBox()
        let errorBox = CaptureBox()
        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.value = capture(
                outputPipe.fileHandleForReading,
                limit: outputByteLimit,
                lineHandler: outputLineHandler,
                chunkAction: outputChunkAction,
                chunkHandler: outputChunkHandler,
                inputHandle: inputPipe?.fileHandleForWriting,
                controller: controller
            )
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorBox.value = capture(errorPipe.fileHandleForReading,
                                     limit: outputByteLimit,
                                     chunkHandler: errorOutputChunkHandler,
                                     controller: controller)
            drains.leave()
        }

        if let inputPipe {
            do {
                if let input { try inputPipe.fileHandleForWriting.write(contentsOf: input) }
                if !answersOutput { try inputPipe.fileHandleForWriting.close() }
            } catch {
                controller.stop(because: .write(error.localizedDescription))
            }
        }

        let status = waitForExit(of: processID, controller: controller)
        let groupStopped = controller.ensureGroupStopped()
        if !groupStopped {
            controller.stop(because: .termination(
                "the process group is still running after SIGKILL"))
        }
        // Once the group is gone, output draining is only consuming bytes already in our
        // pipes. A busy executor must not turn that scheduling delay into a timeout after
        // the command itself completed successfully.
        timeoutItem?.cancel()
        drains.wait()
        if !groupStopped {
            throw RunError.termination("the process group is still running after SIGKILL")
        }
        let runError = controller.finished(processGroup: processID)

        if let runError { throw runError }
        if let error = outputBox.value.error ?? errorBox.value.error {
            throw RunError.read(error)
        }

        return Output(
            output: String(decoding: outputBox.value.data, as: UTF8.self),
            errorOutput: String(decoding: errorBox.value.data, as: UTF8.self),
            status: status,
            outputTruncated: outputBox.value.truncated,
            errorOutputTruncated: errorBox.value.truncated
        )
    }

    static func spawnIsolatedProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32,
        descriptorsToClose: [Int32]
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw RunError.launch("Could not prepare the child process.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw RunError.launch("Could not prepare the child process.")
        }
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        let duplicates = [(standardInput, STDIN_FILENO),
                          (standardOutput, STDOUT_FILENO),
                          (standardError, STDERR_FILENO)]
        var actionResults = duplicates.map {
            posix_spawn_file_actions_adddup2(&actions, $0.0, $0.1)
        }
        let closeDescriptors = Set(descriptorsToClose + duplicates.compactMap {
            $0.0 == $0.1 ? nil : $0.0
        })
        actionResults += closeDescriptors.map {
            posix_spawn_file_actions_addclose(&actions, $0)
        }
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            throw RunError.launch("Could not connect the child process streams.")
        }
        if let currentDirectory {
            // The unsuffixed posix_spawn_file_actions_addchdir only exists in the
            // macOS 26 SDK, so building with an older SDK (CI) fails to find it.
            // The _np variant is available since 10.15 and remains on 26.
            let result = currentDirectory.path.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            }
            guard result == 0 else {
                throw RunError.launch(String(cString: strerror(result)))
            }
        }

        // A child starts the way a shell would start it: nothing blocked, nothing
        // ignored. The spawn happens on a dispatch worker thread, and those run with
        // signals blocked, which a child otherwise inherits across the exec - an
        // interrupt sent to it would then sit pending for as long as it ran, so the
        // command could never be asked to stop the way ^C asks.
        var openMask = sigset_t()
        sigemptyset(&openMask)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        guard posix_spawnattr_setsigmask(&attributes, &openMask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &everySignal) == 0 else {
            throw RunError.launch("Could not reset the child process signals.")
        }

        // Without CLOEXEC_DEFAULT a child inherits every descriptor the app has open, not
        // just the three it is given. Two agent turns running at once is enough for the
        // second one's process to end up holding the write end of the first one's stdin,
        // and then closing that pipe here never reaches the first CLI: it waits on a
        // stream that still has a writer, never exits, and its turn hangs for good.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw RunError.launch("Could not isolate the child process group.")
        }

        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let result = try withCStringArray([executable] + arguments) { argumentPointers in
            try withCStringArray(environmentStrings) { environmentPointers in
                executable.withCString { executablePointer in
                    posix_spawn(&processID, executablePointer, &actions, &attributes,
                                argumentPointers, environmentPointers)
                }
            }
        }
        guard result == 0 else { throw RunError.launch(String(cString: strerror(result))) }

        let reportedGroup = getpgid(processID)
        let exitedBeforeVerification = reportedGroup == -1 && errno == ESRCH
        guard processID > 1,
              processID != getpgrp(),
              reportedGroup == processID || exitedBeforeVerification else {
            Darwin.kill(processID, SIGKILL)
            _ = waitForExit(of: processID, controller: nil)
            throw RunError.launch("Could not verify the child process group.")
        }
        return processID
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                for pointer in pointers { free(pointer) }
                throw RunError.launch("Could not allocate command arguments.")
            }
            pointers.append(pointer)
        }
        defer { for pointer in pointers { free(pointer) } }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func waitForExit(of processID: pid_t,
                                    controller: ProcessController?) -> Int32 {
        var rawStatus: Int32 = 0
        while true {
            let result = waitpid(processID, &rawStatus, 0)
            if result == processID {
                let signal = rawStatus & 0x7F
                return signal == 0 ? (rawStatus >> 8) & 0xFF : signal
            }
            if result < 0, errno == EINTR { continue }
            if result < 0 {
                controller?.stop(because: .read(String(cString: strerror(errno))))
            }
            return -1
        }
    }

    static func waitForExit(of processID: pid_t) -> Int32 {
        waitForExit(of: processID, controller: nil)
    }

    // Keeps a pipe out of the descriptor table of every process the app starts other than
    // the one it was made for. The spawn below already refuses to hand anything else over,
    // but a terminal tab is started by forkpty inside SwiftTerm, which copies the whole
    // table and then execs a shell that lives as long as the tab does. One stray copy of a
    // write end is enough to keep a pipe from ever reaching end of file, and then whoever
    // is reading it waits for a close that cannot come. dup2 clears the mark, so the child
    // a pipe was made for still receives it as one of its three streams.
    static func closeOnExec(_ pipes: Pipe...) {
        for pipe in pipes {
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
                let flags = fcntl(handle.fileDescriptor, F_GETFD)
                guard flags >= 0 else { continue }
                _ = fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC)
            }
        }
    }

    // Stopping a command asks the way a shell asks: ^C first, then a polite terminate,
    // then force. Each step only happens if the one before it was ignored, so a command
    // that tidies up on an interrupt - a tunnel closing its port, a build removing a
    // half-written file - is never cut off part way through doing it.
    static let stopSignals: [Int32] = [SIGINT, SIGTERM, SIGKILL]

    // How long each signal is given before the next one. Long enough for an ordinary
    // clean-up, short enough that a stop still feels like one.
    static let stopGrace: TimeInterval = 0.5

    static func signalProcessGroup(_ processGroup: pid_t, signal: Int32) {
        guard processGroup > 1, processGroup != getpgrp() else { return }
        Darwin.kill(-processGroup, signal)
    }

    @discardableResult
    static func ensureProcessGroupStopped(_ processGroup: pid_t) -> Bool {
        guard processGroup > 1, processGroup != getpgrp() else { return false }
        for signal in stopSignals {
            signalProcessGroup(processGroup, signal: signal)
            // A group cannot ignore SIGKILL, so the wait after it is about the kernel
            // reaping the last of it rather than about giving anything a chance.
            let waits = signal == SIGKILL ? 200 : Int(stopGrace * 100)
            for _ in 0..<waits {
                if !processGroupExists(processGroup) { return true }
                usleep(10_000)
            }
        }
        return !processGroupExists(processGroup)
    }

    private static func processGroupExists(_ processGroup: pid_t) -> Bool {
        if Darwin.kill(-processGroup, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func capture(
        _ handle: FileHandle,
        limit: Int,
        lineHandler: (@Sendable (String) -> OutputLineAction)? = nil,
        chunkAction: (@Sendable (Data) -> OutputLineAction)? = nil,
        chunkHandler: (@Sendable (Data) -> Void)? = nil,
        inputHandle: FileHandle? = nil,
        controller: ProcessController? = nil
    ) -> Capture {
        var data = Data()
        var truncated = false
        var lineBuffer = Data()
        var inputIsOpen = inputHandle != nil
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let descriptor = handle.fileDescriptor
        while true {
            if controller?.error != nil {
                try? handle.close()
                break
            }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    var pollDescriptor = pollfd(fd: descriptor,
                                                events: Int16(POLLIN | POLLHUP),
                                                revents: 0)
                    _ = Darwin.poll(&pollDescriptor, 1, 50)
                    continue
                }
                if errno == EBADF, controller?.error != nil { break }
                return Capture(data: data, truncated: truncated,
                               error: String(cString: strerror(errno)))
            }
            let chunk = Data(buffer.prefix(count))
            chunkHandler?(chunk)
            let remaining = limit - data.count
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { truncated = true }

            // What a handler asked for once it has read the output so far.
            func act(on action: OutputLineAction, through inputHandle: FileHandle) {
                switch action {
                case .none:
                    break
                case .write(let response):
                    guard inputIsOpen else { break }
                    do {
                        try inputHandle.write(contentsOf: response)
                    } catch {
                        inputIsOpen = false
                        controller?.stop(because: .write(error.localizedDescription))
                    }
                case .finishProcess:
                    if inputIsOpen {
                        inputIsOpen = false
                        try? inputHandle.close()
                    }
                    controller?.finish()
                }
            }

            if let chunkAction, let inputHandle {
                act(on: chunkAction(chunk), through: inputHandle)
            }

            if let lineHandler, let inputHandle, lineBuffer.count <= limit {
                lineBuffer.append(chunk.prefix(max(0, limit - lineBuffer.count)))
                while let newline = lineBuffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: lineBuffer[..<newline], as: UTF8.self)
                    lineBuffer.removeSubrange(...newline)
                    act(on: lineHandler(line), through: inputHandle)
                }
            }
        }
        return Capture(data: data, truncated: truncated)
    }

    private struct Capture: Sendable {
        var data = Data()
        var truncated = false
        var error: String?
    }

    private final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Capture()

        var value: Capture {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    private final class ProcessController: @unchecked Sendable {
        private let lock = NSLock()
        private var processGroup: pid_t?
        private var failure: RunError?

        var error: RunError? { lock.withLock { failure } }

        func started(processGroup: pid_t) {
            let shouldStop = lock.withLock {
                self.processGroup = processGroup
                return failure != nil
            }
            if shouldStop { terminate(processGroup) }
        }

        func stop(because error: RunError) {
            let group = lock.withLock { () -> pid_t? in
                guard failure == nil else { return nil }
                failure = error
                return processGroup
            }
            if let group { terminate(group) }
        }

        func finished(processGroup: pid_t) -> RunError? {
            lock.withLock {
                if self.processGroup == processGroup { self.processGroup = nil }
                return failure
            }
        }

        func finish() {
            let group = lock.withLock { processGroup }
            if let group { terminate(group) }
        }

        func ensureGroupStopped() -> Bool {
            guard let group = lock.withLock({ processGroup }) else { return true }
            return CommandRunner.ensureProcessGroupStopped(group)
        }

        private func terminate(_ group: pid_t) {
            guard isSafe(group) else { return }
            escalate(group, from: 0)
        }

        // The group stops owning itself the moment the command finishes, and that is
        // what ends the ladder: a command that went on the interrupt is never sent the
        // signals that would have forced it.
        private func escalate(_ group: pid_t, from step: Int) {
            guard step < CommandRunner.stopSignals.count else { return }
            Darwin.kill(-group, CommandRunner.stopSignals[step])
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + CommandRunner.stopGrace) {
                    let stillOwned = self.lock.withLock { self.processGroup == group }
                    if stillOwned { self.escalate(group, from: step + 1) }
                }
        }

        private func isSafe(_ group: pid_t) -> Bool {
            group > 1 && group != getpgrp()
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

extension String {
    // Wraps the string so a shell reads it back as one argument. Plain words are left
    // alone; anything else is single-quoted, and an embedded quote closes the run, adds
    // an escaped quote, and opens a new one.
    var shellQuoted: String {
        if !isEmpty, allSatisfy({ $0.isLetter || $0.isNumber || "-_=./:@".contains($0) }) {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
