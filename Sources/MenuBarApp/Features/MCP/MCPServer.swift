import Foundation

struct EnvVar: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String

    // A value is treated as a secret when its key looks like a credential.
    var isSecret: Bool { Self.isSecretKey(key) }

    static func isSecretKey(_ key: String) -> Bool {
        let k = key.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "KEY", "AUTH", "COOKIE", "BEARER"]
            .contains { k.contains($0) }
    }

    static func values(_ variables: [EnvVar]) -> [String: String] {
        variables.reduce(into: [:]) { values, variable in
            if !variable.key.isEmpty { values[variable.key] = variable.value }
        }
    }
}

struct Server: Identifiable, Equatable {
    var id: String { name }
    var name: String
    // Which deployment this server talks to, as one of the site file's environment names.
    // Empty means every one of them, which is where a server nobody has tagged belongs.
    var environmentTag: String = ""
    var command: String?
    var args: [String]
    var url: String?
    var type: String?          // "http" / "sse" for remote servers; nil for stdio
    var env: [EnvVar]
    var headers: [EnvVar]      // for remote servers
    var disabled: Bool

    // A remote server is reached over a URL rather than launched locally.
    var isRemote: Bool { command == nil && url != nil }

    var transport: String {
        if command != nil { return "stdio" }
        if let type, !type.isEmpty { return type }
        return url != nil ? "http" : "stdio"
    }

    func matchesRemote(command: String?, url: String?, type: String?, headers: [String: String]) -> Bool {
        isRemote && command == nil && self.url == url
            && transport == (type?.nilIfBlank ?? "http")
            && EnvVar.values(self.headers) == headers
    }

    var isGrafana: Bool {
        command == Grafana.command || name.hasPrefix(Grafana.namePrefix)
    }

    var deployEnvironment: String? { environmentTag.isEmpty ? nil : environmentTag }

    var description: String {
        if let preset = SiteDefaults.current.mcpPreset(named: name) {
            return "\(preset.label) MCP server."
        }
        return isRemote ? "Remote \(transport) MCP server." : "MCP server."
    }
}

struct ImportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// The on-disk shape: { "mcpServers": { "<name>": { command, args, env, ... } } }.
struct ConfigFile: Codable {
    var mcpServers: [String: Entry]

    struct Entry: Codable {
        var command: String?
        var args: [String]?
        var url: String?
        var type: String?
        var env: [String: String]?
        var headers: [String: String]?
        var disabled: Bool?
        var environment: String?
    }
}
