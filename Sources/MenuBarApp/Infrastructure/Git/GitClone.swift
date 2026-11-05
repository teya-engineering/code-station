import Foundation
import Synchronization

// Brings a repository down from a remote so it can become a project. The clone lands in a
// hidden folder beside the destination and only takes its real name once it is whole, so
// a failed or cancelled clone never leaves a half-made project folder, and clearing up
// after one can only ever touch a folder this code made.
enum GitClone {
    struct Progress: Sendable, Equatable {
        var phase: String
        var percent: Int
    }

    enum Outcome: Sendable, Equatable {
        case cloned(URL)
        case failed(String)
        case cancelled
    }

    // The folder git itself would pick: the last part of the address, without `.git`.
    // Handles the scp shape too, where `git@host:repo.git` has no slash to split on.
    static func folderName(for remote: String) -> String? {
        var address = remote.trimmed
        while address.hasSuffix("/") { address.removeLast() }
        if address.hasSuffix(".git") { address.removeLast(4) }
        guard let name = address.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init),
              isUsableFolderName(name) else { return nil }
        return name
    }

    static func isUsableFolderName(_ name: String) -> Bool {
        !name.isBlank && !name.contains("/") && name != "." && name != ".."
    }

    // Runs on CommandRunner rather than GitInspector's queues: a clone can take minutes,
    // and those queues are serial, so every other git read in the app would wait behind it.
    // There is no timeout for the same reason. Cancelling the task stops the clone.
    static func clone(_ remote: String, to destination: URL,
                      onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async -> Outcome {
        guard let tool = await GitInspector.tool() else {
            return .failed("Could not find git on PATH.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return .failed("\(destination.path.abbreviatedPath) already exists.")
        }
        let parent = destination.deletingLastPathComponent()
        let partial = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).cloning-\(UUID().uuidString)", isDirectory: true)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = tool.searchPath
        // No tty here, so git fails on a missing credential rather than waiting for one.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Pins the words Output below reads, whatever language the Mac is set to.
        environment["LC_ALL"] = "C"

        let output = OutputBox()
        let outcome: Outcome
        do {
            let result = try await CommandRunner.run(
                executable: tool.path,
                // `--` keeps a pasted address that starts with a dash from being read as an option.
                arguments: ["clone", "--progress", "--", remote, partial.path],
                environment: environment,
                errorOutputChunkHandler: { chunk in
                    guard let progress = output.read(chunk) else { return }
                    Task { @MainActor in onProgress(progress) }
                },
                timeout: nil,
                outputByteLimit: 65_536)
            if result.succeeded {
                try FileManager.default.moveItem(at: partial, to: destination)
                return .cloned(destination)
            }
            let complaint = output.complaint
            outcome = .failed(complaint.isEmpty ? "Git could not clone the repository." : complaint)
        } catch CommandRunner.RunError.cancelled {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
        }

        // Git removes its own folder on an interrupt, but not if it is forced to stop
        // before it has finished doing so.
        await Task.detached { try? FileManager.default.removeItem(at: partial) }.value
        return outcome
    }

    // Git's stderr carries both the progress meter and the reason for a failure. A long
    // clone prints enough meter to fill any capture limit before the reason arrives, so
    // the two are told apart as the output comes in.
    struct Output {
        private static let complaintLines = 6
        private static let complaintLength = 500

        private var pending = Data()
        private var lines: [String] = []

        // Meter updates end in a carriage return rather than a newline. Returns the newest
        // reading in the chunk, if it held one.
        mutating func read(_ chunk: Data) -> Progress? {
            pending.append(chunk)
            var latest: Progress?
            while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                pending = Data(pending[pending.index(after: end)...])
                if let progress = Self.progress(in: line) {
                    latest = progress
                } else if !Self.isChatter(line) {
                    lines = Array((lines + [line.trimmed]).suffix(Self.complaintLines))
                }
            }
            return latest
        }

        var complaint: String {
            String(lines.joined(separator: "\n").prefix(Self.complaintLength))
        }

        // "Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s"
        static func progress(in line: String) -> Progress? {
            let text = line.hasPrefix("remote: ") ? String(line.dropFirst(8)) : line
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let reading = text[text.index(after: colon)...].drop(while: { $0 == " " })
            guard let sign = reading.firstIndex(of: "%"), let percent = Int(reading[..<sign]) else {
                return nil
            }
            return Progress(phase: String(text[..<colon]), percent: percent)
        }

        private static func isChatter(_ line: String) -> Bool {
            let text = line.trimmed
            return text.isEmpty || text.hasPrefix("Cloning into") || text.hasSuffix(", done.")
                || text.hasPrefix("remote: Total")
        }
    }

    private final class OutputBox: Sendable {
        private let storage = Mutex(Output())

        func read(_ chunk: Data) -> Progress? { storage.withLock { $0.read(chunk) } }
        var complaint: String { storage.withLock { $0.complaint } }
    }
}
