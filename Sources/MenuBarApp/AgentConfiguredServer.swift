import Foundation

// A server owned by an agent's configuration rather than Code Station's config file.
// Keeping it separate from Server prevents read-only discoveries from entering save,
// process, environment and bulk-sync paths that only apply to app-managed servers.
struct AgentConfiguredServer: Identifiable, Equatable {
    enum Source: String, Identifiable {
        case claudeCode
        case codex

        var id: Self { self }

        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            }
        }

        var shortTitle: String {
            switch self {
            case .claudeCode: "Claude"
            case .codex: "Codex"
            }
        }
    }

    struct Registration: Identifiable, Equatable {
        let source: Source
        var command: String?
        var args: [String]
        var env: [String: String]
        var url: String?
        var type: String?
        var headers: [String: String]
        var enabled: Bool

        var id: Source { source }

        var transport: String {
            if command != nil { return "stdio" }
            guard let type, !type.isEmpty else { return url == nil ? "stdio" : "http" }
            return type == "streamable_http" ? "http" : type
        }

        fileprivate var connection: Connection {
            Connection(command: command, args: args, env: env, url: url,
                       type: transport, headers: headers)
        }
    }

    fileprivate struct Connection: Equatable {
        var command: String?
        var args: [String]
        var env: [String: String]
        var url: String?
        var type: String
        var headers: [String: String]
    }

    let name: String
    let registrations: [Registration]

    var id: String { name }

    var hasDifferentConfigurations: Bool {
        guard let first = registrations.first?.connection else { return false }
        return registrations.dropFirst().contains { $0.connection != first }
    }

    static func outsideCodeStation(
        managedServers: [Server],
        claudeEntries: [String: ClaudeCodeManager.Entry],
        codexEntries: [String: CodexCodeManager.Entry]
    ) -> [Self] {
        let managedNames = Set(managedServers.map(\.name))
        let discoveredNames = Set(claudeEntries.keys)
            .union(codexEntries.keys)
            .subtracting(managedNames)

        return discoveredNames.sorted().map { name in
            var registrations: [Registration] = []
            if let entry = claudeEntries[name] {
                registrations.append(Registration(
                    source: .claudeCode,
                    command: entry.command,
                    args: entry.args,
                    env: entry.env,
                    url: entry.url,
                    type: entry.type,
                    headers: entry.headers,
                    enabled: true))
            }
            if let entry = codexEntries[name] {
                registrations.append(Registration(
                    source: .codex,
                    command: entry.command,
                    args: entry.args,
                    env: entry.env,
                    url: entry.url,
                    type: entry.type,
                    headers: [:],
                    enabled: entry.enabled))
            }
            return Self(name: name, registrations: registrations)
        }
    }
}
