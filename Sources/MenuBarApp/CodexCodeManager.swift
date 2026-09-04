import Foundation
import Observation
import SwiftUI

// Keeps the app's MCP definitions registered with the Codex CLI. The CLI remains the
// owner of ~/.codex/config.toml, so this manager only reads or changes it through
// `codex mcp` commands.
@MainActor
@Observable
final class CodexCodeManager {
    struct Entry: Equatable {
        var command: String?
        var args: [String] = []
        var env: [String: String] = [:]
        var url: String?
        var type: String?
        var enabled = true
    }

    private struct ListedServer: Decodable {
        struct Transport: Decodable {
            let command: String?
            let url: String?
        }

        let name: String
        let enabled: Bool
        let transport: Transport?

        var disabledSnapshot: DisabledMCPServer? {
            if transport?.command != nil {
                return DisabledMCPServer(name: name, transport: .stdio)
            }
            if transport?.url != nil {
                return DisabledMCPServer(name: name, transport: .streamableHTTP)
            }
            return nil
        }
    }

    private struct DiscoveryFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private let registrar = CLIRegistrar(command: "codex",
                                         notFoundMessage: "Codex CLI not found on PATH.")
    private(set) var entries: [String: Entry] = [:]
    private(set) var isRefreshing = false
    let available: Bool

    var bulkBusy: Bool { registrar.bulkBusy }
    var errors: [String: String] { registrar.errors }

    private var knownServers: [String: Server] = [:]
    private var refreshID = UUID()

    init() {
        available = ProcessManager.resolve("codex") != nil
    }

    func isRegistered(_ name: String) -> Bool { entries[name] != nil }
    func isBusy(_ name: String) -> Bool { registrar.isBusy(name) }

    func supports(_ server: Server) -> Bool {
        if server.isRemote {
            return server.transport == "http" && !server.headers.contains { !$0.key.isEmpty }
        }
        return server.command?.isEmpty == false
    }

    // True when the server exists in Codex but its command, args, env or URL differ
    // from the definition held by this app.
    func isOutOfSync(_ server: Server) -> Bool {
        guard let entry = entries[server.name], supports(server) else { return false }
        if server.isRemote { return entry.url != server.url }
        if entry.command != resolvedCommand(server) { return true }
        if entry.args != server.args { return true }
        return entry.env != appEnv(server)
    }

    func serversNeedingSync(_ servers: [Server]) -> [Server] {
        servers.filter { supports($0) && (!isRegistered($0.name) || isOutOfSync($0)) }
    }

    // Codex exposes its server names and each registered server as JSON, which avoids
    // needing to parse its TOML file and keeps this compatible with config format changes.
    // A refresh started while another is still asking the CLI wins: the older one stops
    // at its next step and leaves the entries to the newer one.
    func refresh(_ servers: [Server]) {
        knownServers = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        let id = UUID()
        refreshID = id
        isRefreshing = true
        guard let codexPath = ProcessManager.resolve("codex") else {
            entries = [:]
            isRefreshing = false
            return
        }
        let fallbackNames = servers.map(\.name)
        Task {
            let listed = await Self.output(codexPath, ["mcp", "list", "--json"])
            let names = listed.flatMap { Self.serverNames(in: Data($0.utf8)) } ?? fallbackNames
            var found: [String: Entry] = [:]
            for name in names {
                guard refreshID == id else { return }
                if let output = await Self.output(codexPath, ["mcp", "get", name, "--json"]),
                   let entry = Entry(json: output) {
                    found[name] = entry
                }
            }
            guard refreshID == id else { return }
            entries = found
            isRefreshing = false
        }
    }

    func addCommand(for server: Server) -> String? {
        guard let args = Self.addArguments(for: server, executable: resolvedCommand(server)) else { return nil }
        return (["codex"] + args).map(\.shellQuoted).joined(separator: " ")
    }

    func add(_ server: Server) {
        guard let args = Self.addArguments(for: server, executable: resolvedCommand(server)) else {
            registrar.errors[server.name] = unsupportedMessage(server)
            return
        }
        knownServers[server.name] = server
        runSteps([args], names: [server.name])
    }

    func remove(_ name: String) {
        runSteps([["mcp", "remove", name]], names: [name])
    }

    // Remove then add so a changed command, URL or token replaces the old registration.
    func reregister(_ server: Server) {
        guard let args = Self.addArguments(for: server, executable: resolvedCommand(server)) else {
            registrar.errors[server.name] = unsupportedMessage(server)
            return
        }
        knownServers[server.name] = server
        runSteps([["mcp", "remove", server.name], args], names: [server.name])
    }

    func syncAll(_ servers: [Server]) {
        knownServers = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        var steps: [[String]] = []
        var names: [String] = []
        for server in serversNeedingSync(servers) {
            guard let args = Self.addArguments(for: server, executable: resolvedCommand(server)) else { continue }
            if isRegistered(server.name) { steps.append(["mcp", "remove", server.name]) }
            steps.append(args)
            names.append(server.name)
        }
        guard !steps.isEmpty else { return }
        runSteps(steps, names: names)
    }

