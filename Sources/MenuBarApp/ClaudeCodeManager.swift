import Foundation
import Observation
import SwiftUI

// Registers servers with the Claude Code CLI so it actually connects to them.
// Detection reads ~/.claude.json directly (fast, no health checks); changes go
// through `claude mcp add/remove` so the CLI owns its config format.
@MainActor
@Observable
final class ClaudeCodeManager {
    struct Entry: Equatable {
        var command: String?
        var args: [String] = []
        var env: [String: String]
    }

    private let configURL: URL
    private(set) var entries: [String: Entry] = [:]
    private(set) var busy: Set<String> = []
    private(set) var bulkBusy = false
    private(set) var errors: [String: String] = [:]
    let available: Bool

    init() {
        configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        available = ProcessManager.resolve("claude") != nil
        refresh()
    }

    func isRegistered(_ name: String) -> Bool { entries[name] != nil }
    func isBusy(_ name: String) -> Bool { busy.contains(name) }

    // True when the server exists in Claude Code but its command, args or env differ
    // from what the app holds (for example after the token was changed here). Remote
    // servers are not diffed - registered counts as in sync.
    func isOutOfSync(_ server: Server) -> Bool {
        guard let entry = entries[server.name] else { return false }
        if server.isRemote { return false }
        if entry.command != resolvedCommand(server) { return true }
        if entry.args != server.args { return true }
        return entry.env != appEnv(server)
    }

    func serversNeedingSync(_ servers: [Server]) -> [Server] {
        servers.filter { !isRegistered($0.name) || isOutOfSync($0) }
    }

    func refresh() {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else {
            entries = [:]
            return
        }
        var result: [String: Entry] = [:]
        for (name, value) in servers {
            let dict = value as? [String: Any]
            result[name] = Entry(command: dict?["command"] as? String,
                                 args: (dict?["args"] as? [String]) ?? [],
                                 env: (dict?["env"] as? [String: String]) ?? [:])
        }
        entries = result
    }

    // Pasteable shell command shown by "Copy command" (this one is quoted for a shell).
    func addCommand(for server: Server) -> String? {
        guard let args = addArgs(for: server) else { return nil }
        return (["claude"] + args).map(quote).joined(separator: " ")
    }

    func add(_ server: Server) {
        guard let args = addArgs(for: server) else {
            errors[server.name] = notFoundMessage(server)
            return
        }
        runSteps([args], names: [server.name])
    }

    func remove(_ name: String) {
        runSteps([removeArgs(name)], names: [name])
    }

    // Remove then add, so a changed token or URL replaces the old registration.
    func reregister(_ server: Server) {
        guard let args = addArgs(for: server) else {
            errors[server.name] = notFoundMessage(server)
            return
        }
        runSteps([removeArgs(server.name), args], names: [server.name])
    }

    // Register everything missing and re-register everything out of sync.
    func syncAll(_ servers: [Server]) {
        var steps: [[String]] = []
        var names: [String] = []
        for server in serversNeedingSync(servers) {
            guard let args = addArgs(for: server) else { continue }
            if isRegistered(server.name) { steps.append(removeArgs(server.name)) }
            steps.append(args)
            names.append(server.name)
        }
        guard !steps.isEmpty else { return }
        runSteps(steps, names: names)
    }

    // MARK: - Private

    // Prefer the absolute path (a Finder-launched app has a minimal PATH), but fall
    // back to the bare command so servers already on PATH still register.
    private func resolvedCommand(_ server: Server) -> String? {
        guard let command = server.command, !command.isEmpty else { return nil }
        return ProcessManager.resolve(command) ?? command
    }

    private func addArgs(for server: Server) -> [String]? {
        if server.isRemote, let url = server.url {
            var args = ["mcp", "add", "--transport", server.transport, server.name, url, "-s", "user"]
            for header in server.headers where !header.key.isEmpty {
                args += ["--header", "\(header.key): \(header.value)"]
            }
            return args
        }
        guard let executable = resolvedCommand(server) else { return nil }
        var args = ["mcp", "add", server.name, "-s", "user"]
        for variable in server.env where !variable.key.isEmpty {
            args += ["-e", "\(variable.key)=\(variable.value)"]
        }
        args += ["--", executable] + server.args
        return args
    }

    private func removeArgs(_ name: String) -> [String] { ["mcp", "remove", name, "-s", "user"] }

    private func notFoundMessage(_ server: Server) -> String {
        "\"\(server.name)\" needs a command or url to register."
    }

    private func appEnv(_ server: Server) -> [String: String] {
        var env: [String: String] = [:]
        for variable in server.env where !variable.key.isEmpty { env[variable.key] = variable.value }
        return env
    }

    // Run the `claude` binary directly, one step at a time. No login shell: it would
    // source the user's profile, which can spawn daemons that inherit the output pipe
    // and keep it open, hanging the read forever. Steps run in order so writes to
    // ~/.claude.json never race.
    private func runSteps(_ steps: [[String]], names: [String]) {
        guard let claudePath = ProcessManager.resolve("claude") else {
            for name in names { errors[name] = "Claude Code CLI not found on PATH." }
            return
        }
        for name in names { busy.insert(name); errors[name] = nil }
        if names.count > 1 { bulkBusy = true }
        runStep(claudePath, steps, index: 0, names: names, failure: nil)
    }

    private func runStep(_ claudePath: String, _ steps: [[String]], index: Int,
                         names: [String], failure: String?) {
        guard index < steps.count else {
            for name in names { busy.remove(name) }
            bulkBusy = false
            if let failure { for name in names { errors[name] = failure } }
            refresh()
            return
        }

        let arguments = steps[index]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessManager.searchPath
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Drain the pipe while the process runs. Waiting until termination to read
        // deadlocks on output larger than the pipe buffer: the child blocks on write
        // and never exits.
        let reader = Task.detached {
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let manager = self
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                let output = await reader.value
                // A failing "remove" is fine (the server may not exist yet); only
                // a failing "add" is a real error worth surfacing.
                var nextFailure = failure
                if code != 0, !arguments.contains("remove") {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    nextFailure = trimmed.isEmpty ? "Command failed (exit \(code))." : trimmed
                }
                manager.runStep(claudePath, steps, index: index + 1, names: names, failure: nextFailure)
            }
        }

        do {
            try process.run()
        } catch {
            // Nothing will ever write to the pipe, so close our end to unblock the reader.
            pipe.fileHandleForWriting.closeFile()
            for name in names { busy.remove(name); errors[name] = error.localizedDescription }
            bulkBusy = false
        }
    }

    private func quote(_ string: String) -> String {
        if !string.isEmpty, string.allSatisfy({ $0.isLetter || $0.isNumber || "-_=./:@".contains($0) }) {
            return string
        }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
