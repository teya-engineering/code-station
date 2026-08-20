import Foundation

// One thing a settings file offers. A file arrives as a single document, but the parts of
// it are unrelated: an organisation's Grafana instances are worth taking even when its
// starter requests would bury the ones already saved. The index is the position in the
// file's own array, which is what lets a choice be applied back to the raw JSON.
enum SiteConfigurationItem: Hashable, Sendable {
    case oauth
    case environments
    case request(Int)
    case grafanaPreset(Int)
    case skills
    case shortcut(Int)
}

// What a loaded file holds, listed so it can be reviewed before any of it is kept.
struct SiteConfigurationPlan: Sendable {
    struct Item: Identifiable, Sendable {
        let id: SiteConfigurationItem
        let title: String
        let detail: String
    }

    struct Group: Identifiable, Sendable {
        let title: String
        let items: [Item]

        var id: String { title }
    }

    let groups: [Group]

    var items: [Item] { groups.flatMap(\.items) }
    var everything: Set<SiteConfigurationItem> { Set(items.map(\.id)) }
    var isEmpty: Bool { groups.isEmpty }

    init(_ defaults: SiteDefaults) {
        var groups: [Group] = []

        var access: [Item] = []
        if let oauth = defaults.dispatch?.oauth {
            let detail = [oauth.clientID, oauth.tokenURL ?? oauth.authURL]
                .compactMap { $0 }
                .joined(separator: " at ")
            access.append(Item(id: .oauth,
                               title: "Sign-in provider",
                               detail: detail.isEmpty ? "The provider API calls sign in against" : detail))
        }
        if let environments = defaults.dispatch?.environments,
           environments.staging != nil || environments.production != nil {
            let values = defaults.dispatchEnvValues
            access.append(Item(id: .environments,
                               title: "Environment names",
                               detail: "staging is \(values.staging), production is \(values.production)"))
        }
        if !access.isEmpty {
            groups.append(Group(title: "API access", items: access))
        }

        let requests = defaults.dispatch?.requests ?? []
        if !requests.isEmpty {
            groups.append(Group(title: "Starter requests",
                                items: requests.enumerated().map { index, request in
                Item(id: .request(index),
                     title: request.name,
                     detail: "\((request.method ?? .get).rawValue) \(request.url)")
            }))
        }

        let presets = defaults.grafanaPresets
        if !presets.isEmpty {
            groups.append(Group(title: "Grafana presets",
                                items: presets.enumerated().map { index, preset in
                Item(id: .grafanaPreset(index), title: preset.name, detail: preset.url)
            }))
        }

        if let skills = defaults.skills {
            groups.append(Group(title: "Skills marketplace",
                                items: [Item(id: .skills,
                                             title: skills.name,
                                             detail: skills.repository)]))
        }

        let shortcuts = defaults.shortcuts ?? []
        if !shortcuts.isEmpty {
            groups.append(Group(title: "Shortcuts",
                                items: shortcuts.enumerated().map { index, shortcut in
                Item(id: .shortcut(index), title: shortcut.name, detail: shortcut.command)
            }))
        }

        self.groups = groups
    }
}

extension SiteConfigurationPlan {
    // The chosen parts written back as a settings file. The file's own JSON is edited
    // rather than re-encoded from the decoded values, so anything the app does not read
    // yet - a newer key, a field only one section uses - survives an import that keeps
    // the section holding it.
    static func filter(_ data: Data, keeping chosen: Set<SiteConfigurationItem>) throws -> Data {
        let object = try? JSONSerialization.jsonObject(with: data)
        guard var root = object as? [String: Any] else {
            throw ImportError("The configuration is not a JSON object.")
        }

        // A file may still name this section the way the HTTP client used to be called.
        let dispatchKey = root["dispatch"] != nil ? "dispatch" : "postman"
        if var dispatch = root[dispatchKey] as? [String: Any] {
            if !chosen.contains(.oauth) { dispatch.removeValue(forKey: "oauth") }
            if !chosen.contains(.environments) { dispatch.removeValue(forKey: "environments") }
            if let requests = dispatch["requests"] as? [Any] {
                put(keep(requests) { chosen.contains(.request($0)) },
                    at: "requests", in: &dispatch)
            }
            put(dispatch.isEmpty ? nil : dispatch, at: dispatchKey, in: &root)
        }

        if var grafana = root["grafana"] as? [String: Any] {
            if let presets = grafana["presets"] as? [Any] {
                put(keep(presets) { chosen.contains(.grafanaPreset($0)) },
                    at: "presets", in: &grafana)
            }
            put(grafana.isEmpty ? nil : grafana, at: "grafana", in: &root)
        }

        if !chosen.contains(.skills) { root.removeValue(forKey: "skills") }

        if let shortcuts = root["shortcuts"] as? [Any] {
            put(keep(shortcuts) { chosen.contains(.shortcut($0)) }, at: "shortcuts", in: &root)
        }

        do {
            return try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw ImportError("The chosen parts could not be saved: \(error.localizedDescription)")
        }
    }

    // An emptied list is dropped rather than left behind, so a section nobody kept reads
    // as absent instead of as one that deliberately offers nothing.
    private static func keep(_ values: [Any], where isChosen: (Int) -> Bool) -> [Any]? {
        let kept = values.enumerated().filter { isChosen($0.offset) }.map(\.element)
        return kept.isEmpty ? nil : kept
    }

    private static func put(_ value: Any?, at key: String, in dictionary: inout [String: Any]) {
        if let value {
            dictionary[key] = value
        } else {
            dictionary.removeValue(forKey: key)
        }
    }
}
