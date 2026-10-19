import Foundation
import Observation
import SwiftUI
import CodeStationCore

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
        // Codex's own word for the sign-in: "unsupported", "not_logged_in",
        // "bearer_token" or "o_auth".
        var authStatus: String?
    }

    private struct ListedServer: Decodable {
        struct Transport: Decodable {
            let command: String?
            let url: String?
        }

        let name: String
        let enabled: Bool
        let transport: Transport?
        let authStatus: String?

        enum CodingKeys: String, CodingKey {
            case name, enabled, transport
            case authStatus = "auth_status"
        }

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
    private(set) var checkedAt: Date?
    let available: Bool
    let serverWork = AgentServerWork()

    var bulkBusy: Bool { registrar.bulkBusy }
    var errors: [String: String] { registrar.errors }

    private var knownServers: [String: Server] = [:]
    private var refreshID = UUID()

    init() {
        available = ExecutableSearch.resolve("codex") != nil
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
        guard let codexPath = ExecutableSearch.resolve("codex") else {
            entries = [:]
            isRefreshing = false
            return
        }
        let fallbackNames = servers.map(\.name)
        Task {
            let listed = await Self.output(codexPath, ["mcp", "list", "--json"])
            let states = listed.flatMap { Self.listedStates(in: Data($0.utf8)) }
            let names = states.map { $0.keys.sorted() } ?? fallbackNames
            var found: [String: Entry] = [:]
            for name in names {
                guard refreshID == id else { return }
                if let output = await Self.output(codexPath, ["mcp", "get", name, "--json"]),
                   var entry = Entry(json: output) {
                    if let state = states?[name] {
                        entry.enabled = state.enabled
                        entry.authStatus = state.authStatus
                    }
                    found[name] = entry
                }
            }
            guard refreshID == id else { return }
            entries = found
            isRefreshing = false
            checkedAt = .now
        }
    }

    // MARK: - Servers Codex owns

    func work(on name: String) -> AgentConfiguredServer.Work? {
        serverWork.work[name] ?? (isRefreshing ? .checking : nil)
    }

    nonisolated static func auth(fromStatus status: String?) -> AgentConfiguredServer.Auth {
        switch status {
        case "not_logged_in": .signedOut
        case "o_auth": .signedIn
        // A bearer token is set in the config, so there is nothing to sign in to.
        default: .none
        }
    }

    func signIn(_ name: String, servers: [Server]) {
        serverWork.perform(.signingIn, on: name) {
            try await AgentServerWork.output("codex", ["mcp", "login", name], timeout: .seconds(300))
        } then: { [weak self] _ in
            self?.refresh(servers)
        }
    }

    func signOut(_ name: String, servers: [Server]) {
        serverWork.perform(.checking, on: name) {
            try await AgentServerWork.output("codex", ["mcp", "logout", name], timeout: .seconds(30))
        } then: { [weak self] _ in
            self?.refresh(servers)
        }
    }

    // `codex mcp` has no command for this, so it is the one place the app writes to
    // Codex's config itself. The write touches a single key in the server's own table
    // and leaves every other line as it was.
    func setEnabled(_ enabled: Bool, for name: String, servers: [Server]) {
        let configURL = Self.configURL
        entries[name]?.enabled = enabled
        serverWork.perform(enabled ? .turningOn : .turningOff, on: name) {
            try Self.writeEnabled(enabled, for: name, in: configURL)
        } then: { [weak self] _ in
            self?.refresh(servers)
        } otherwise: { [weak self] in
            // The switch moved before the write, so put it back where Codex has it.
            self?.refresh(servers)
        }
    }

    nonisolated static var configURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("config.toml")
    }

    // The link is followed so a config kept in a dotfiles folder stays a link.
    private nonisolated static func writeEnabled(_ enabled: Bool, for name: String,
                                                 in configURL: URL) throws {
        let target = configURL.resolvingSymlinksInPath()
        guard let toml = try? String(contentsOf: target, encoding: .utf8) else {
            throw AgentServerWork.Failure(message: "Could not read \(configURL.path.abbreviatedPath).")
        }
        guard let updated = settingEnabled(enabled, forServer: name, in: toml) else {
            throw AgentServerWork.Failure(
                message: "\(name) is not in \(configURL.path.abbreviatedPath). It may come from a Codex plugin, which Codex switches on its own.")
        }
        try updated.write(to: target, atomically: true, encoding: .utf8)
    }

    // The server's table with its `enabled` key set, or nil when the file has no table
    // of its own for the server. Turning a server on drops the key, since on is what
    // Codex assumes when it is missing.
    nonisolated static func settingEnabled(_ enabled: Bool, forServer name: String,
                                           in toml: String) -> String? {
        var lines = toml.components(separatedBy: "\n")
        let headers = ["[mcp_servers.\(name)]", "[mcp_servers.\"\(name)\"]",
                       "[mcp_servers.'\(name)']"]
        guard let header = lines.firstIndex(where: { line in
            let bare = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "")
            return headers.contains(bare.components(separatedBy: "#")[0])
        }) else { return nil }
        let end = lines[(header + 1)...].firstIndex {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        } ?? lines.endIndex
        let existing = lines[(header + 1)..<end].firstIndex {
            let key = $0.trimmingCharacters(in: .whitespaces)
            return key.hasPrefix("enabled") && key.dropFirst("enabled".count)
                .trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
        switch (existing, enabled) {
        case (let index?, true): lines.remove(at: index)
        case (let index?, false): lines[index] = "enabled = false"
        case (nil, true): break
        case (nil, false): lines.insert("enabled = false", at: header + 1)
        }
        return lines.joined(separator: "\n")
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
        runSteps([Self.removeArguments(name)], names: [name])
    }

    // Remove then add so a changed command, URL or token replaces the old registration.
    func reregister(_ server: Server) {
        guard let args = Self.addArguments(for: server, executable: resolvedCommand(server)) else {
            registrar.errors[server.name] = unsupportedMessage(server)
            return
        }
        knownServers[server.name] = server
        runSteps([Self.removeArguments(server.name), args], names: [server.name])
    }

    func syncAll(_ servers: [Server]) {
        knownServers = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        let plan = CLIRegistrar.plan(
            serversNeedingSync(servers),
            add: { Self.addArguments(for: $0, executable: resolvedCommand($0)) },
            remove: Self.removeArguments,
            isRegistered: isRegistered)
        guard !plan.steps.isEmpty else { return }
        runSteps(plan.steps, names: plan.names)
    }

    // Codex has no single flag that suppresses every configured MCP server. A diagnosis
    // that turns MCP off snapshots the enabled servers and their transport kinds, using
    // the CLI as the source of truth instead of parsing its TOML file.
    func enabledServers(in directory: String) async throws -> [DisabledMCPServer] {
        guard let codexPath = ExecutableSearch.resolve("codex") else {
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
    nonisolated static func removeArguments(_ name: String) -> [String] { ["mcp", "remove", name] }

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
        listedStates(in: data)?.keys.sorted()
    }

    // `mcp get` leaves out whether the server is signed in, so that comes from the list.
    nonisolated static func listedStates(in data: Data)
        -> [String: (enabled: Bool, authStatus: String?)]? {
        guard let servers = try? JSONDecoder().decode([ListedServer].self, from: data) else {
            return nil
        }
        return Dictionary(servers.map { ($0.name, (enabled: $0.enabled, authStatus: $0.authStatus)) },
                          uniquingKeysWith: { first, _ in first })
    }

    nonisolated static func enabledServers(in data: Data) -> [DisabledMCPServer]? {
        CodexMCPListing.enabledServers(in: data)
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
        return ExecutableSearch.resolve(command) ?? command
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
