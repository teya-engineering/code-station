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
    private(set) var saveError: String?

    let configURL: URL
    private let files: PersistentFileClient
    private var hasUnsavedChanges = false

    init(configURL: URL? = nil, files: PersistentFileClient = .live) {
        self.configURL = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mcp/config.json")
        self.files = files
        load()
    }

    var selected: Server? { servers.first { $0.id == selectedID } }

    // MARK: - Loading

    func load() {
        // Edits still waiting to be written go out first, so typing and then reloading
        // does not read a stale file and lose them.
        guard loadError != nil || flushPendingSave() else { return }

        let data: Data?
        do {
            data = try files.readIfPresent(configURL)
        } catch {
            loadError = PersistentFile.loadMessage(for: configURL, error: error)
            return
        }

        // No file yet is a normal empty state; a present-but-unreadable file is not.
        guard let data else {
            saveTask?.cancel()
            saveTask = nil
            servers = []
            selectedID = nil
            lastModified = nil
            loadError = nil
            saveError = nil
            hasUnsavedChanges = false
            return
        }

        let file: ConfigFile
        do {
            file = try JSONDecoder().decode(ConfigFile.self, from: data)
        } catch {
            // Keep whatever we already have and refuse to overwrite the file.
            loadError = PersistentFile.decodeMessage(for: configURL, error: error)
            return
        }

        loadError = nil
        saveError = nil
        hasUnsavedChanges = false
        saveTask?.cancel()
        saveTask = nil
        servers = file.mcpServers
            .map { name, entry in server(named: name, from: entry) }
            .sorted { $0.name < $1.name }

        lastModified = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        if selected == nil { selectedID = servers.first?.id }
    }

    // A file written before servers carried a tag says nothing about the environment, so
    // one is read out of the Grafana naming convention instead. That guess is written
    // back on the next save, and after that the file is the only thing that decides.
    private func server(named name: String, from entry: ConfigFile.Entry,
                        environment: String? = nil) -> Server {
        Server(
            name: name,
            environmentTag: entry.environment
                ?? environment
                ?? Grafana.environment(from: name)
                ?? "",
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

    private var saveTask: Task<Void, Never>?

    // Typing in a key or value field is one write per keystroke, so those are coalesced
    // into one file write the way the request store does it.
    private func scheduleSave() {
        saveTask?.cancel()
        hasUnsavedChanges = true
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // Writes out an edit that is still waiting on its debounce, so readers of the file
    // and the app's last moments see what is on screen.
    @discardableResult
    func flushPendingSave() -> Bool {
        guard saveTask != nil || hasUnsavedChanges else { return true }
        return save()
    }

    @discardableResult
    func save() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        hasUnsavedChanges = true
        // Never overwrite a file we could not read in the first place.
        guard loadError == nil else {
            saveError = "Changes were not saved because the existing MCP config could not be loaded."
            return false
        }
        guard let data = Self.mcpConfigurationData(
            from: servers, allowing: servers.map(\.name)) else {
            saveError = "The MCP config could not be encoded."
            return false
        }

        do {
            try files.write(data, configURL)
            hasUnsavedChanges = false
            saveError = nil
            lastModified = Date()
            return true
        } catch {
            saveError = PersistentFile.saveMessage(for: configURL, error: error)
            return false
        }
    }

    // The environment tag is this app's own bookkeeping. It belongs in this app's file,
    // where an empty value has to be written out so a deliberate "every environment" is
    // not read back as a server nobody has tagged yet. It is left out of the copy handed
    // to an agent, which should only ever see the keys its own loader expects.
    nonisolated static func mcpConfigurationData(from servers: [Server],
                                                 allowing names: [String],
                                                 taggingEnvironments: Bool = true) -> Data? {
        let allowed = Set(names)
        var map: [String: ConfigFile.Entry] = [:]
        for server in servers where allowed.contains(server.name) {
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
                disabled: server.disabled ? true : nil,
                environment: taggingEnvironments ? server.environmentTag : nil
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(ConfigFile(mcpServers: map))
    }

    // The file is always written pretty-printed with clean URLs, so show it verbatim.
    var rawJSON: String {
        flushPendingSave()
        return (try? String(contentsOf: configURL, encoding: .utf8)) ?? "{\n  \"mcpServers\": {}\n}"
    }

    // MARK: - Mutations

    func upsertGrafana(preset: SiteDefaults.Grafana.Preset, token: String) {
        let name = preset.name
        let vars = [
            EnvVar(key: Grafana.urlKey, value: preset.url),
            EnvVar(key: Grafana.tokenKey, value: token),
        ]
        if let i = servers.firstIndex(where: { $0.name == name }) {
            servers[i].env = vars
            servers[i].environmentTag = preset.environment
        } else {
            servers.append(Server(name: name, environmentTag: preset.environment,
                                  command: Grafana.command, args: [],
                                  url: nil, type: nil, env: vars, headers: [], disabled: false))
            servers.sort { $0.name < $1.name }
        }
        selectedID = name
        save()
    }

    func setEnvironment(_ tag: String, for id: Server.ID) {
        guard let i = servers.firstIndex(where: { $0.id == id }),
              servers[i].environmentTag != tag else { return }
        servers[i].environmentTag = tag
        save()
    }

    // Import one or more servers pasted as JSON. Accepts either the full
    // { "mcpServers": { ... } } shape or a bare { "<name>": { ... } } map. The chosen
    // environment covers every server in the paste that does not name one itself.
    @discardableResult
    func importJSON(_ text: String, environment: String? = nil) throws -> Int {
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
            let built = server(named: name, from: entry, environment: environment)
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
                self.scheduleSave()
            })
    }
}
