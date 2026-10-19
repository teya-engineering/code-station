import Foundation

// The MCP servers the person has set up, in the shared file the GUI's MCP settings write.
// A session limited to some of them hands its agent a copy holding only those. The GUI
// builds that copy from its open settings; a front end without them reads the file.
public enum MCPConfigFile {
    public static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mcp/config.json")
    }

    // Only the servers named, each without the app's own environment tag, which no
    // agent's loader expects. No file is no servers. Nil when the file cannot be read,
    // so the turn fails and says so rather than running with the wrong servers.
    public static func filtered(at url: URL, allowing names: [String]) -> Data? {
        var servers: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let all = object["mcpServers"] as? [String: Any] else { return nil }
            for name in Set(names) {
                guard var entry = all[name] as? [String: Any] else { continue }
                entry["environment"] = nil
                servers[name] = entry
            }
        }
        return try? JSONSerialization.data(withJSONObject: ["mcpServers": servers],
                                           options: [.prettyPrinted, .sortedKeys,
                                                     .withoutEscapingSlashes])
    }

    // One server in the file: its name and the environment the app tagged it with.
    public struct Server: Codable, Equatable, Sendable {
        public var name: String
        public var environment: String?

        public init(name: String, environment: String? = nil) {
            self.name = name
            self.environment = environment
        }
    }

    // Every server the file holds, by name. No file, or one that cannot be read, holds none.
    public static func servers(at url: URL) -> [Server] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = object["mcpServers"] as? [String: Any] else { return [] }
        return all.keys.sorted().map { name in
            let tag = (all[name] as? [String: Any])?["environment"] as? String
            return Server(name: name, environment: tag?.isEmpty == false ? tag : nil)
        }
    }
}
