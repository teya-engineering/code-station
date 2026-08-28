import CryptoKit
import Foundation

// The parts of the app that belong to one organisation rather than to the app itself:
// the identity provider its APIs sign in against, the calls worth starting from, the
// deployments it runs, the MCP servers it offers, the skills marketplace its agents install
// from, and the commands worth having on hand. Keeping them in a file rather than in code
// means each team points the same build at its own setup, and a build with no file at all
// still runs with every one of them empty.
//
// The current configuration is read from the first of these that can be parsed:
//
//   1. $CODE_STATION_SITE_DEFAULTS
//   2. A saved external configuration path
//   3. <application support>/site-defaults.json
//   4. site-defaults.json inside the app bundle
//
// Once the user changes or resets any part, the application-support file is updated and
// is also what the settings screen exports. `site-defaults.example.json` shows the shape,
// and the build script can fold a chosen settings file into the bundle so a team can hand
// out an app that is already set up.
struct SiteDefaults: Codable, Sendable, Equatable {
    var dispatch: DispatchConfig? = nil
    var environments: [Environment]? = nil
    var mcp: MCP? = nil
    var skills: Skills? = nil
    var shortcuts: [Shortcut]? = nil

    // Not part of the file. These tell the UI where the values came from and whether a
    // higher-priority location failed, so a fallback never looks like that file worked.
    var loadFailure: String? = nil
    var sourceURL: URL? = nil

    private enum CodingKeys: String, CodingKey {
        case dispatch, environments, mcp, skills, shortcuts
        case legacyGrafana = "grafana"
        case legacyHTTPClient = "postman"
    }

    init(dispatch: DispatchConfig? = nil,
         environments: [Environment]? = nil,
         mcp: MCP? = nil,
         skills: Skills? = nil,
         shortcuts: [Shortcut]? = nil,
         loadFailure: String? = nil,
         sourceURL: URL? = nil) {
        self.dispatch = dispatch
        self.environments = environments
        self.mcp = mcp
        self.skills = skills
        self.shortcuts = shortcuts
        self.loadFailure = loadFailure
        self.sourceURL = sourceURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let dispatch = try values.decodeIfPresent(DispatchConfig.self, forKey: .dispatch)
        let legacy = try values.decodeIfPresent(DispatchConfig.self, forKey: .legacyHTTPClient)
        self.dispatch = dispatch ?? legacy
        environments = try values.decodeIfPresent([Environment].self, forKey: .environments)
        // Earlier site files kept two Dispatch-only aliases instead of using the shared
        // environment list. A file with only that shape is upgraded in memory so every
        // feature sees the same deployments.
        if environments == nil, let legacyNames = self.dispatch?.environments {
            let staging = legacyNames.staging ?? "dev"
            let production = legacyNames.production ?? "prd"
            environments = [Environment(name: staging, title: "Staging")]
            if production != staging {
                environments?.append(Environment(name: production,
                                                 title: "Production",
                                                 danger: true))
            }
        }
        mcp = try values.decodeIfPresent(MCP.self, forKey: .mcp)
        if mcp == nil,
           let grafana = try values.decodeIfPresent(LegacyGrafana.self,
                                                    forKey: .legacyGrafana) {
            mcp = MCP(presets: grafana.presets?.map { preset in
                MCP.Preset(
                    name: preset.name,
                    title: "Grafana \(preset.scope) \(preset.environment)",
                    serverType: "Grafana",
                    environment: preset.environment,
                    command: Grafana.command,
                    env: [
                        .init(key: Grafana.urlKey, value: preset.url),
                        .init(key: Grafana.tokenKey, value: ""),
                    ])
            })
        }
        skills = try values.decodeIfPresent(Skills.self, forKey: .skills)
        shortcuts = try values.decodeIfPresent([Shortcut].self, forKey: .shortcuts)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(dispatch, forKey: .dispatch)
        try values.encodeIfPresent(environments, forKey: .environments)
        try values.encodeIfPresent(mcp, forKey: .mcp)
        try values.encodeIfPresent(skills, forKey: .skills)
        try values.encodeIfPresent(shortcuts, forKey: .shortcuts)
    }

    // The deployments an organisation runs. Every MCP server is tagged with one of these,
    // and a troubleshooting session offers a server only for the environment it is tagged
    // with, so a dev diagnosis cannot reach into production by accident.
    struct Environment: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var title: String?
        var danger: Bool?

        init(name: String, title: String? = nil, danger: Bool? = nil) {
            self.name = name
            self.title = title
            self.danger = danger
        }

        var id: String { name }

