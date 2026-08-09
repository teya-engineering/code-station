import Darwin
import Foundation

// Runs commands that are expected to finish and whose output is consumed only after
// they exit. Long-lived and streaming processes keep their own lifecycle managers.
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
        timeout: Duration,
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
        timeout: Duration?,
        outputByteLimit: Int,
        controller: ProcessController
    ) throws -> Output {
        if let error = controller.error {
            throw error
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let readHandles = [outputPipe.fileHandleForReading, errorPipe.fileHandleForReading]
        for handle in readHandles {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw RunError.read(String(cString: strerror(errno)))
            }
        }

        let inputPipe: Pipe?
        if input != nil || outputLineHandler != nil {
            let pipe = Pipe()
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
                inputHandle: inputPipe?.fileHandleForWriting,
                controller: controller
            )
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorBox.value = capture(errorPipe.fileHandleForReading,
                                     limit: outputByteLimit,
                                     controller: controller)
            drains.leave()
        }

        if let inputPipe {
            do {
                if let input { try inputPipe.fileHandleForWriting.write(contentsOf: input) }
                if outputLineHandler == nil { try inputPipe.fileHandleForWriting.close() }
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
            let result = currentDirectory.path.withCString {
                if #available(macOS 26.0, *) {
                    posix_spawn_file_actions_addchdir(&actions, $0)
                } else {
                    posix_spawn_file_actions_addchdir_np(&actions, $0)
                }
            }
            guard result == 0 else {
                throw RunError.launch(String(cString: strerror(result)))
            }
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
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

    static func signalProcessGroup(_ processGroup: pid_t, signal: Int32) {
        guard processGroup > 1, processGroup != getpgrp() else { return }
        Darwin.kill(-processGroup, signal)
    }

    @discardableResult
    static func ensureProcessGroupStopped(_ processGroup: pid_t) -> Bool {
        guard processGroup > 1, processGroup != getpgrp() else { return false }
        signalProcessGroup(processGroup, signal: SIGTERM)
        for _ in 0..<50 {
            if !processGroupExists(processGroup) { return true }
            usleep(10_000)
        }
        signalProcessGroup(processGroup, signal: SIGKILL)
        for _ in 0..<200 {
            if !processGroupExists(processGroup) { return true }
            usleep(10_000)
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
            let remaining = limit - data.count
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { truncated = true }

            if let lineHandler, let inputHandle, lineBuffer.count <= limit {
                lineBuffer.append(chunk.prefix(max(0, limit - lineBuffer.count)))
                while let newline = lineBuffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: lineBuffer[..<newline], as: UTF8.self)
                    lineBuffer.removeSubrange(...newline)
                    switch lineHandler(line) {
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
            Darwin.kill(-group, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                let stillOwned = self.lock.withLock { self.processGroup == group }
                if stillOwned { Darwin.kill(-group, SIGKILL) }
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
