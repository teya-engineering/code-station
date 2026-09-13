import Foundation
import Observation
import SwiftUI

// Keeps the app's MCP definitions registered with the Copilot CLI. The CLI owns
// ~/.copilot/mcp-config.json, so this manager only reads or changes it through
// `copilot mcp` commands, which also give the registry back as JSON.
@MainActor
@Observable
final class CopilotCodeManager {
    struct Entry: Equatable {
        var command: String?
        var args: [String] = []
        var env: [String: String] = [:]
        var url: String?
        var type: String?
        var headers: [String: String] = [:]
        var enabled = true
    }

    private struct DiscoveryFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private let registrar = CLIRegistrar(command: "copilot",
                                         notFoundMessage: "Copilot CLI not found on PATH.")
    private(set) var entries: [String: Entry] = [:]
    private(set) var isRefreshing = false
    let available: Bool

    var bulkBusy: Bool { registrar.bulkBusy }
    var errors: [String: String] { registrar.errors }

    private var knownServers: [String: Server] = [:]
    private var refreshID = UUID()

    init() {
        available = ProcessManager.resolve("copilot") != nil
    }

    func isRegistered(_ name: String) -> Bool { entries[name] != nil }
    func isBusy(_ name: String) -> Bool { registrar.isBusy(name) }

    // Copilot takes local servers and remote ones over streamable HTTP or SSE, with
    // headers on either remote kind.
    func supports(_ server: Server) -> Bool {
        if server.isRemote {
            return ["http", "sse"].contains(server.transport) && server.url?.isEmpty == false
        }
        return server.command?.isEmpty == false
    }

    // True when the server exists in Copilot but its command, args, env, URL or headers
    // differ from the definition held by this app.
    func isOutOfSync(_ server: Server) -> Bool {
        guard let entry = entries[server.name], supports(server) else { return false }
        if server.isRemote {
            return entry.url != server.url || entry.headers != appHeaders(server)
        }
        if entry.command != resolvedCommand(server) { return true }
        if entry.args != server.args { return true }
        return entry.env != appEnv(server)
    }

    func serversNeedingSync(_ servers: [Server]) -> [Server] {
        servers.filter { supports($0) && (!isRegistered($0.name) || isOutOfSync($0)) }
    }

    // A refresh started while another is still asking the CLI wins: the older answer is
    // dropped when it arrives.
    func refresh(_ servers: [Server]) {
        knownServers = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        let id = UUID()
        refreshID = id
        isRefreshing = true
        guard let copilotPath = ProcessManager.resolve("copilot") else {
            entries = [:]
            isRefreshing = false
            return
        }
        Task {
            let listed = await Self.output(copilotPath, ["mcp", "list", "--json"])
            guard refreshID == id else { return }
            entries = listed.flatMap { Self.entries(in: Data($0.utf8)) } ?? [:]
            isRefreshing = false
        }
    }

    func addCommand(for server: Server) -> String? {
        guard let args = Self.addArguments(for: server, executable: resolvedCommand(server)) else { return nil }
        return (["copilot"] + args).map(\.shellQuoted).joined(separator: " ")
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

    // Remove then add so a changed command, URL or header replaces the old registration.
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

    // Copilot has no single flag that suppresses every configured MCP server, only one
    // per name. A diagnosis that hides servers therefore needs to know which ones are
    // switched on, read from the CLI in the folder the diagnosis will run in so the
    // workspace's own servers are counted too.
    func enabledServers(in directory: String) async throws -> [DisabledMCPServer] {
        guard let copilotPath = ProcessManager.resolve("copilot") else {
            throw DiscoveryFailure(message: "Copilot CLI not found on PATH.")
        }
        let result: CommandRunner.Output
        do {
            result = try await CommandRunner.run(executable: copilotPath,
                                                 arguments: ["mcp", "list", "--json"],
                                                 currentDirectory: URL(fileURLWithPath: directory),
                                                 environment: CLIRegistrar.environment,
                                                 timeout: .seconds(30))
        } catch {
            throw DiscoveryFailure(message: "Could not run Copilot: \(error.localizedDescription)")
        }
        guard result.succeeded else {
            let message = result.errorOutput.trimmed
            throw DiscoveryFailure(message: message.isEmpty
                ? "Copilot could not list its MCP servers."
                : message)
        }
        guard let entries = Self.entries(in: Data(result.output.utf8)) else {
            throw DiscoveryFailure(message: "Copilot returned an MCP server list the app could not read.")
        }
        return entries.filter { $0.value.enabled }.map { name, entry in
            DisabledMCPServer(name: name,
                              transport: entry.command != nil ? .stdio : .streamableHTTP)
        }.sorted { $0.name < $1.name }
    }

    // Kept separate from process handling so the supported Copilot CLI forms stay easy
    // to exercise without launching a real CLI in tests.
    nonisolated static func addArguments(for server: Server, executable: String?) -> [String]? {
        if server.isRemote {
            guard ["http", "sse"].contains(server.transport),
                  let url = server.url, !url.isEmpty else { return nil }
            var args = ["mcp", "add", server.name, url]
            if server.transport == "sse" { args += ["--transport", "sse"] }
            for header in server.headers where !header.key.isEmpty {
                args += ["--header", "\(header.key): \(header.value)"]
            }
            return args
        }
        guard let executable, !executable.isEmpty else { return nil }
        var args = ["mcp", "add", server.name]
        for variable in server.env where !variable.key.isEmpty {
            args += ["--env", "\(variable.key)=\(variable.value)"]
        }
        return args + ["--", executable] + server.args
    }

    // What `copilot mcp list --json` printed: every server by name, local ones with a
    // command and remote ones with a URL.
    nonisolated static func entries(in data: Data) -> [String: Entry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return nil }
        var entries: [String: Entry] = [:]
        for (name, value) in servers {
            guard let raw = value as? [String: Any] else { continue }
            var entry = Entry()
            entry.command = raw["command"] as? String
            entry.args = raw["args"] as? [String] ?? []
            entry.env = raw["env"] as? [String: String] ?? [:]
            entry.url = raw["url"] as? String
            entry.headers = raw["headers"] as? [String: String] ?? [:]
            entry.enabled = raw["enabled"] as? Bool ?? true
            // "local" is Copilot's word for a command it starts itself; the app calls
            // that stdio and reads a missing type as one, so it is not carried over.
            if let type = raw["type"] as? String, type != "local" { entry.type = type }
            entries[name] = entry
        }
        return entries
    }

    // MARK: - Private

    private nonisolated static func output(_ copilotPath: String, _ arguments: [String]) async -> String? {
        guard let result = try? await CommandRunner.run(executable: copilotPath,
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

    private func appHeaders(_ server: Server) -> [String: String] {
        var headers: [String: String] = [:]
        for header in server.headers where !header.key.isEmpty { headers[header.key] = header.value }
        return headers
    }

    private func unsupportedMessage(_ server: Server) -> String {
        if server.isRemote, !["http", "sse"].contains(server.transport) {
            return "Copilot supports streamable HTTP and SSE MCP servers, not \(server.transport.uppercased())."
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