    // Codex has no single flag that suppresses every configured MCP server. A diagnosis
    // that turns MCP off snapshots the enabled servers and their transport kinds, using
    // the CLI as the source of truth instead of parsing its TOML file.
    func enabledServers(in directory: String) async throws -> [DisabledMCPServer] {
        guard let codexPath = ProcessManager.resolve("codex") else {
            throw DiscoveryFailure(message: "Codex CLI not found on PATH.")
        }
        let result: CommandRunner.Output
        do {
            result = try await CommandRunner.run(executable: codexPath,
                                                 arguments: ["mcp", "list", "--json"],
                                                 currentDirectory: URL(fileURLWithPath: directory),
                                                 environment: CLIRegistrar.environment,
                                                 timeout: .seconds(30))
        } catch {
            throw DiscoveryFailure(message: "Could not run Codex: \(error.localizedDescription)")
        }
        guard result.succeeded else {
            let message = result.errorOutput.trimmed
            throw DiscoveryFailure(message: message.isEmpty
                ? "Codex could not list its MCP servers."
                : message)
        }
        guard let snapshots = Self.enabledServers(in: Data(result.output.utf8)) else {
            throw DiscoveryFailure(message: "Codex returned an MCP server without a usable transport.")
        }
        return snapshots
    }

    // Kept separate from process handling so the supported Codex CLI forms stay easy
    // to exercise without launching a real CLI in tests.
    nonisolated static func addArguments(for server: Server, executable: String?) -> [String]? {
        if server.isRemote {
            guard server.transport == "http", server.headers.allSatisfy({ $0.key.isEmpty }),
                  let url = server.url else { return nil }
            return ["mcp", "add", server.name, "--url", url]
        }
        guard let executable, !executable.isEmpty else { return nil }
        var args = ["mcp", "add", server.name]
        for variable in server.env where !variable.key.isEmpty {
            args += ["--env", "\(variable.key)=\(variable.value)"]
        }
        return args + ["--", executable] + server.args
    }

    // MARK: - Private

    nonisolated static func serverNames(in data: Data) -> [String]? {
        guard let servers = try? JSONDecoder().decode([ListedServer].self, from: data) else {
            return nil
        }
        return servers.map(\.name).sorted()
    }

    nonisolated static func enabledServers(in data: Data) -> [DisabledMCPServer]? {
        guard let servers = try? JSONDecoder().decode([ListedServer].self, from: data) else {
            return nil
        }
        let enabled = servers.filter(\.enabled)
        let snapshots = enabled.compactMap(\.disabledSnapshot)
        guard snapshots.count == enabled.count else { return nil }
        return snapshots.sorted { $0.name < $1.name }
    }

    // What one `codex mcp` read printed, or nil when the CLI could not be run or said no.
    private nonisolated static func output(_ codexPath: String, _ arguments: [String]) async -> String? {
        guard let result = try? await CommandRunner.run(executable: codexPath,
                                                        arguments: arguments,
                                                        environment: CLIRegistrar.environment,
                                                        timeout: .seconds(30)),
              result.succeeded else { return nil }
        return result.output
    }

    private func resolvedCommand(_ server: Server) -> String? {
        guard let command = server.command, !command.isEmpty else { return nil }
        return ProcessManager.resolve(command) ?? command
    }

    private func appEnv(_ server: Server) -> [String: String] {
        var env: [String: String] = [:]
        for variable in server.env where !variable.key.isEmpty { env[variable.key] = variable.value }
        return env
    }

    private func unsupportedMessage(_ server: Server) -> String {
        if server.isRemote, server.transport != "http" {
            return "Codex supports stdio and streamable HTTP MCP servers, not \(server.transport.uppercased())."
        }
        if server.isRemote, server.headers.contains(where: { !$0.key.isEmpty }) {
            return "Codex can register bearer-token authentication, but not custom HTTP headers."
        }
        return "\"\(server.name)\" needs a command or url to register."
    }

    private func runSteps(_ steps: [[String]], names: [String]) {
        registrar.run(steps, names: names) { [weak self] in
            guard let self else { return }
            refresh(Array(knownServers.values).sorted { $0.name < $1.name })
        }
    }
}

extension CodexCodeManager.Entry {
    init?(json output: String) {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let data = String(output[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let config = (root["config"] as? [String: Any]) ?? root
        let transport = (config["transport"] as? [String: Any]) ?? config
        command = transport["command"] as? String
        args = transport["args"] as? [String] ?? []
        env = transport["env"] as? [String: String] ?? [:]
        url = transport["url"] as? String
        type = command == nil ? transport["type"] as? String : nil
        enabled = (root["enabled"] as? Bool) ?? (config["enabled"] as? Bool) ?? true
    }
}
