import Foundation

// What every Grafana server is launched and configured with, whatever instance it points
// at. The instances themselves are not the app's to know, so they come from the site
// file.
enum Grafana {
    static let namePrefix = "grafana-"
    static let command = "mcp-grafana"
    static let urlKey = "GRAFANA_URL"
    static let tokenKey = "GRAFANA_SERVICE_ACCOUNT_TOKEN"

    // Pull the environment back out of a "grafana-<scope>-<env>" name. Reading the name
    // rather than the site file means a server somebody added by hand is labelled too.
    // The environment is the last part and the scope is everything before it, so a scope
    // with a hyphen of its own, like "non-platform", still reads.
    static func environment(from name: String) -> String? { parts(of: name)?.environment }

    static func scope(from name: String) -> String? { parts(of: name)?.scope }

    static func serverName(scope: String, environment: String) -> String {
        "\(namePrefix)\(scope)-\(environment)"
    }

    private static func parts(of name: String) -> (scope: String, environment: String)? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let rest = name.dropFirst(namePrefix.count)
        guard let dash = rest.lastIndex(of: "-") else { return nil }
        let scope = String(rest[..<dash])
        let environment = String(rest[rest.index(after: dash)...])
        guard !scope.isEmpty, !environment.isEmpty else { return nil }
        return (scope, environment)
    }
}
