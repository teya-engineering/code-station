import Foundation
import Synchronization

// Brings a repository down from a remote so it can become a project. The clone lands in a
// hidden folder beside the destination and only takes its real name once it is whole, so
// a failed or cancelled clone never leaves a half-made project folder, and clearing up
// after one can only ever touch a folder this code made. The hidden folder is noted in the
// preferences while the clone runs, so one left by a quit or a crash goes at the next launch.
enum GitClone {
    struct Progress: Sendable, Equatable {
        var phase: String
        var percent: Int
    }

    enum Outcome: Sendable, Equatable {
        case cloned(URL)
        case failed(String)
        // Git needed a login or a host key it could not ask for. Said as what it means,
        // with the SSH address to try instead when one can be worked out.
        case signInRequired(GitSignInRequired)
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
                      preferences: UserDefaults = .standard,
                      onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async -> Outcome {
        guard let tool = await GitInspector.tool() else {
            return .failed("Could not find git on PATH.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return .failed("\(destination.path.abbreviatedPath) already exists.")
        }
        let parent = destination.deletingLastPathComponent()
        let partial = parent.appendingPathComponent(
            ".\(destination.lastPathComponent)\(partialMark)\(UUID().uuidString)", isDirectory: true)
        notePartial(partial, in: preferences)

        let environment = GitEnvironment.nonInteractive(searchPath: tool.searchPath)
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
                // Git can finish just as the person cancels. Their choice wins.
                if Task.isCancelled { throw CommandRunner.RunError.cancelled }
                try FileManager.default.moveItem(at: partial, to: destination)
                outcome = .cloned(destination)
            } else {
                outcome = output.failure(address: remote)
            }
        } catch CommandRunner.RunError.cancelled {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
        }

        // Git removes its own folder on an interrupt, but not if it is forced to stop
        // before it has finished doing so.
        await Task.detached { try? FileManager.default.removeItem(at: partial) }.value
        forgetPartial(partial, in: preferences)
        return outcome
    }

    // Removes what clones left behind when the app stopped before they ended, and says how
    // many went. A folder that cannot be removed yet stays noted for the next launch.
    static func removeLeftovers(in preferences: UserDefaults = .standard) -> Int {
        var removed = 0
        for path in Preferences.partialClones(in: preferences) {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            // The path comes back from a preference and this delete is recursive, so it
            // has to look like a folder this code named.
            if folder.lastPathComponent.hasPrefix("."), folder.lastPathComponent.contains(partialMark),
               FileManager.default.fileExists(atPath: path) {
                guard (try? FileManager.default.removeItem(at: folder)) != nil else { continue }
                removed += 1
            }
            forgetPartial(folder, in: preferences)
        }
        return removed
    }

    private static let partialMark = ".cloning-"

    // Held while the list changes, so that two clones cannot lose each other's change.
    private static let partialListLock = Mutex(())

    private static func notePartial(_ folder: URL, in preferences: UserDefaults) {
        partialListLock.withLock { _ in
            Preferences.setPartialClones(Preferences.partialClones(in: preferences) + [folder.path],
                                         in: preferences)
        }
    }

    private static func forgetPartial(_ folder: URL, in preferences: UserDefaults) {
        partialListLock.withLock { _ in
            Preferences.setPartialClones(Preferences.partialClones(in: preferences).filter { $0 != folder.path },
                                         in: preferences)
        }
    }

    // Git's stderr carries both the progress meter and the reason for a failure. A long
    // clone prints enough meter to fill any capture limit before the reason arrives, so
    // the two are told apart as the output comes in.
    //
    // More lines are kept than are shown. What ssh prints about a changed host key starts
    // well above the last few lines, and it must still be seen when working out what went wrong.
    struct Output {
        private static let keptLines = 200
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
                    lines = Array((lines + [line.trimmed]).suffix(Self.keptLines))
                }
            }
            return latest
        }

        // The newest text, since git states the reason last.
        var complaint: String {
            String(lines.suffix(Self.complaintLines).joined(separator: "\n").suffix(Self.complaintLength))
        }

        func failure(address: String) -> Outcome {
            if let signIn = GitSignIn.problem(in: lines.joined(separator: "\n"), address: address) {
                return .signInRequired(signIn)
            }
            return .failed(complaint.isEmpty ? "Git could not clone the repository." : complaint)
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
        func failure(address: String) -> Outcome { storage.withLock { $0.failure(address: address) } }
    }
}
