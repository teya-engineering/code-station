import Foundation

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
    var permissionMode: PermissionMode?
    var codexSandboxMode: CodexSandboxMode?
    var copilotAccessMode: CopilotAccessMode?
    // Only read by Design turns. Nil follows the app's Design default.
    var designAmbition: DesignAmbition?
    var mcpServersEnabled: Bool?
    // An allowlist of managed servers for sessions that need a filtered MCP config.
    // Nil keeps using the agent's own configuration without filtering it.
    var allowedMCPServerNames: [String]?
    var disabledMCPServers: [DisabledMCPServer]?
    // Kept so sessions written before disabled servers carried a transport still decode.
    // A name alone cannot form a valid Codex MCP override, so new sessions do not set it.
    var disabledMCPServerNames: [String]?
    init(model: String? = nil,
         effort: String? = nil,
         permissionMode: PermissionMode? = nil,
         codexSandboxMode: CodexSandboxMode? = nil,
         copilotAccessMode: CopilotAccessMode? = nil,
         designAmbition: DesignAmbition? = nil,
         mcpServersEnabled: Bool? = nil,
         allowedMCPServerNames: [String]? = nil,
         disabledMCPServers: [DisabledMCPServer]? = nil,
         disabledMCPServerNames: [String]? = nil) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.codexSandboxMode = codexSandboxMode
        self.copilotAccessMode = copilotAccessMode
        self.designAmbition = designAmbition
        self.mcpServersEnabled = mcpServersEnabled
        self.allowedMCPServerNames = allowedMCPServerNames
        self.disabledMCPServers = disabledMCPServers
        self.disabledMCPServerNames = disabledMCPServerNames
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
        permissionMode = try values.decodeIfPresent(String.self, forKey: .permissionMode)
            .map { PermissionMode(rawValue: $0) ?? .fallback }
        codexSandboxMode = try values.decodeIfPresent(String.self, forKey: .codexSandboxMode)
            .map { CodexSandboxMode(rawValue: $0) ?? .workspaceWrite }
        copilotAccessMode = try values.decodeIfPresent(String.self, forKey: .copilotAccessMode)
            .map { CopilotAccessMode(rawValue: $0) ?? .workspace }
        designAmbition = try values.decodeIfPresent(String.self, forKey: .designAmbition)
            .flatMap(DesignAmbition.init(rawValue:))
        mcpServersEnabled = try values.decodeIfPresent(Bool.self, forKey: .mcpServersEnabled)
        allowedMCPServerNames = try values.decodeIfPresent([String].self, forKey: .allowedMCPServerNames)
        disabledMCPServers = try values.decodeIfPresent([DisabledMCPServer].self, forKey: .disabledMCPServers)
        disabledMCPServerNames = try values.decodeIfPresent([String].self, forKey: .disabledMCPServerNames)
    }

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

// How far a Design turn pushes the look. The canvas, file and handoff rules are the same
// at every level; only the taste the agent is asked for changes.
enum DesignAmbition: String, Codable, Sendable, CaseIterable, Identifiable {
    case restrained
    case balanced
    case allOut = "all-out"

    static let fallback: DesignAmbition = .balanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restrained: "Restrained"
        case .balanced: "Balanced"
        case .allOut: "All out"
        }
    }

    var detail: String {
        switch self {
        case .restrained: "Stays close to the product as it is. Small changes that are easy to build."
        case .balanced: "Matches the product and finishes every detail."
        case .allOut: "Showcase quality. Bolder choices and richer motion."
        }
    }

    static func valid(_ value: String?) -> Self? {
        value.flatMap(Self.init(rawValue:))
    }

    // What a session runs with: its own choice, or the app's Design default.
    static func resolved(_ value: String?, in store: UserDefaults = .standard) -> Self {
        valid(value) ?? Preferences.designAmbition(in: store)
    }

    func changeNote(from previous: DesignAmbition) -> String {
        "Design ambition changed from \(previous.title) to \(title)."
    }

    // Put in front of the first prompt after a change. The level also sits in the system
    // prompt, but the conversation is full of work pitched at the old one, so the change
    // has to be said out loud for the agent to act on it.
    func changePrompt(from previous: DesignAmbition) -> String {
        "The design ambition has changed from \(previous.title) to \(title). \(title) means: "
            + "\(detail) Bring the design in line with the new level as you work on this request."
    }
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

// Token counts run to seven digits, which nothing on screen has room for.
func formattedTokens(_ count: Int) -> String {
    switch count {
    case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
    case 1_000...: String(format: "%.1fk", Double(count) / 1_000)
    default: "\(count)"
    }
}
