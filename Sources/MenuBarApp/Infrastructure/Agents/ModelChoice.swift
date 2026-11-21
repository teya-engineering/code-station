import Foundation

// The models each agent's picker offers. Claude Code publishes stable aliases but no
// account-aware catalog, so those stay curated here. Codex and Copilot supply their
// choices through a local server of their own; the fallbacks keep settings usable with
// older or offline CLIs. `discovered` is that live catalog for the agent being asked
// about, and nil where there is none yet.
enum ModelChoice {
    struct Option: Identifiable, Equatable, Sendable {
        let id: String?
        let title: String
        let detail: String
        var supportedEfforts: [String]? = nil
        var isDefault = false
    }

    static let claude: [Option] = [
        Option(id: nil, title: "Default", detail: "Whatever Claude Code is set to use."),
        Option(id: "opus", title: "Opus", detail: "The strongest reasoning, and the slowest."),
        Option(id: "sonnet", title: "Sonnet", detail: "The everyday balance of speed and depth."),
        Option(id: "haiku", title: "Haiku", detail: "The fastest and cheapest; best for small, mechanical work."),
        Option(id: "fable", title: "Fable", detail: "Tuned for writing and long-form prose."),
    ]

    static let codexFallback: [Option] = [
        Option(id: nil, title: "Default", detail: "Whatever Codex is set to use."),
        Option(id: "gpt-5.6-sol", title: "Sol", detail: "The strongest reasoning, for long and hard work."),
        Option(id: "gpt-5.6-terra", title: "Terra", detail: "The everyday balance of speed and depth."),
        Option(id: "gpt-5.6-luna", title: "Luna", detail: "The fastest and cheapest; best for small, mechanical work."),
    ]

    // Copilot serves models from several makers, and which ones an account gets is up to
    // the account. These are the ones every plan has had.
    static let copilotFallback: [Option] = [
        Option(id: nil, title: "Default", detail: "Whatever Copilot is set to use."),
        Option(id: "auto", title: "Auto", detail: "Copilot picks the model for each request."),
        Option(id: "claude-sonnet-5", title: "Claude Sonnet 5", detail: "The everyday balance of speed and depth."),
        Option(id: "claude-opus-5", title: "Claude Opus 5", detail: "The strongest reasoning, and the slowest."),
        Option(id: "gpt-5.4", title: "GPT-5.4", detail: "OpenAI's everyday model."),
    ]

    static func fallback(for agent: AgentKind) -> [Option] {
        switch agent {
        case .claudeCode: claude
        case .codex: codexFallback
        case .copilot: copilotFallback
        }
    }

    static func options(for agent: AgentKind, discovered: [Option]? = nil) -> [Option] {
        guard agent != .claudeCode, let discovered else { return fallback(for: agent) }
        return [Option(id: nil, title: "Default",
                       detail: "Whatever \(agent.title) is set to use.")] + discovered
    }

    static func valid(_ id: String?, for agent: AgentKind,
                      discovered: [Option]? = nil) -> String? {
        guard let id, !id.isEmpty else { return nil }
        switch agent {
        case .claudeCode:
            guard claude.contains(where: { $0.id == id }) || id.hasPrefix("claude-")
            else { return nil }
        case .codex:
            if let discovered {
                guard discovered.contains(where: { $0.id == id }) else { return nil }
            } else {
                guard !claude.contains(where: { $0.id == id }), !id.hasPrefix("claude-")
                else { return nil }
            }
        case .copilot:
            // Copilot's catalog names Claude models too, so nothing about the id itself
            // says whether it belongs here. Without a catalog the CLI is left to judge.
            if let discovered {
                guard discovered.contains(where: { $0.id == id }) else { return nil }
            }
        }
        return id
    }

    // Copilot's fallback is left out on purpose: its ids are full model names, which
    // read better cut down the way the strip cuts them than under the picker's titles.
    static func title(of id: String?, discovered: [Option]? = nil) -> String {
        (claude + codexFallback + (discovered ?? [])).first { $0.id == id }?.title
            ?? id.map(shortName) ?? "Default"
    }

    // How the app-wide choice reads on the row that says a session is following it.
    static func summary(of id: String?, agent: AgentKind,
                        discovered: [Option]? = nil) -> String {
        guard let id, !id.isEmpty else { return "Whatever \(agent.title) is set to use" }
        return title(of: id, discovered: discovered)
    }

    // Which agent an old session most likely ran on, going by its model. Only Claude Code
    // and Codex predate the agent being saved with the session, so those are the choices.
    static func inferredAgent(of id: String?) -> AgentKind? {
        guard let id, !id.isEmpty else { return nil }
        if claude.contains(where: { $0.id == id }) || id.hasPrefix("claude-") {
            return .claudeCode
        }
        return .codex
    }

    // What the CLI reports a turn ran on, cut down to the part worth reading in a strip:
    // "claude-haiku-4-5-20251001" is mostly prefix and a release date, and the family and
    // its number are all that separate one model from another at a glance.
    static func shortName(of canonical: String) -> String {
        if let choice = (claude + codexFallback).first(where: { $0.id == canonical }) {
            return choice.title
        }

        var name = canonical
        // A window variant is spelled "claude-opus-5[1m]", and the window is already a
        // number of its own on the same row.
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }

        var parts = name.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first, !family.isEmpty else { return canonical }

        let version = parts.dropFirst().joined(separator: ".")
        let title = family == "gpt" ? "GPT" : family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }
}
