import Foundation

// The two axes that identify a Grafana instance.
enum Scope: String, CaseIterable, Identifiable, Codable {
    case platform, cde, edge, shared
    var id: String { rawValue }
}

enum DeployEnv: String, CaseIterable, Identifiable, Codable {
    case dev, prd, shared
    var id: String { rawValue }
}

// Everything Grafana-specific lives here so the naming and URL scheme have one home.
enum Grafana {
    static let command = "mcp-grafana"
    static let urlKey = "GRAFANA_URL"
    static let tokenKey = "GRAFANA_SERVICE_ACCOUNT_TOKEN"

    static func name(_ scope: Scope, _ env: DeployEnv) -> String {
        "grafana-\(scope.rawValue)-\(env.rawValue)"
    }

    static func url(_ scope: Scope, _ env: DeployEnv) -> String {
        // The shared account holds one Grafana with no dev/prd split, so its host
        // segment is just "shared" rather than the usual "<scope>-<env>" pair.
        let account = scope == .shared && env == .shared ? "shared" : "\(scope.rawValue)-\(env.rawValue)"
        return "https://grafana.\(account).example.com"
    }

    // Pull the scope/env back out of a "grafana-<scope>-<env>" name.
    static func parts(from name: String) -> (Scope, DeployEnv)? {
        let bits = name.split(separator: "-")
        guard bits.count == 3, bits[0] == "grafana",
              let scope = Scope(rawValue: String(bits[1])),
              let env = DeployEnv(rawValue: String(bits[2])) else { return nil }
        return (scope, env)
    }
}

struct EnvVar: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String

    // A value is treated as a secret when its key looks like a credential.
    var isSecret: Bool {
        let k = key.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "APIKEY", "API_KEY", "KEY", "AUTH", "COOKIE", "BEARER"]
            .contains { k.contains($0) }
    }
}

struct Server: Identifiable, Equatable {
    var id: String { name }
    var name: String
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

    var isGrafana: Bool { command == Grafana.command || name.hasPrefix("grafana-") }

    var deployEnvironment: DeployEnv? { Grafana.parts(from: name)?.1 }

    var description: String {
        if let (scope, env) = Grafana.parts(from: name) {
            return "Grafana MCP server for the \(scope.rawValue) scope in \(env.rawValue)."
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
    }
}
