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
struct SessionSettings: Codable, Equatable, Sendable {
    var model: String?
    var effort: String?
    var permissionMode: String?
    var codexSandboxMode: String?
    var mcpServersEnabled: Bool?
    // An allowlist of managed servers for sessions that need a filtered MCP config.
    // Nil keeps using the agent's own configuration without filtering it.
    var allowedMCPServerNames: [String]?
    var disabledMCPServers: [DisabledMCPServer]?
    // Kept so sessions written before disabled servers carried a transport still decode.
    // A name alone cannot form a valid Codex MCP override, so new sessions do not set it.
    var disabledMCPServerNames: [String]?
}

// Codex validates an MCP server's transport before it looks at whether the server is
// enabled. The transport kind is therefore part of a diagnosis's disabled-server snapshot.
struct DisabledMCPServer: Codable, Equatable, Sendable {
    enum Transport: String, Codable, Sendable {
        case stdio
        case streamableHTTP
    }

    let name: String
    let transport: Transport
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

// The permission modes Claude Code takes, minus the ones that have no place in a desktop
// app: nothing here can turn every check off. Stored as its raw value, which is the word
// the CLI's --permission-mode flag takes.
enum PermissionMode: String, CaseIterable, Identifiable {
    case acceptEdits, manual, auto

    static let fallback: PermissionMode = .acceptEdits

    // The fallback stands in for nothing chosen and for a mode the app no longer offers.
    init(stored: String?) {
        self = stored.flatMap(PermissionMode.init(rawValue:)) ?? .fallback
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .acceptEdits: "Accept edits, ask about the rest"
        case .manual: "Ask about everything"
        case .auto: "Ask only about risky things"
        }
    }

    // What the mode is called where a sentence does not fit, like the composer bar.
    var shortTitle: String {
        switch self {
        case .acceptEdits: "Accept edits"
        case .manual: "Ask everything"
        case .auto: "Ask risky only"
        }
    }

    var detail: String {
        switch self {
        case .acceptEdits:
            "Edits to files go through on their own. Commands and anything else are asked about."
        case .manual:
            "Every edit and every command waits for an answer. The slowest, and the one that shows the most."
        case .auto:
            "Claude Code judges each step and only asks about the ones that can do damage."
        }
    }
}

// The models each agent's picker offers. Claude Code publishes stable aliases but no
// account-aware catalog, so those stay curated here. Codex supplies its choices through
// the local app server; the fallback keeps settings usable with older or offline CLIs.
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

    static func options(for agent: AgentKind, codexModels: [Option]? = nil) -> [Option] {
        switch agent {
        case .claudeCode: return claude
        case .codex:
            guard let codexModels else { return codexFallback }
            return [Option(id: nil, title: "Default",
                           detail: "Whatever Codex is set to use.")] + codexModels
        }
    }

    static func valid(_ id: String?, for agent: AgentKind,
                      codexModels: [Option]? = nil) -> String? {
        guard let id, !id.isEmpty else { return nil }
        switch agent {
        case .claudeCode:
            guard claude.contains(where: { $0.id == id }) || id.hasPrefix("claude-")
            else { return nil }
        case .codex:
            if let codexModels {
                guard codexModels.contains(where: { $0.id == id }) else { return nil }
            } else {
                guard !claude.contains(where: { $0.id == id }), !id.hasPrefix("claude-")
                else { return nil }
            }
        }
        return id
    }

    static func title(of id: String?, codexModels: [Option]? = nil) -> String {
        (claude + (codexModels ?? codexFallback)).first { $0.id == id }?.title
            ?? id.map(shortName) ?? "Default"
    }

    // How the app-wide choice reads on the row that says a session is following it.
    static func summary(of id: String?, agent: AgentKind,
                        codexModels: [Option]? = nil) -> String {
        guard let id, !id.isEmpty else { return "Whatever \(agent.title) is set to use" }
        return title(of: id, codexModels: codexModels)
    }

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
        let title = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }
}

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

    static func all(for agent: AgentKind, model: String? = nil,
                    codexModels: [ModelChoice.Option]? = nil) -> [Option] {
        guard agent == .codex, let codexModels else { return levels }
        let selected = model.flatMap { selected in
            codexModels.first { $0.id == selected }
        } ?? codexModels.first(where: \.isDefault)
        guard let efforts = selected?.supportedEfforts, !efforts.isEmpty else { return levels }
        return [Option(id: nil, title: "Default")] + efforts.map {
            Option(id: $0, title: title(of: $0))
        }
    }

    static func valid(_ id: String?, for agent: AgentKind, model: String? = nil,
                      codexModels: [ModelChoice.Option]? = nil) -> String? {
        guard let id, !id.isEmpty,
              all(for: agent, model: model, codexModels: codexModels)
                .contains(where: { $0.id == id }) else { return nil }
        return id
    }

    static func summary(of id: String?, agent: AgentKind, model: String? = nil,
                        codexModels: [ModelChoice.Option]? = nil) -> String {
        guard let id, !id.isEmpty else { return "Whatever \(agent.title) is set to use" }
        return all(for: agent, model: model, codexModels: codexModels)
            .first { $0.id == id }?.title ?? Self.title(of: id)
    }

    private static func title(of id: String) -> String {
        switch id {
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
struct SessionUsage: Codable, Equatable, Sendable {
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
