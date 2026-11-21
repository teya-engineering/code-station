import Foundation

enum SiteConfigurationForm {
    static func cleaned(_ defaults: SiteDefaults,
                        aspect: SiteConfigurationAspect) throws -> SiteDefaults {
        var result = defaults
        result.loadFailure = nil
        result.sourceURL = nil

        switch aspect {
        case .environments:
            result.environments = (result.environments ?? []).map {
                SiteDefaults.Environment(name: $0.name.trimmed,
                                         title: optional($0.title),
                                         danger: $0.isDangerous ? true : nil)
            }
            guard result.environments?.allSatisfy({ !$0.name.isEmpty }) == true else {
                throw ImportError("Every environment needs a name.")
            }
            let names = result.environments?.map(\.name) ?? []
            guard !names.isEmpty else {
                throw ImportError("Add at least one environment.")
            }
            guard Set(names).count == names.count else {
                throw ImportError("Environment names must be unique.")
            }

        case .apiAccess:
            if var oauth = result.dispatch?.oauth {
                oauth.authURL = optional(oauth.authURL)
                oauth.tokenURL = optional(oauth.tokenURL)
                oauth.clientID = optional(oauth.clientID)
                oauth.scope = optional(oauth.scope)
                oauth.callbackURL = optional(oauth.callbackURL)
                result.dispatch?.oauth = oauth

                let config = result.dispatchOAuth
                guard config.missing.isEmpty else {
                    throw ImportError("Fill in \(config.missing.joined(separator: ", ")).")
                }
            }
            removeEmptyDispatch(from: &result)

        case .requests:
            let requests = (result.dispatch?.requests ?? []).map {
                SiteDefaults.DispatchConfig.Request(name: $0.name.trimmed,
                                                    method: $0.method ?? .get,
                                                    url: $0.url.trimmed)
            }
            guard requests.allSatisfy({ !$0.name.isEmpty && !$0.url.isEmpty }) else {
                throw ImportError("Every starter request needs a name and URL.")
            }
            var dispatch = result.dispatch ?? SiteDefaults.DispatchConfig()
            dispatch.requests = requests
            result.dispatch = dispatch

        case .mcp:
            let presets = (result.mcp?.presets ?? []).map(cleanedPreset)
            guard presets.allSatisfy({ !$0.name.isEmpty && $0.hasConnection }) else {
                throw ImportError("Every MCP preset needs a name and either a command or URL.")
            }
            let names = presets.map(\.name)
            guard Set(names).count == names.count else {
                throw ImportError("MCP preset names must be unique.")
            }
            for preset in presets {
                try validateValues(preset.env, in: preset.name)
                try validateValues(preset.headers, in: preset.name)
            }
            result.mcp = SiteDefaults.MCP(presets: presets)

        case .skills:
            if let skills = result.skills {
                let cleaned = SiteDefaults.Skills(name: skills.name.trimmed,
                                                  marketplace: skills.marketplace.trimmed,
                                                  repository: skills.repository.trimmed,
                                                  sourceKind: skills.sourceKind)
                guard !cleaned.name.isEmpty,
                      !cleaned.marketplace.isEmpty,
                      !cleaned.repository.isEmpty else {
                    throw ImportError("The marketplace needs a display name, marketplace name, and repository.")
                }
                result.skills = cleaned
            }

        case .shortcuts:
            let shortcuts = (result.shortcuts ?? []).map {
                SiteDefaults.ShortcutEntry(name: $0.name.trimmed, command: $0.command.trimmed,
                                           icon: ShortcutIcon.resolve($0.icon))
            }
            guard shortcuts.allSatisfy({ !$0.name.isEmpty && !$0.command.isEmpty }) else {
                throw ImportError("Every shortcut needs a name and a command.")
            }
            result.shortcuts = shortcuts
        }

        return result
    }

    private static func optional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanedPreset(_ preset: SiteDefaults.MCP.Preset)
        -> SiteDefaults.MCP.Preset {
        SiteDefaults.MCP.Preset(
            name: preset.name.trimmed,
            title: optional(preset.title),
            serverType: optional(preset.serverType),
            environment: optional(preset.environment),
            command: optional(preset.command),
            args: preset.args?.map(\.trimmed).filter { !$0.isEmpty },
            url: optional(preset.url),
            type: optional(preset.type),
            env: cleanedValues(preset.env),
            headers: cleanedValues(preset.headers))
    }

    private static func cleanedValues(_ values: [SiteDefaults.MCP.Value]?)
        -> [SiteDefaults.MCP.Value]? {
        values?.map { .init(key: $0.key.trimmed, value: $0.value.trimmed) }
    }

    private static func validateValues(_ values: [SiteDefaults.MCP.Value]?,
                                       in preset: String) throws {
        let values = values ?? []
        guard values.allSatisfy({ !$0.key.isEmpty }) else {
            throw ImportError("Every environment variable and header in \(preset) needs a key.")
        }
        guard Set(values.map(\.key)).count == values.count else {
            throw ImportError("Environment variable and header keys must be unique within \(preset).")
        }
    }

    private static func removeEmptyDispatch(from defaults: inout SiteDefaults) {
        guard let dispatch = defaults.dispatch else { return }
        if dispatch.oauth == nil && dispatch.requests == nil {
            defaults.dispatch = nil
        }
    }
}
