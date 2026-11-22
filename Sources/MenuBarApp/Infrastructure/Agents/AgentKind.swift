import Foundation

// The coding agents the app can run a session on. Each is a CLI resolved on PATH, with
// models, sign-in and conversation history of its own; the app speaks each one's stream
// dialect and folds them all onto the same events, so everything past the runner is shared.
enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude"
    case codex = "codex"
    case copilot = "copilot"

    var id: String { rawValue }

    // The executable the agent is run through.
    var command: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        }
    }

    // Who makes the agent, for the places that tell the agents apart by it.
    var vendor: String {
        switch self {
        case .claudeCode: "Anthropic"
        case .codex: "OpenAI"
        case .copilot: "GitHub"
        }
    }

    var blurb: String { "\(vendor)'s coding agent." }

    var symbol: String {
        switch self {
        case .claudeCode: "brain.head.profile"
        case .codex: "sparkles"
        case .copilot: "airplane"
        }
    }

    var installHint: String {
        switch self {
        case .claudeCode: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .copilot: "npm install -g @github/copilot"
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

    // What signing in means for each CLI, typed into a shell as-is.
    var loginCommand: String {
        switch self {
        case .claudeCode: "claude /login"
        case .codex: "codex login"
        case .copilot: "copilot login"
        }
    }

    // Whether tool access can be approved interactively. Codex and Copilot keep the
    // access policy chosen in settings, even though their servers accept follow-ups.
    var asksPermissions: Bool { self == .claudeCode }

    // Whether a prompt sent during a turn can reach the agent before that turn ends.
    // Claude Code takes a message written to its open input at its next step, and Codex
    // has a request for steering its active turn. Copilot holds a second message until
    // the turn is over, which is no better than the app's own queue.
    var canSteer: Bool { self != .copilot }

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
