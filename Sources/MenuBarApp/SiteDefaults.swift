import Foundation

// The parts of the app that belong to one organisation rather than to the app itself:
// the identity provider its APIs sign in against, the calls worth starting from, its
// Grafana instances, and the skills marketplace its agents install from. Keeping them in
// a file rather than in code means each team points the same build at its own setup, and
// a build with no file at all still runs with every one of them empty.
//
// The file is read from the first of these that exists:
//
//   1. $CONDUCTOR_SITE_DEFAULTS
//   2. <application support>/site-defaults.json
//   3. site-defaults.json inside the app bundle
//
// None of it is compiled in. `site-defaults.example.json` shows the shape and
// `teya-defaults.json` holds Teya's own setup; the build script folds whichever one it is
// given into the bundle, so a team can hand out an app that is already set up.
struct SiteDefaults: Decodable, Sendable {
    var dispatch: DispatchConfig? = nil
    var grafana: Grafana? = nil
    var skills: Skills? = nil

    // Not part of the file. Set when a file was found but could not be read, so a typo
    // in it does not look the same as having no file.
    var loadFailure: String? = nil

    private enum CodingKeys: String, CodingKey {
        case dispatch, grafana, skills
        case legacyHTTPClient = "postman"
    }

    init(dispatch: DispatchConfig? = nil,
         grafana: Grafana? = nil,
         skills: Skills? = nil,
         loadFailure: String? = nil) {
        self.dispatch = dispatch
        self.grafana = grafana
        self.skills = skills
        self.loadFailure = loadFailure
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let dispatch = try values.decodeIfPresent(DispatchConfig.self, forKey: .dispatch)
        let legacy = try values.decodeIfPresent(DispatchConfig.self, forKey: .legacyHTTPClient)
        self.dispatch = dispatch ?? legacy
        grafana = try values.decodeIfPresent(Grafana.self, forKey: .grafana)
        skills = try values.decodeIfPresent(Skills.self, forKey: .skills)
    }

    struct DispatchConfig: Decodable, Sendable {
        var oauth: OAuth?
        var requests: [Request]?

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
}

extension SiteDefaults {
    static let current: SiteDefaults = load()

    static func load(_ urls: [URL] = searchPaths) -> SiteDefaults {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                return try JSONDecoder().decode(SiteDefaults.self, from: data)
            } catch {
                let message = "\(url.path) could not be read: \(error.localizedDescription)"
                FileHandle.standardError.write(Data("site defaults: \(message)\n".utf8))
                return SiteDefaults(loadFailure: message)
            }
        }
        return SiteDefaults()
    }

    static var searchPaths: [URL] {
        var paths: [URL] = []
        if let override = ProcessInfo.processInfo.environment["CONDUCTOR_SITE_DEFAULTS"] {
            paths.append(URL(fileURLWithPath: override))
        }
        paths.append(AppPaths.support.appendingPathComponent(fileName))
        if let bundled = bundledURL { paths.append(bundled) }
        return paths
    }

    static var bundledURL: URL? {
        Bundle.module.url(forResource: "site-defaults", withExtension: "json")
    }

    static let fileName = "site-defaults.json"

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

    var grafanaPresets: [Grafana.Preset] { grafana?.presets ?? [] }

    func grafanaPreset(named name: String) -> Grafana.Preset? {
        grafanaPresets.first { $0.name == name }
    }
}
