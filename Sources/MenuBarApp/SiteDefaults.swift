import CryptoKit
import Foundation

// The parts of the app that belong to one organisation rather than to the app itself:
// the identity provider its APIs sign in against, the calls worth starting from, what its
// environments are named, its Grafana instances, the skills marketplace its agents install
// from, and the commands worth having on hand. Keeping them in a file rather than in code
// means each team points the same build at its own setup, and a build with no file at all
// still runs with every one of them empty.
//
// The file is read from the first of these that can be parsed:
//
//   1. $CONDUCTOR_SITE_DEFAULTS
//   2. A saved external configuration path
//   3. <application support>/site-defaults.json
//   4. site-defaults.json inside the app bundle
//
// None of it is compiled in. `site-defaults.example.json` shows the shape, and the build
// script can fold a chosen settings file into the bundle so a team can hand out an app
// that is already set up.
struct SiteDefaults: Decodable, Sendable {
    var dispatch: DispatchConfig? = nil
    var grafana: Grafana? = nil
    var skills: Skills? = nil
    var shortcuts: [Shortcut]? = nil

    // Not part of the file. These tell the UI where the values came from and whether a
    // higher-priority location failed, so a fallback never looks like that file worked.
    var loadFailure: String? = nil
    var sourceURL: URL? = nil

    private enum CodingKeys: String, CodingKey {
        case dispatch, grafana, skills, shortcuts
        case legacyHTTPClient = "postman"
    }

    init(dispatch: DispatchConfig? = nil,
         grafana: Grafana? = nil,
         skills: Skills? = nil,
         shortcuts: [Shortcut]? = nil,
         loadFailure: String? = nil,
         sourceURL: URL? = nil) {
        self.dispatch = dispatch
        self.grafana = grafana
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
        grafana = try values.decodeIfPresent(Grafana.self, forKey: .grafana)
        skills = try values.decodeIfPresent(Skills.self, forKey: .skills)
        shortcuts = try values.decodeIfPresent([Shortcut].self, forKey: .shortcuts)
    }

    struct DispatchConfig: Decodable, Sendable {
        var oauth: OAuth?
        var requests: [Request]?
        var environments: Environments?

        // What {{env}} stands for on each side of the sheet. Named here because the same
        // deployment is "dev" to one organisation and "staging" to the next.
        struct Environments: Decodable, Sendable {
            var staging: String?
            var production: String?
        }

        // Only the fields that identify a provider. The client secret and the tokens are
        // the user's own and live in the Keychain, so they are never written here.
        struct OAuth: Decodable, Sendable {
            var grant: GrantType?
            var authURL: String?
            var tokenURL: String?
            var clientID: String?
            var scope: String?
            var callbackURL: String?
        }

        struct Request: Decodable, Sendable {
            var name: String
            var method: HTTPMethod?
            var url: String
        }
    }

    struct Grafana: Decodable, Sendable {
        // Every instance is named after this, both here and in the agents' config files.
        static let namePrefix = "grafana-"

        var presets: [Preset]?

        struct Preset: Decodable, Sendable, Equatable, Identifiable {
            var scope: String
            var environment: String
            var url: String
            private var serves: [String]?

            init(scope: String, environment: String, url: String, serves: [String]? = nil) {
                self.scope = scope
                self.environment = environment
                self.url = url
                self.serves = serves
            }

            var id: String { name }

            // The server name the two agents know this instance by. Both the config file
            // and the troubleshooting prompt refer to it by name, so it has to be built
            // the same way every time.
            var name: String { "\(Grafana.namePrefix)\(scope)-\(environment)" }

            // Which environment a troubleshooting session offers this instance for. An
            // instance that lists none is offered for all of them.
            func serves(_ environment: String) -> Bool {
                guard let serves, !serves.isEmpty else { return true }
                return serves.contains(environment)
            }
        }
    }

    struct Skills: Decodable, Sendable {
        var name: String
        var marketplace: String
        var repository: String
    }

    // A command a fresh install starts with, for the ones a whole team runs often enough
    // to be worth handing over rather than typing out.
    struct Shortcut: Decodable, Sendable {
        var name: String
        var command: String
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
        ProcessInfo.processInfo.environment["CONDUCTOR_SITE_DEFAULTS"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    static var searchPaths: [URL] {
        searchPaths(environmentURL: environmentURL,
                    savedURL: Preferences.siteDefaultsURL,
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

    // The provider both API environments start from. Everything else about the setup,
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
            SavedRequest(name: $0.name, method: $0.method ?? .get, url: $0.url)
        }
    }

    // What {{env}} resolves to on each side. These are also the app's own values, so a
    // file that names neither still sends requests somewhere sensible.
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

    var grafanaPresets: [Grafana.Preset] { grafana?.presets ?? [] }

    func grafanaPreset(named name: String) -> Grafana.Preset? {
        grafanaPresets.first { $0.name == name }
    }
}
