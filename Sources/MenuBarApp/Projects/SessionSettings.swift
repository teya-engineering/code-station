import Foundation

// The coding agents the app can run a session on. Each is a CLI resolved on PATH, with
// models, sign-in and conversation history of its own; the app speaks each one's stream
// dialect and folds both onto the same events, so everything past the runner is shared.
enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude"
    case codex = "codex"

    var id: String { rawValue }

    // The executable the agent is run through.
    var command: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var installHint: String {
        switch self {
        case .claudeCode: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        }
    }

    // What signing in means for each CLI, typed into a shell as-is.
    var loginCommand: String {
        switch self {
        case .claudeCode: "claude /login"
        case .codex: "codex login"
        }
    }
}

// What a session runs the agent with, on top of the prompt itself. These are the same
// choices the CLIs offer behind their model, effort and permission settings.
//
// The same type holds both layers. A session model starts as a copy of the app default
// and can be changed between turns; nil uses the CLI's own default. Nil for the other
// session controls keeps following the app default. In the app defaults, nil leaves the
// flag off entirely.
struct SessionSettings: Codable, Equatable {
    var model: String?
    var effort: String?
    var permissionMode: String?
    var codexSandboxMode: String?
    var mcpServersEnabled: Bool?
    // An allowlist of managed servers for sessions that need a filtered MCP config.
    // Nil keeps using the agent's own configuration without filtering it.
    var allowedMCPServerNames: [String]?
    var disabledMCPServerNames: [String]?
}

// Codex `exec` has no way to send a permission question back through the JSONL stream,
// so the app offers the access modes it can apply consistently to new and resumed turns.
// Full access is needed for local services such as a GPG agent.
enum CodexSandboxMode: String, CaseIterable {
    case workspaceWrite = "workspace-write"
    case approveForMe = "approve-for-me"
    case fullAccess = "danger-full-access"

    var title: String {
        switch self {
        case .workspaceWrite: "Sandboxed"
        case .approveForMe: "Sandboxed + auto-approve"
        case .fullAccess: "Full access"
        }
    }

    var summary: String {
        switch self {
        case .approveForMe: "Sandboxed + auto"
        default: title
        }
    }

    var detail: String {
        switch self {
        case .workspaceWrite:
            "Can edit this session's files. Internet, GPG, and other services outside the workspace stay blocked."
        case .approveForMe:
            "Keeps the sandbox. Codex can automatically approve a retry outside it when needed."
        case .fullAccess:
            "Runs without file, local service, or network restrictions. Use only with projects you trust."
        }
    }

    static func valid(_ value: String?) -> Self? {
        value.flatMap(Self.init(rawValue:))
    }

    static func resolved(_ value: String?) -> Self {
        valid(value) ?? .workspaceWrite
    }
}

// The models each agent's picker offers. For Claude Code these are the aliases the CLI
// takes - full names ("claude-opus-5") work too, but an alias always points at the
// newest of that family, which is what a picker should do. For Codex they are the model
// ids its CLI takes.
enum ModelChoice {
    static let claude: [(id: String?, title: String, detail: String)] = [
        (nil, "Default", "Whatever Claude Code is set to use."),
        ("opus", "Opus", "The strongest reasoning, and the slowest."),
        ("sonnet", "Sonnet", "The everyday balance of speed and depth."),
        ("haiku", "Haiku", "The fastest and cheapest; best for small, mechanical work."),
        ("fable", "Fable", "Tuned for writing and long-form prose."),
    ]

    static let codex: [(id: String?, title: String, detail: String)] = [
        (nil, "Default", "Whatever Codex is set to use."),
        ("gpt-5.6-sol", "Sol", "The strongest reasoning, for long and hard work."),
        ("gpt-5.6-terra", "Terra", "The everyday balance of speed and depth."),
        ("gpt-5.6-luna", "Luna", "The fastest and cheapest; best for small, mechanical work."),
    ]

    static func options(for agent: AgentKind) -> [(id: String?, title: String, detail: String)] {
        switch agent {
        case .claudeCode: claude
        case .codex: codex
        }
    }

    // An id that belongs to another agent can exist on an older mixed session. It reads
    // as "nothing chosen" instead of being sent and refused.
    static func valid(_ id: String?, for agent: AgentKind) -> String? {
        guard let id, !id.isEmpty,
              options(for: agent).contains(where: { $0.id == id }) else { return nil }
        return id
    }

    static func title(of id: String?) -> String {
        (claude + codex).first { $0.id == id }?.title ?? id ?? "Default"
    }

    // How the app-wide choice reads on the row that says a session is following it.
    static func summary(of id: String?, agent: AgentKind) -> String {
        guard let id, !id.isEmpty else { return "Whatever \(agent.title) is set to use" }
        return title(of: id)
    }

