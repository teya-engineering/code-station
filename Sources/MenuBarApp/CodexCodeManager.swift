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
        var enabled = true
    }

    private struct ListedServer: Decodable {
        let name: String
        let enabled: Bool
    }

    private struct DiscoveryFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var busy: Set<String> = []
    private(set) var bulkBusy = false
    private(set) var isRefreshing = false
    private(set) var errors: [String: String] = [:]
    let available: Bool

    private var knownServers: [String: Server] = [:]
    private var refreshID = UUID()

    init() {
        available = ProcessManager.resolve("codex") != nil
    }

    func isRegistered(_ name: String) -> Bool { entries[name] != nil }
    func isBusy(_ name: String) -> Bool { busy.contains(name) }

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

    // Codex exposes each registered server as JSON, which avoids needing to parse its
    // TOML file and keeps this compatible with config format changes.
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
        refreshEntry(codexPath, servers: servers, index: 0, entries: [:], refreshID: id)
    }

    func addCommand(for server: Server) -> String? {
        guard let args = Self.addArguments(for: server, executable: resolvedCommand(server)) else { return nil }
        return (["codex"] + args).map(quote).joined(separator: " ")
    }

    func add(_ server: Server) {
        guard let args = Self.addArguments(for: server, executable: resolvedCommand(server)) else {
            errors[server.name] = unsupportedMessage(server)
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
            errors[server.name] = unsupportedMessage(server)
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
    // that turns MCP off snapshots the enabled names and passes one config override per
    // server, using the CLI as the source of truth instead of parsing its TOML file.
    func enabledServerNames(in directory: String) async throws -> [String] {
        guard let codexPath = ProcessManager.resolve("codex") else {
            throw DiscoveryFailure(message: "Codex CLI not found on PATH.")
        }
        let searchPath = ProcessManager.searchPath

        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.arguments = ["mcp", "list", "--json"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            process.environment = environment

            let output = Pipe()
            let errors = Pipe()
            CommandRunner.closeOnExec(output, errors)
            process.standardOutput = output
            process.standardError = errors
            let outputReader = Task.detached {
                output.fileHandleForReading.readDataToEndOfFile()
            }
            let errorReader = Task.detached {
                errors.fileHandleForReading.readDataToEndOfFile()
            }

            do {
                try process.run()
            } catch {
                output.fileHandleForWriting.closeFile()
                errors.fileHandleForWriting.closeFile()
                throw DiscoveryFailure(message: "Could not start Codex: \(error.localizedDescription)")
            }
            process.waitUntilExit()
            let data = await outputReader.value
            let errorData = await errorReader.value

            guard process.terminationStatus == 0 else {
                let message = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw DiscoveryFailure(message: message.isEmpty
                    ? "Codex could not list its MCP servers."
                    : message)
            }
            guard let servers = try? JSONDecoder().decode([ListedServer].self, from: data) else {
                throw DiscoveryFailure(message: "Codex returned an unreadable MCP server list.")
            }
            return servers.filter(\.enabled).map(\.name)
        }.value
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

    private func refreshEntry(_ codexPath: String, servers: [Server], index: Int,
                              entries: [String: Entry], refreshID: UUID) {
        guard refreshID == self.refreshID else { return }
        guard index < servers.count else {
            self.entries = entries
            isRefreshing = false
            return
        }

        let server = servers[index]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["mcp", "get", server.name, "--json"]
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessManager.searchPath
        process.environment = env
        let pipe = Pipe()
        CommandRunner.closeOnExec(pipe)
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = Task.detached {
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let manager = self
        process.terminationHandler = { finished in
            Task { @MainActor in
                guard refreshID == manager.refreshID else { return }
                let output = await reader.value
                var nextEntries = entries
                if finished.terminationStatus == 0, let entry = Entry(json: output) {
                    nextEntries[server.name] = entry
                }
                manager.refreshEntry(codexPath, servers: servers, index: index + 1,
                                     entries: nextEntries, refreshID: refreshID)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            refreshEntry(codexPath, servers: servers, index: index + 1,
                         entries: entries, refreshID: refreshID)
        }
    }

    private func runSteps(_ steps: [[String]], names: [String]) {
        guard let codexPath = ProcessManager.resolve("codex") else {
            for name in names { errors[name] = "Codex CLI not found on PATH." }
            return
        }
        for name in names { busy.insert(name); errors[name] = nil }
        if names.count > 1 { bulkBusy = true }
        runStep(codexPath, steps, index: 0, names: names, failure: nil)
    }

    private func runStep(_ codexPath: String, _ steps: [[String]], index: Int,
                         names: [String], failure: String?) {
        guard index < steps.count else {
            for name in names { busy.remove(name) }
            bulkBusy = false
            if let failure { for name in names { errors[name] = failure } }
            refresh(Array(knownServers.values).sorted { $0.name < $1.name })
            return
        }

        let arguments = steps[index]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessManager.searchPath
        process.environment = env
        let pipe = Pipe()
        CommandRunner.closeOnExec(pipe)
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = Task.detached {
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let manager = self
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                let output = await reader.value
                var nextFailure = failure
                if code != 0, !arguments.contains("remove") {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    nextFailure = trimmed.isEmpty ? "Command failed (exit \(code))." : trimmed
                }
                manager.runStep(codexPath, steps, index: index + 1, names: names, failure: nextFailure)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            for name in names { busy.remove(name); errors[name] = error.localizedDescription }
            bulkBusy = false
        }
    }

    private func quote(_ string: String) -> String {
        if !string.isEmpty, string.allSatisfy({ $0.isLetter || $0.isNumber || "-_=./:@".contains($0) }) {
            return string
        }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\\\''") + "'"
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
        enabled = (root["enabled"] as? Bool) ?? (config["enabled"] as? Bool) ?? true
    }
}
