import Foundation

// The coding agents the app can run a session on. Each is a CLI resolved on PATH, with
// models, sign-in and conversation history of its own; the app speaks each one's stream
// dialect and folds them all onto the same events, so everything past the runner is shared.
enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude"
    case codex = "codex"
    case copilot = "copilot"
    case kiro = "kiro"

    var id: String { rawValue }

    // The executable the agent is run through. Kiro's CLI is named for the product, not
    // the agent, so it is the one whose command differs from its stored name.
    var command: String { self == .kiro ? "kiro-cli" : rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        case .kiro: "Kiro"
        }
    }

    // Who makes the agent, for the places that tell the agents apart by it.
    var vendor: String {
        switch self {
        case .claudeCode: "Anthropic"
        case .codex: "OpenAI"
        case .copilot: "GitHub"
        case .kiro: "AWS"
        }
    }

    // Beta leads, so a menu that cuts the line short still shows it.
    var blurb: String { isBeta ? "Beta · \(vendor)'s coding agent." : "\(vendor)'s coding agent." }

    // An agent the app runs but does not yet support in full. It is marked BETA wherever
    // it can be picked, and says what that means where its settings are.
    var isBeta: Bool { self == .kiro }

    // What beta means for this agent, in one sentence a person can act on.
    var betaNote: String? {
        guard isBeta else { return nil }
        return "\(title) support is in beta. Sessions, permissions, models, credits, Code Station's MCP servers, "
            + "importing past sessions and marketplace skills work. A marketplace package brings only its skills to \(title)."
    }

    var symbol: String {
        switch self {
        case .claudeCode: "brain.head.profile"
        case .codex: "sparkles"
        case .copilot: "airplane"
        case .kiro: "cloud"
        }
    }

    var installHint: String {
        switch self {
        case .claudeCode: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .copilot: "npm install -g @github/copilot"
        case .kiro: "brew install --cask kiro-cli"
        }
    }

    // The oldest release that accepts every argument the app passes. Each one is set by
    // the newest thing the app relies on, noted beside it, so it has to rise when the app
    // starts passing something newer.
    var minimumVersion: String {
        switch self {
        case .claudeCode: "2.1.154" // --prompt-suggestions
        case .codex: "0.147.0" // --approve-for-me
        case .copilot: "1.0.32" // --session-id
        case .kiro: "3.5.0" // ACP v3 model choice through session/set_config_option
        }
    }

    // Nil when the version cannot be read, so an unfamiliar format never raises a false
    // alarm about a CLI that may well be fine.
    func isOutdated(_ version: String) -> Bool? {
        guard var installed = Self.versionNumbers(version),
              var minimum = Self.versionNumbers(minimumVersion) else { return nil }
        let length = max(installed.count, minimum.count)
        installed += Array(repeating: 0, count: length - installed.count)
        minimum += Array(repeating: 0, count: length - minimum.count)
        return installed.lexicographicallyPrecedes(minimum)
    }

    // "0.153.4-alpha.2" reads as 0.153.4: a prerelease counts as the release it leads to.
    private static func versionNumbers(_ version: String) -> [Int]? {
        let core = version.prefix { $0.isNumber || $0 == "." }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count >= 2, !numbers.contains(nil) else { return nil }
        return numbers.compactMap { $0 }
    }

    // What signing in means for each CLI, typed into a shell as-is. Kiro's opens its own
    // menu of every way in, an organisation's sign-in included.
    var loginCommand: String {
        switch self {
        case .claudeCode: "claude /login"
        case .codex: "codex login"
        case .copilot: "copilot login"
        case .kiro: "kiro-cli login"
        }
    }

    // Whether tool access can be approved interactively. Codex and Copilot keep the
    // access policy chosen in settings, even though their servers accept follow-ups.
    // Kiro asks over ACP for each call its access mode does not already allow.
    var asksPermissions: Bool { self == .claudeCode || self == .kiro }

    // Whether a prompt sent during a turn can reach the agent before that turn ends.
    // Claude Code takes a message written to its open input at its next step, and Codex
    // has a request for steering its active turn. Copilot holds a second message until
    // the turn is over, which is no better than the app's own queue. ACP has no way to
    // add to a running prompt, so Kiro waits the same way.
    var canSteer: Bool { self != .copilot && self != .kiro }

    // Whether the CLI takes an effort level at all. Kiro's ACP server has none, so its
    // effort control would offer nothing but "Default" and is left out.
    var choosesEffort: Bool { self != .kiro }

    // Whether the CLI predicts the next prompt itself and reports it on its stream. The
    // others have to be asked in a run of their own, so a suggestion costs them far more.
    var predictsPrompts: Bool { self == .claudeCode }

    // Whether the CLI turns a slash command into the words behind it when one arrives in
    // a headless prompt. The others read the line as ordinary text and are left guessing
    // what it meant, so the app expands the command for them before it is sent.
    var expandsCommands: Bool { self == .claudeCode }

    // Whether a skill or command file named in the middle of a prompt still runs. Claude
    // Code picks one up through its Skill tool as it reads. The app expands only a leading
    // command for the other two, so a later one would reach them as plain words.
    var readsCommandsMidPrompt: Bool { self == .claudeCode }

    // Whether the CLI keeps one conversation id for the whole session. Claude Code forks
    // a new id on every resumed turn instead, which is what lets a turn be wound back.
    var reusesConversationID: Bool { self != .claudeCode }
}
