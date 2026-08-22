import Foundation

// A configuration file is useful as a baseline without being an all-or-nothing import.
// Each aspect can be reset on its own, while everything not selected stays as it is.
enum SiteConfigurationAspect: String, CaseIterable, Hashable, Identifiable, Sendable {
    case environments
    case apiAccess
    case requests
    case mcp
    case skills
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .environments: "Environments"
        case .apiAccess: "API access"
        case .requests: "Starter requests"
        case .mcp: "MCP presets"
        case .skills: "Skills marketplace"
        case .shortcuts: "Shortcuts"
        }
    }

    var icon: String {
        switch self {
        case .environments: "server.rack"
        case .apiAccess: "key"
        case .requests: "arrow.up.right"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .skills: "shippingbox"
        case .shortcuts: "terminal"
        }
    }

    func detail(in defaults: SiteDefaults) -> String {
        switch self {
        case .environments:
            let count = defaults.environments?.count ?? 0
            return count == 1 ? "1 environment" : "\(count) environments"
        case .apiAccess:
            let oauth = defaults.dispatch?.oauth
            if let clientID = oauth?.clientID, !clientID.isEmpty { return clientID }
            if oauth != nil { return "Sign-in provider" }
            return "No sign-in provider"
        case .requests:
            let count = defaults.dispatch?.requests?.count ?? 0
            return count == 1 ? "1 starter request" : "\(count) starter requests"
        case .mcp:
            let count = defaults.mcp?.presets?.count ?? 0
            return count == 1 ? "1 MCP preset" : "\(count) MCP presets"
        case .skills:
            return defaults.skills?.name ?? "No marketplace"
        case .shortcuts:
            let count = defaults.shortcuts?.count ?? 0
            return count == 1 ? "1 shortcut" : "\(count) shortcuts"
        }
    }
}

struct SiteConfigurationPlan: Sendable {
    let aspects: [SiteConfigurationAspect]

    var everything: Set<SiteConfigurationAspect> { Set(aspects) }
    var isEmpty: Bool { aspects.isEmpty }

    init(_ defaults: SiteDefaults) {
        aspects = SiteConfigurationAspect.allCases.filter { aspect in
            switch aspect {
            case .environments:
                defaults.environments != nil
            case .apiAccess:
                defaults.dispatch?.oauth != nil
            case .requests:
                defaults.dispatch?.requests != nil
            case .mcp:
                defaults.mcp != nil
            case .skills:
                defaults.skills != nil
            case .shortcuts:
                defaults.shortcuts != nil
            }
        }
    }

    static func resetting(_ chosen: Set<SiteConfigurationAspect>,
                          in current: SiteDefaults,
                          to imported: SiteDefaults) -> SiteDefaults {
        var result = current

        if chosen.contains(.environments) {
            result.environments = imported.deployEnvironments
        }

        if chosen.contains(.apiAccess) || chosen.contains(.requests) {
            var dispatch = result.dispatch ?? SiteDefaults.DispatchConfig()
            if chosen.contains(.apiAccess) {
                dispatch.oauth = imported.dispatch?.oauth
            }
            if chosen.contains(.requests) {
                dispatch.requests = imported.dispatch?.requests
            }
            result.dispatch = dispatch.oauth == nil
                && dispatch.requests == nil ? nil : dispatch
        }

        if chosen.contains(.mcp) { result.mcp = imported.mcp }
        if chosen.contains(.skills) { result.skills = imported.skills }
        if chosen.contains(.shortcuts) { result.shortcuts = imported.shortcuts }

        result.loadFailure = nil
        result.sourceURL = nil
        return result
    }
}