        // What the pills show. A file that names no title reads well enough capitalised.
        var label: String { title ?? name.capitalized }

        // Whether a session here is told to keep every check read-only. Set on anything
        // a mistake would be felt in, which is usually production but need not only be.
        var isDangerous: Bool { danger ?? false }
    }

    struct DispatchConfig: Codable, Sendable, Equatable {
        var oauth: OAuth?
        var requests: [Request]?
        // Read only for migrating site and OAuth settings written before Dispatch used
        // the shared top-level environment list. New configuration files omit this field.
        var environments: Environments?

        init(oauth: OAuth? = nil,
             requests: [Request]? = nil,
             environments: Environments? = nil) {
            self.oauth = oauth
            self.requests = requests
            self.environments = environments
        }

        // The two aliases used by older configuration files.
        struct Environments: Codable, Sendable, Equatable {
            var staging: String?
            var production: String?

            init(staging: String? = nil, production: String? = nil) {
                self.staging = staging
                self.production = production
            }
        }

        // Only the fields that identify a provider. The client secret and the tokens are
        // the user's own and live in the Keychain, so they are never written here.
        struct OAuth: Codable, Sendable, Equatable {
            var grant: GrantType?
            var authURL: String?
            var tokenURL: String?
            var clientID: String?
            var scope: String?
            var callbackURL: String?

            init(grant: GrantType? = nil,
                 authURL: String? = nil,
                 tokenURL: String? = nil,
                 clientID: String? = nil,
                 scope: String? = nil,
                 callbackURL: String? = nil) {
                self.grant = grant
                self.authURL = authURL
                self.tokenURL = tokenURL
                self.clientID = clientID
                self.scope = scope
                self.callbackURL = callbackURL
            }
        }

        struct Request: Codable, Sendable, Equatable {
            var name: String
            var method: HTTPMethod?
            var url: String

            init(name: String, method: HTTPMethod? = nil, url: String) {
                self.name = name
                self.method = method
                self.url = url
            }
        }
    }

    struct MCP: Codable, Sendable, Equatable {
        var presets: [Preset]?

        init(presets: [Preset]? = nil) {
            self.presets = presets
        }

        struct Preset: Codable, Sendable, Equatable, Identifiable {
            var name: String
            var title: String?
            var serverType: String?
            var environment: String?
            var command: String?
            var args: [String]?
            var url: String?
            var type: String?
            var env: [Value]?
            var headers: [Value]?

            init(name: String,
                 title: String? = nil,
                 serverType: String? = nil,
                 environment: String? = nil,
                 command: String? = nil,
                 args: [String]? = nil,
                 url: String? = nil,
                 type: String? = nil,
                 env: [Value]? = nil,
                 headers: [Value]? = nil) {
                self.name = name
                self.title = title
                self.serverType = serverType
                self.environment = environment
                self.command = command
                self.args = args
                self.url = url
                self.type = type
                self.env = env
                self.headers = headers
            }

            private enum CodingKeys: String, CodingKey {
                case name, title, serverType, environment, command, args, url, type, env, headers
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                name = try values.decode(String.self, forKey: .name)
                title = try values.decodeIfPresent(String.self, forKey: .title)
                serverType = try values.decodeIfPresent(String.self, forKey: .serverType)
                environment = try values.decodeIfPresent(String.self, forKey: .environment)
                command = try values.decodeIfPresent(String.self, forKey: .command)
                args = try values.decodeIfPresent([String].self, forKey: .args)
                url = try values.decodeIfPresent(String.self, forKey: .url)
                type = try values.decodeIfPresent(String.self, forKey: .type)
                env = try Self.decodeValues(.env, from: values)
                headers = try Self.decodeValues(.headers, from: values)

                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      hasConnection else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .name,
                        in: values,
                        debugDescription: "An MCP preset needs a name and either a command or URL.")
                }
            }

            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(name, forKey: .name)
                try values.encodeIfPresent(title, forKey: .title)
                try values.encodeIfPresent(serverType, forKey: .serverType)
                try values.encodeIfPresent(environment, forKey: .environment)
                try values.encodeIfPresent(command, forKey: .command)
                try values.encodeIfPresent(args, forKey: .args)
                try values.encodeIfPresent(url, forKey: .url)
                try values.encodeIfPresent(type, forKey: .type)
                try Self.encodeValues(env, forKey: .env, to: &values)
                try Self.encodeValues(headers, forKey: .headers, to: &values)
            }

            var id: String { name }
            var label: String { title ?? name }
            var environmentTag: String { environment ?? "" }
            var isRemote: Bool { !hasCommand && hasURL }
            var hasConnection: Bool { hasCommand != hasURL }

            private var hasCommand: Bool {
                command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }

            private var hasURL: Bool {
                url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }

            private static func decodeValues(
                _ key: CodingKeys,
                from values: KeyedDecodingContainer<CodingKeys>
            ) throws -> [Value]? {
                guard let map = try values.decodeIfPresent([String: String].self, forKey: key)
                else { return nil }
                return map.map { Value(key: $0.key, value: $0.value) }
                    .sorted { $0.key < $1.key }
            }

            private static func encodeValues(
                _ entries: [Value]?,
                forKey key: CodingKeys,
                to values: inout KeyedEncodingContainer<CodingKeys>
            ) throws {
                guard let entries else { return }
                try values.encode(Dictionary(uniqueKeysWithValues: entries.map {
                    ($0.key, $0.value)
                }), forKey: key)
            }
        }

        struct PresetGroup: Sendable, Equatable, Identifiable {
            let serverType: String?
            var presets: [Preset]

            var id: String { serverType ?? "" }
            var addTitle: String {
                guard let serverType else { return "Add from preset" }
                return "Add \(serverType) MCP server"
            }
        }

        struct Value: Sendable, Equatable, Identifiable {
            var key: String
            var value: String

            init(key: String, value: String) {
                self.key = key
                self.value = value
            }

            var id: String { key }
        }
    }

    private struct LegacyGrafana: Decodable {
        var presets: [Preset]?

        struct Preset: Decodable {
            var scope: String
            var environment: String
            var url: String

            var name: String { "grafana-\(scope)-\(environment)" }
        }
    }

    struct Skills: Codable, Sendable, Equatable {
        var name: String
        var marketplace: String
        var repository: String
        var sourceKind: SkillMarketplaceConfiguration.SourceKind?

        init(name: String,
             marketplace: String,
             repository: String,
             sourceKind: SkillMarketplaceConfiguration.SourceKind? = nil) {
            self.name = name
            self.marketplace = marketplace
            self.repository = repository
            self.sourceKind = sourceKind
        }
    }

    // A command a fresh install starts with, for the ones a whole team runs often enough
    // to be worth handing over rather than typing out.
    struct Shortcut: Codable, Sendable, Equatable {
        var name: String
        var command: String

        init(name: String, command: String) {
            self.name = name
            self.command = command
        }
    }
}

