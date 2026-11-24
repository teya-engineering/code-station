import Foundation

// How long the model spends thinking before it answers. More effort costs more tokens
// and more time, so it is the first thing to turn down when a limit is close.
enum EffortChoice {
    struct Option: Identifiable, Equatable, Sendable {
        let id: String?
        let title: String
    }

    static let levels: [Option] = [
        Option(id: nil, title: "Default"),
        Option(id: "low", title: "Low"),
        Option(id: "medium", title: "Medium"),
        Option(id: "high", title: "High"),
        Option(id: "xhigh", title: "Extra high"),
        Option(id: "max", title: "Max"),
    ]

    // A discovered catalog can say which levels a model takes; the curated levels stand
    // in for every other case.
    static func all(for agent: AgentKind, model: String? = nil,
                    discovered: [ModelChoice.Option]? = nil) -> [Option] {
        // Kiro's ACP server takes no effort level, so there is nothing to choose.
        if agent == .kiro { return [levels[0]] }
        guard agent != .claudeCode, let discovered else { return levels }
        let selected = model.flatMap { selected in
            discovered.first { $0.id == selected }
        } ?? discovered.first(where: \.isDefault)
        guard let efforts = selected?.supportedEfforts, !efforts.isEmpty else { return levels }
        return [Option(id: nil, title: "Default")] + efforts.map {
            Option(id: $0, title: title(of: $0))
        }
    }

    static func valid(_ id: String?, for agent: AgentKind, model: String? = nil,
                      discovered: [ModelChoice.Option]? = nil) -> String? {
        guard let id, !id.isEmpty,
              all(for: agent, model: model, discovered: discovered)
                .contains(where: { $0.id == id }) else { return nil }
        return id
    }

    static func summary(of id: String?, agent: AgentKind, model: String? = nil,
                        discovered: [ModelChoice.Option]? = nil) -> String {
        guard let id, !id.isEmpty else { return "Whatever \(agent.title) is set to use" }
        return all(for: agent, model: model, discovered: discovered)
            .first { $0.id == id }?.title ?? Self.title(of: id)
    }

    private static func title(of id: String) -> String {
        switch id {
        case "none": "None"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        case "max": "Max"
        case "ultra": "Ultra"
        default: id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
