import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ConfigStore {
    private(set) var servers: [Server] = []
    var selectedID: Server.ID?
    private(set) var lastModified: Date?
    // Set when the file exists but could not be parsed. While true, saving is blocked
    // so a file we can't read is never overwritten with an empty config.
    private(set) var loadError: String?

    let configURL: URL

    init() {
        configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mcp/config.json")
        load()
    }

    var selected: Server? { servers.first { $0.id == selectedID } }

    // MARK: - Loading

    func load() {
        // No file yet is a normal empty state; a present-but-unreadable file is not.
        guard let data = try? Data(contentsOf: configURL), !data.isEmpty else {
            servers = []
            loadError = nil
            return
        }
        guard let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            // Keep whatever we already have and refuse to overwrite the file.
            loadError = "The config file at \(configURL.path) could not be parsed. Fix it by hand; edits are disabled until it loads."
            return
        }
        loadError = nil
        servers = file.mcpServers
            .map { name, entry in server(named: name, from: entry) }
            .sorted { $0.name < $1.name }

        lastModified = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        if selected == nil { selectedID = servers.first?.id }
    }

    private func server(named name: String, from entry: ConfigFile.Entry) -> Server {
        Server(
            name: name,
            command: entry.command,
            args: entry.args ?? [],
            url: entry.url,
            type: entry.type,
            env: orderedEnv(entry.env ?? [:]),
            headers: orderedEnv(entry.headers ?? [:]),
            disabled: entry.disabled ?? false
        )
    }

    // Non-secret vars first (so GRAFANA_URL sits above the token), then alphabetical.
    private func orderedEnv(_ dict: [String: String]) -> [EnvVar] {
        dict.map { EnvVar(key: $0.key, value: $0.value) }
            .sorted { a, b in
                if a.isSecret != b.isSecret { return !a.isSecret }
                return a.key < b.key
            }
    }

    // MARK: - Saving

    private func save() {
        // Never overwrite a file we could not read in the first place.
        guard loadError == nil else { return }
        var map: [String: ConfigFile.Entry] = [:]
        for server in servers {
            var env: [String: String] = [:]
            for v in server.env where !v.key.isEmpty { env[v.key] = v.value }
            var headers: [String: String] = [:]
            for h in server.headers where !h.key.isEmpty { headers[h.key] = h.value }
            map[server.name] = ConfigFile.Entry(
                command: server.command,
                args: server.command != nil ? server.args : nil,
                url: server.url,
                type: server.type,
                env: env.isEmpty ? nil : env,
                headers: headers.isEmpty ? nil : headers,
                disabled: server.disabled ? true : nil
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(ConfigFile(mcpServers: map)) else { return }

        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
        lastModified = Date()
    }

    // The file is always written pretty-printed with clean URLs, so show it verbatim.
    var rawJSON: String {
        (try? String(contentsOf: configURL, encoding: .utf8)) ?? "{\n  \"mcpServers\": {}\n}"
    }

    // MARK: - Mutations

    func upsertGrafana(scope: Scope, env: DeployEnv, token: String) {
        let name = Grafana.name(scope, env)
        let vars = [
            EnvVar(key: Grafana.urlKey, value: Grafana.url(scope, env)),
            EnvVar(key: Grafana.tokenKey, value: token),
        ]
        if let i = servers.firstIndex(where: { $0.name == name }) {
            servers[i].env = vars
        } else {
            servers.append(Server(name: name, command: Grafana.command, args: [],
                                  url: nil, type: nil, env: vars, headers: [], disabled: false))
            servers.sort { $0.name < $1.name }
        }
        selectedID = name
        save()
    }

    // Import one or more servers pasted as JSON. Accepts either the full
    // { "mcpServers": { ... } } shape or a bare { "<name>": { ... } } map.
    @discardableResult
    func importJSON(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError("Paste a server JSON first.") }
        guard let root = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            throw ImportError("That is not valid JSON.")
        }
        guard var map = root as? [String: Any] else {
            throw ImportError("Expected a JSON object, like { \"my-server\": { ... } }.")
        }
        if map.count == 1, let inner = map["mcpServers"] as? [String: Any] { map = inner }
        guard !map.isEmpty else { throw ImportError("No servers found in the JSON.") }

        let entries: [String: ConfigFile.Entry]
        do {
            let data = try JSONSerialization.data(withJSONObject: map)
            entries = try JSONDecoder().decode([String: ConfigFile.Entry].self, from: data)
        } catch {
            throw ImportError("Each server must be an object with command/args/env or url. Check the shape and try again.")
        }
        for (name, entry) in entries where entry.command == nil && entry.url == nil {
            throw ImportError("\"\(name)\" needs a \"command\" (stdio) or a \"url\" (remote).")
        }

        for (name, entry) in entries {
            let built = server(named: name, from: entry)
            if let i = servers.firstIndex(where: { $0.name == name }) {
                servers[i] = built
            } else {
                servers.append(built)
            }
        }
        servers.sort { $0.name < $1.name }
        selectedID = entries.keys.sorted().first
        save()
        return entries.count
    }

    func remove(_ id: Server.ID) {
        servers.removeAll { $0.id == id }
        if selectedID == id { selectedID = servers.first?.id }
        save()
    }

    func addBlankVar(to id: Server.ID) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].env.append(EnvVar(key: "", value: ""))
        save()
    }

    func removeVar(_ envID: EnvVar.ID, from id: Server.ID) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].env.removeAll { $0.id == envID }
        save()
    }

    // MARK: - Bindings that persist on every edit

    func keyBinding(_ envID: EnvVar.ID, in id: Server.ID) -> Binding<String> {
        field(envID, in: id, get: { $0.key }, set: { $0.key = $1 })
    }

    func valueBinding(_ envID: EnvVar.ID, in id: Server.ID) -> Binding<String> {
        field(envID, in: id, get: { $0.value }, set: { $0.value = $1 })
    }

    private func field(_ envID: EnvVar.ID, in id: Server.ID,
                       get: @escaping (EnvVar) -> String,
                       set: @escaping (inout EnvVar, String) -> Void) -> Binding<String> {
        Binding(
            get: {
                guard let s = self.servers.first(where: { $0.id == id }),
                      let v = s.env.first(where: { $0.id == envID }) else { return "" }
                return get(v)
            },
            set: { newValue in
                guard let si = self.servers.firstIndex(where: { $0.id == id }),
                      let ei = self.servers[si].env.firstIndex(where: { $0.id == envID }) else { return }
                set(&self.servers[si].env[ei], newValue)
                self.save()
            })
    }
}