extension SiteDefaults {
    private static let storage = CurrentStorage(load())

    static var current: SiteDefaults { storage.read() }

    @discardableResult
    static func reload() -> SiteDefaults {
        let defaults = load()
        storage.write(defaults)
        return defaults
    }

    @discardableResult
    static func setCurrent(_ defaults: SiteDefaults, sourceURL: URL) -> SiteDefaults {
        var current = defaults
        current.loadFailure = nil
        current.sourceURL = sourceURL
        storage.write(current)
        return current
    }

    static func decode(_ data: Data, from url: URL) throws -> SiteDefaults {
        var defaults = try JSONDecoder().decode(SiteDefaults.self, from: data)
        defaults.sourceURL = url
        return defaults
    }

    static func load(_ urls: [URL] = searchPaths) -> SiteDefaults {
        var failures: [String] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                failures.append("\(url.path) could not be read: \(error.localizedDescription)")
                continue
            }

            do {
                let defaults = try decode(data, from: url)
                if !failures.isEmpty {
                    var defaults = defaults
                    failures.append("The app loaded \(url.path) instead.")
                    defaults.loadFailure = report(failures)
                    return defaults
                }
                return defaults
            } catch {
                failures.append("\(url.path) could not be parsed: \(error.localizedDescription)")
            }
        }

        guard !failures.isEmpty else { return SiteDefaults() }
        failures.append("No fallback configuration was available, so the app started without site defaults.")
        return SiteDefaults(loadFailure: report(failures))
    }

    private static func report(_ failures: [String]) -> String {
        let message = failures.joined(separator: "\n")
        FileHandle.standardError.write(Data("site defaults: \(message)\n".utf8))
        return message
    }

    static var environmentURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        return (environment["CODE_STATION_SITE_DEFAULTS"]
            ?? environment["CONDUCTOR_SITE_DEFAULTS"]).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    static var searchPaths: [URL] {
        searchPaths(environmentURL: environmentURL,
                    savedURL: Preferences.siteDefaultsURL(),
                    bundledURL: bundledURL)
    }

    static func searchPaths(environmentURL: URL?, savedURL: URL?, bundledURL: URL?) -> [URL] {
        let candidates = [
            environmentURL,
            savedURL,
            AppPaths.support.appendingPathComponent(fileName),
            bundledURL
        ].compactMap { $0?.standardizedFileURL }

        return candidates.reduce(into: []) { paths, url in
            if !paths.contains(where: { $0.path == url.path }) {
                paths.append(url)
            }
        }
    }

    static var bundledURL: URL? {
        AppResources.bundle.url(forResource: "site-defaults", withExtension: "json")
    }

    static let fileName = "site-defaults.json"

    private final class CurrentStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SiteDefaults

        init(_ value: SiteDefaults) {
            self.value = value
        }

        func read() -> SiteDefaults {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func write(_ value: SiteDefaults) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
    }

    // MARK: - What the rest of the app reads

    // The provider every API environment starts from. Everything else about the setup,
    // including the callback, keeps the app's own defaults.
    var dispatchOAuth: OAuthConfig {
        guard let oauth = dispatch?.oauth else { return OAuthConfig() }
        var config = OAuthConfig()
        if let grant = oauth.grant { config.grant = grant }
        if let authURL = oauth.authURL { config.authURL = authURL }
        if let tokenURL = oauth.tokenURL { config.tokenURL = tokenURL }
        if let clientID = oauth.clientID { config.clientID = clientID }
        if let scope = oauth.scope { config.scope = scope }
        if let callbackURL = oauth.callbackURL { config.callbackURL = callbackURL }
        return config
    }

    var dispatchRequests: [SavedRequest] {
        (dispatch?.requests ?? []).map {
            let method = $0.method ?? .get
            return SavedRequest(
                id: Self.identity(of: "dispatch\n\($0.name)\n\(method.rawValue)\n\($0.url)"),
                name: $0.name,
                method: method,
                url: $0.url
            )
        }
    }

    // Used only to map OAuth settings saved by versions with fixed staging and production
    // slots onto the matching configured environments.
    var dispatchEnvValues: (staging: String, production: String) {
        let named = dispatch?.environments
        return (named?.staging ?? "dev", named?.production ?? "prd")
    }

    // The shortcuts a first run starts with. The file names no IDs, so they are derived
    // from what a shortcut is: the same entry keeps the same identity across launches,
    // which is what keeps a running command attached to its row.
    var commandShortcuts: [CommandShortcut] {
        (shortcuts ?? []).map {
            CommandShortcut(id: Self.identity(of: "\($0.name)\n\($0.command)"),
                            name: $0.name,
                            command: $0.command)
        }
    }

    private static func identity(of text: String) -> UUID {
        var digest = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        // Shape the digest into a version 5 UUID, so it reads as a name-based one.
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }

    // What a file turned out to hold, for the two places that offer one before and after
    // it is installed.
    var summary: String {
        let named = environments?.count ?? 0
        let requests = dispatchRequests.count
        let presets = mcpPresets.count
        let commands = commandShortcuts.count
        let marketplace = skills == nil ? "no skills marketplace" : "a skills marketplace"
        return "\(named) environment\(named == 1 ? "" : "s"), "
            + "\(requests) starter request\(requests == 1 ? "" : "s"), "
            + "\(presets) MCP preset\(presets == 1 ? "" : "s"), "
            + "\(commands) shortcut\(commands == 1 ? "" : "s"), and \(marketplace)."
    }

    // The environments to offer. A file that names none leaves the app on the two most
    // deployments have, so there is always something to tag a server with and pick from.
    static let ownEnvironments = [
        Environment(name: "staging", title: "Staging"),
        Environment(name: "production", title: "Production", danger: true),
    ]

    var deployEnvironments: [Environment] {
        let named = (environments ?? []).filter { !$0.name.isEmpty }
        return named.isEmpty ? Self.ownEnvironments : named
    }

    func deployEnvironment(named name: String) -> Environment? {
        deployEnvironments.first { $0.name == name }
    }

    var mcpPresets: [MCP.Preset] { mcp?.presets ?? [] }

    var mcpPresetGroups: [MCP.PresetGroup] {
        mcpPresets.reduce(into: []) { groups, preset in
            let trimmedType = preset.serverType?.trimmed
            let serverType = trimmedType?.isEmpty == false ? trimmedType : nil
            if let index = groups.firstIndex(where: { $0.serverType == serverType }) {
                groups[index].presets.append(preset)
            } else {
                groups.append(MCP.PresetGroup(serverType: serverType, presets: [preset]))
            }
        }
    }

    func mcpPreset(named name: String) -> MCP.Preset? {
        mcpPresets.first { $0.name == name }
    }
}
