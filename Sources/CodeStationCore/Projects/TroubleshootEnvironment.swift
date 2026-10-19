import Foundation

// One of the deployments the site file names, as a diagnosis sees it. The GUI reads them
// from its own site defaults (bundled file included); a host without them reads the
// site file's `environments` itself (`site(from:)`).
public struct TroubleshootEnvironment: Identifiable, Equatable, Codable, Sendable {
    public let name: String
    public let title: String
    public let isDangerous: Bool

    public init(name: String, title: String, isDangerous: Bool = false) {
        self.name = name
        self.title = title
        self.isDangerous = isDangerous
    }

    public var id: String { name }

    // The prompt gets the name the deployment goes by as well as its label, since "prd"
    // is what the agent will meet in URLs and namespaces while "Prod" is only on screen.
    public var promptTitle: String {
        title.lowercased() == name.lowercased() ? name : "\(title) (\(name))"
    }

    // What a file that names no environment leaves the app on.
    public static let production = TroubleshootEnvironment(name: "production",
                                                           title: "Production",
                                                           isDangerous: true)
}

extension TroubleshootEnvironment {
    // What a site file that names no environment leaves every host on.
    public static let ownEnvironments = [
        TroubleshootEnvironment(name: "staging", title: "Staging"),
        production,
    ]

    // The site file's own places, as the GUI looks them up, without the copy bundled
    // into the app: the environment's override, the path saved in the preferences, then
    // the file in the app's support folder.
    public static func siteSearchPaths(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       preferences: UserDefaults = Preferences.defaults) -> [URL] {
        let named = (environment["CODE_STATION_SITE_DEFAULTS"] ?? environment["CONDUCTOR_SITE_DEFAULTS"])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        return [named, Preferences.siteDefaultsURL(in: preferences),
                AppPaths.support.appendingPathComponent("site-defaults.json")]
            .compactMap { $0 }
    }

    // The deployments the first readable site file names, as the GUI reads them: each
    // name with its label (the name capitalised when it has none) and whether it is live.
    // An older file's two Dispatch aliases stand in for a missing list. A file that names
    // none, or no file at all, leaves staging and production.
    public static func site(from urls: [URL]) -> [TroubleshootEnvironment] {
        struct File: Decodable {
            struct Entry: Decodable { var name: String; var title: String?; var danger: Bool? }
            struct Dispatch: Decodable {
                struct Aliases: Decodable { var staging: String?; var production: String? }
                var environments: Aliases?
            }
            var environments: [Entry]?
            var dispatch: Dispatch?
            var postman: Dispatch?
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data) else { continue }
            var named = (file.environments ?? []).filter { !$0.name.isEmpty }.map {
                TroubleshootEnvironment(name: $0.name, title: $0.title ?? $0.name.capitalized,
                                        isDangerous: $0.danger ?? false)
            }
            if file.environments == nil, let aliases = (file.dispatch ?? file.postman)?.environments {
                let staging = aliases.staging ?? "dev"
                let live = aliases.production ?? "prd"
                named = [TroubleshootEnvironment(name: staging, title: "Staging")]
                if live != staging {
                    named.append(TroubleshootEnvironment(name: live, title: "Production", isDangerous: true))
                }
            }
            return named.isEmpty ? ownEnvironments : named
        }
        return ownEnvironments
    }

    // Whether a server tagged `tag` is offered to a diagnosis here. An untagged server,
    // or one tagged with an environment the site no longer names, is offered everywhere.
    public func includes(tag: String?, among environments: [TroubleshootEnvironment]) -> Bool {
        guard let tag, !tag.isEmpty, environments.contains(where: { $0.name == tag }) else { return true }
        return tag == name
    }
}
