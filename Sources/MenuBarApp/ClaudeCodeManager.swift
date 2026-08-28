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
        var env: [String: String] = [:]
        var url: String?
        var type: String?
        var headers: [String: String] = [:]
    }

    private let configURL: URL
    private let registrar = CLIRegistrar(command: "claude",
                                         notFoundMessage: "Claude Code CLI not found on PATH.")
    private(set) var entries: [String: Entry] = [:]
    let available: Bool

    var bulkBusy: Bool { registrar.bulkBusy }
    var errors: [String: String] { registrar.errors }

    init() {
        configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        available = ProcessManager.resolve("claude") != nil
        refresh()
    }

    func isRegistered(_ name: String) -> Bool { entries[name] != nil }
    func isBusy(_ name: String) -> Bool { registrar.isBusy(name) }

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
              let result = Self.configurationEntries(in: data) else {
            entries = [:]
            return
        }
        entries = result
    }

    nonisolated static func configurationEntries(in data: Data) -> [String: Entry]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return nil }
        var result: [String: Entry] = [:]
        for (name, value) in servers {
            let dict = value as? [String: Any]
            result[name] = Entry(command: dict?["command"] as? String,
                                 args: (dict?["args"] as? [String]) ?? [],
                                 env: (dict?["env"] as? [String: String]) ?? [:],
                                 url: dict?["url"] as? String,
                                 type: dict?["type"] as? String,
                                 headers: (dict?["headers"] as? [String: String]) ?? [:])
        }
        return result
    }

    // Pasteable shell command shown by "Copy command" (this one is quoted for a shell).
    func addCommand(for server: Server) -> String? {
        guard let args = addArgs(for: server) else { return nil }
        return (["claude"] + args).map(\.shellQuoted).joined(separator: " ")
    }

    func add(_ server: Server) {
        guard let args = addArgs(for: server) else {
            registrar.errors[server.name] = notFoundMessage(server)
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
            registrar.errors[server.name] = notFoundMessage(server)
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

    private func runSteps(_ steps: [[String]], names: [String]) {
        registrar.run(steps, names: names) { [weak self] in self?.refresh() }
    }
}