    // What the CLI reports a turn ran on, cut down to the part worth reading in a strip:
    // "claude-haiku-4-5-20251001" is mostly prefix and a release date, and the family and
    // its number are all that separate one model from another at a glance.
    static func shortName(of canonical: String) -> String {
        if let choice = (claude + codex).first(where: { $0.id == canonical }) {
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
        let title = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }
}

// How long the model spends thinking before it answers. More effort costs more tokens
// and more time, so it is the first thing to turn down when a limit is close.
enum EffortChoice {
    static let claude: [(id: String?, title: String)] = [
        (nil, "Default"),
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("xhigh", "Extra high"),
        ("max", "Max"),
    ]

    static let codex: [(id: String?, title: String)] = [
        (nil, "Default"),
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("xhigh", "Extra high"),
        ("max", "Max"),
    ]

    static func all(for agent: AgentKind) -> [(id: String?, title: String)] {
        switch agent {
        case .claudeCode: claude
        case .codex: codex
        }
    }

    static func valid(_ id: String?, for agent: AgentKind) -> String? {
        guard let id, !id.isEmpty,
              all(for: agent).contains(where: { $0.id == id }) else { return nil }
        return id
    }

    static func summary(of id: String?, agent: AgentKind) -> String {
        guard let id, !id.isEmpty else { return "Whatever \(agent.title) is set to use" }
        return all(for: agent).first { $0.id == id }?.title ?? id
    }
}

// What one finished turn cost. Read off the CLI's result event, which reports the whole
// turn including every tool call inside it.
struct TurnUsage: Equatable, Sendable {
    var costUSD: Double = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    // What the model is told to use for this model, when it says.
    var contextWindow = 0
    var model: String?
}

// Everything the session has spent so far. Persisted with the conversation, so the
// numbers survive a restart the way the transcript does.
struct SessionUsage: Codable, Equatable {
    var costUSD: Double = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var turns = 0
    // The size of the last prompt rather than a running total: it is what the next turn
    // starts from, so it is the number that says how much room is left. Cached tokens
    // count towards it - they are still in the window, they were just cheaper.
    var contextTokens = 0
    var contextWindow = 0
    // A session can move between agents, but its last model and context window belong
    // to the one that produced them.
    var latestAgent: AgentKind?
    var model: String?

    mutating func add(_ turn: TurnUsage, from agent: AgentKind) {
        costUSD += turn.costUSD
        inputTokens += turn.inputTokens
        outputTokens += turn.outputTokens
        cacheReadTokens += turn.cacheReadTokens
        cacheWriteTokens += turn.cacheWriteTokens
        turns += 1
        beginReport(from: agent)
        if turn.contextWindow > 0 { contextWindow = turn.contextWindow }
        if let model = turn.model { self.model = model }
    }

    mutating func noteContext(_ tokens: Int, contextWindow: Int?, model: String?,
                              from agent: AgentKind) {
        guard tokens > 0 else { return }
        beginReport(from: agent)
        contextTokens = tokens
        if let contextWindow, contextWindow > 0 { self.contextWindow = contextWindow }
        if let model, !model.isEmpty { self.model = model }
    }

    // The conversation behind the window has been dropped, so the next turn starts from
    // nothing. Only the size of that prompt goes back to zero: the tokens already spent
    // were still spent, and the window size still describes the model that will run.
    mutating func noteCleared() {
        contextTokens = 0
    }

    // A summary has taken the place of the conversation. Unlike clearing, this does not
    // leave the window empty, and the CLI only reports how big it was before, never
    // after - so the honest reading is none at all until the next turn measures one.
    // Dropping the window size with it is what takes the meter off the row meanwhile.
    mutating func noteCompacted() {
        contextTokens = 0
        contextWindow = 0
    }

    func model(for agent: AgentKind) -> String? {
        latestAgent == agent ? model : nil
    }

    var contextFraction: Double? {
        guard contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }

    func contextFraction(for agent: AgentKind) -> Double? {
        latestAgent == agent ? contextFraction : nil
    }

    private mutating func beginReport(from agent: AgentKind) {
        if latestAgent != agent {
            contextTokens = 0
            contextWindow = 0
            model = nil
        }
        latestAgent = agent
    }
}

// One of the account's usage windows, as the CLI reports it while a turn runs. This is
// what `/usage` shows: it belongs to the account rather than to any one session, and it
// is only ever as fresh as the last turn that ran.
struct RateLimit: Equatable, Sendable {
    var kind: String
    var status: String
    var resetsAt: Date?
    // A fraction of the window that has been used. The CLI only sends it once a window
    // is far enough along to be worth warning about, so it is usually missing.
    var utilization: Double?

    var title: String {
        switch kind {
        case "five_hour": "Current session limit"
        case "seven_day": "Weekly limit"
        case "seven_day_opus": "Weekly Opus limit"
        case "seven_day_sonnet": "Weekly Sonnet limit"
        case "seven_day_overage_included", "overage": "Extra usage"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var isBlocked: Bool { status == "rejected" }
    var isWarning: Bool { status == "allowed_warning" }
}

// Token counts run to seven digits, which nothing on screen has room for.
func formattedTokens(_ count: Int) -> String {
    switch count {
    case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
    case 1_000...: String(format: "%.1fk", Double(count) / 1_000)
    default: "\(count)"
    }
}
