import Foundation

// Everything the sidebar says about a session whose transcript is not in memory. It is
// derived from the conversation and written beside it in the index, which is what lets
// a session be described without being loaded.
struct SessionSummary: Codable, Equatable, Sendable {
    var lastMessageAt: Date?
    // The last call that finished, in the one-line form a row shows: "Bash · swift build".
    var lastTool: String?
    var added = 0
    var removed = 0

    // A whole shell command can be the label, and this one is written to the index for
    // every session. The row it ends up on is a single truncated line, so anything past
    // what could be read there is not worth keeping.
    private static let labelLimit = 120

    // Built from the whole transcript rather than kept up to date call by call: a result
    // lands long after the call that asked for it, and both numbers have to include it.
    static func of(_ messages: [ChatMessage], projectPath: String) -> SessionSummary {
        var summary = SessionSummary(lastMessageAt: messages.last?.date)
        for tool in messages.flatMap(\.tools) {
            guard !tool.isRunning else { continue }
            let presentation = ToolPresentationCache.presentation(for: tool,
                                                                   projectPath: projectPath)
            if !tool.isError {
                summary.added += presentation.added ?? 0
                summary.removed += presentation.removed ?? 0
            }
            let label = presentation.label
            summary.lastTool = label.count > labelLimit
                ? String(label.prefix(labelLimit)) + "…"
                : label
        }
        return summary
    }
}

enum SessionMode: String, Codable, Equatable, Sendable {
    case chat
    case design

    var title: String {
        switch self {
        case .chat: "Chat"
        case .design: "Design"
        }
    }
}

// A conversation with one coding agent in a project's directory. The agent is chosen
// when the session is created and stays with it, so every visible turn belongs to the
// same underlying conversation.
//
// The conversation itself is kept in a file of its own rather than in this record, so
// the app can hold every session it has ever had while only the open one costs anything.
struct ChatSession: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var projectID: UUID
    var title: String = "New session"
    var isPinned = false
    var isTroubleshooting = false
    var agent: AgentKind
    var mode: SessionMode = .chat
    // Design is the origin of a session, while the phase says what the agent is doing
    // now. Keeping them separate lets implementation retain the approved canvas and its
    // revisions without continuing to apply the Design-only instructions.
    var designPhase: DesignPhase?
    var designRevisions: [DesignRevision] = []
    var approvedDesignRevisionID: UUID?
    // A fresh Chat handoff owns its own checkout and immutable copy of the approved
    // materials. The source id links the two conversations when both still exist.
    var sourceDesignSessionID: UUID?
    var handedOffDesignRevisionID: UUID?
    // A hidden Design conversation can borrow another session's checkout without owning
    // its worktree. User-created Design sessions hold their own conversation directly.
    var designSourceSessionID: UUID?
    // Resume ids written before agents were pinned are kept so those conversations can
    // still be recovered. New sessions only fill the id belonging to their chosen agent.
    var claudeSessionID: String?
    var codexSessionID: String?
    var createdAt: Date = Date()
    // Set when the session runs in its own git worktree instead of the project
    // folder. The worktree and branch belong to this session and go with it.
    var worktreePath: String?
    var worktreeBranch: String?
    // Set only for a multi-project session. The checkout list is a snapshot of the
    // workspace at creation time, ordered with the lead project first.
    var workspaceID: UUID?
    var sessionProjects: [SessionProject]?
    // Folders outside every checkout that the person opened up from a permission card.
    // The agent's own view of them lasts as long as its process, and each turn starts a
    // new one, so the grant has to be kept here and handed over again every turn.
    var grantedDirectories: [String] = []
    // Optional so conversations written before the app had either still decode. Both
    // read as "nothing chosen yet" and "nothing spent yet".
    var settings: SessionSettings?
    var usage: SessionUsage?
    // The bot selected for this session. Custom bot filenames stay stable across launches,
    // while the built-in Default bot has a reserved name.
    var agentAvatarName: String?
    // Set when the agent opens a pull request from this session.
    var pullRequest: PullRequest?
    // What this run of a task was given for the holes in its prompt. The prompt itself is
    // in the transcript; this is kept so the run list can say what each run was about
    // without opening it.
    var taskValues: [String: String]?
    // A short account generated after an unseen turn, or when the person asks for one.
    // It stays outside the transcript because the request is an app action rather than a
    // new instruction for the coding task.
    var recap: SessionRecap?
    var summary = SessionSummary()

    // Empty until the store loads it, and empty again once nothing holds this session,
    // so nothing outside ProjectStore should reach for it: ask the store instead, which
    // is what guarantees there is a transcript here to read.
    var messages: [ChatMessage] = []
    var transcriptLoaded = false

    // When something last happened here, used for the sidebar's relative times.
    var lastActivity: Date { summary.lastMessageAt ?? createdAt }

    var isDesignSession: Bool { designSourceSessionID != nil }

    var ownsDesign: Bool { mode == .design }

    var isActivelyDesigning: Bool {
        ownsDesign && designPhase != .implementing
    }

    var isImplementingDesign: Bool {
        designPhase == .implementing || sourceDesignSessionID != nil
    }

    // A resume id proves an older session already started even if its transcript summary
    // came from a version that did not save dates.
    var hasStarted: Bool {
        summary.lastMessageAt != nil || claudeSessionID != nil || codexSessionID != nil
    }

    func agentSessionID(for agent: AgentKind) -> String? {
        switch agent {
        case .claudeCode: claudeSessionID
        case .codex: codexSessionID
        }
    }

    // Whether any agent still holds a conversation this session could resume. An empty
    // id is the same as none: it is never handed to a CLI as something to resume.
    var hasAgentConversation: Bool {
        AgentKind.allCases.contains { agentSessionID(for: $0)?.isEmpty == false }
    }

    // The first thing the user asked makes a better title than "New session". Pasted
    // terminal output can carry long runs of spaces and tabs, which would spend the whole
    // title on blanks, so runs collapse to one space before it is cut to length.
    mutating func retitleIfNeeded(from prompt: String) {
        guard title == "New session" else { return }
        let line = prompt.trimmed.split(separator: "\n").first.map(String.init) ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return }
        title = words.count > 48 ? String(words.prefix(48)) + "…" : words
    }

    // The transcript is read and written on its own, so it is not part of what a session
    // encodes to. It is still decoded: a file written before the split holds every
    // conversation inline, and that is what the store moves out on the first launch.
    private enum CodingKeys: String, CodingKey {
        case id, projectID, title, isPinned, isTroubleshooting, agent, mode, designPhase
        case designRevisions, approvedDesignRevisionID, sourceDesignSessionID
        case handedOffDesignRevisionID, designSourceSessionID
        case claudeSessionID, codexSessionID, createdAt
        case worktreePath, worktreeBranch
        case workspaceID, sessionProjects, settings, usage, agentAvatarName
        case pullRequest, taskValues, recap, summary, messages
    }

    init(id: UUID = UUID(), projectID: UUID, agent: AgentKind = .claudeCode) {
        self.id = id
        self.projectID = projectID
        self.agent = agent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New session"
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isTroubleshooting = try container.decodeIfPresent(Bool.self, forKey: .isTroubleshooting)
            ?? false
        designSourceSessionID = try container.decodeIfPresent(
            UUID.self, forKey: .designSourceSessionID)
        mode = try container.decodeIfPresent(SessionMode.self, forKey: .mode)
            ?? (designSourceSessionID == nil ? .chat : .design)
        designPhase = try container.decodeIfPresent(DesignPhase.self, forKey: .designPhase)
            ?? (mode == .design ? .designing : nil)
        designRevisions = try container.decodeIfPresent(
            [DesignRevision].self, forKey: .designRevisions) ?? []
        approvedDesignRevisionID = try container.decodeIfPresent(
            UUID.self, forKey: .approvedDesignRevisionID)
        sourceDesignSessionID = try container.decodeIfPresent(
            UUID.self, forKey: .sourceDesignSessionID)
        handedOffDesignRevisionID = try container.decodeIfPresent(
            UUID.self, forKey: .handedOffDesignRevisionID)
        claudeSessionID = try container.decodeIfPresent(String.self, forKey: .claudeSessionID)
        codexSessionID = try container.decodeIfPresent(String.self, forKey: .codexSessionID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        worktreeBranch = try container.decodeIfPresent(String.self, forKey: .worktreeBranch)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        sessionProjects = try container.decodeIfPresent([SessionProject].self, forKey: .sessionProjects)
        settings = try container.decodeIfPresent(SessionSettings.self, forKey: .settings)
        usage = try container.decodeIfPresent(SessionUsage.self, forKey: .usage)
        agentAvatarName = try container.decodeIfPresent(String.self, forKey: .agentAvatarName)
        pullRequest = try container.decodeIfPresent(PullRequest.self, forKey: .pullRequest)
        taskValues = try container.decodeIfPresent([String: String].self, forKey: .taskValues)
        recap = try container.decodeIfPresent(SessionRecap.self, forKey: .recap)
        summary = try container.decodeIfPresent(SessionSummary.self, forKey: .summary) ?? SessionSummary()
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        transcriptLoaded = !messages.isEmpty
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent)
            ?? Self.inferredAgent(claudeSessionID: claudeSessionID,
                                  codexSessionID: codexSessionID,
                                  settings: settings,
                                  usage: usage)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(title, forKey: .title)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isTroubleshooting, forKey: .isTroubleshooting)
        try container.encode(agent, forKey: .agent)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(designPhase, forKey: .designPhase)
        if !designRevisions.isEmpty {
            try container.encode(designRevisions, forKey: .designRevisions)
        }
        try container.encodeIfPresent(approvedDesignRevisionID,
                                      forKey: .approvedDesignRevisionID)
        try container.encodeIfPresent(sourceDesignSessionID, forKey: .sourceDesignSessionID)
        try container.encodeIfPresent(handedOffDesignRevisionID,
                                      forKey: .handedOffDesignRevisionID)
        try container.encodeIfPresent(designSourceSessionID, forKey: .designSourceSessionID)
        try container.encodeIfPresent(claudeSessionID, forKey: .claudeSessionID)
        try container.encodeIfPresent(codexSessionID, forKey: .codexSessionID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(worktreePath, forKey: .worktreePath)
        try container.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(sessionProjects, forKey: .sessionProjects)
        try container.encodeIfPresent(settings, forKey: .settings)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(agentAvatarName, forKey: .agentAvatarName)
        try container.encodeIfPresent(pullRequest, forKey: .pullRequest)
        try container.encodeIfPresent(taskValues, forKey: .taskValues)
        try container.encodeIfPresent(recap, forKey: .recap)
        try container.encode(summary, forKey: .summary)
    }

    // Old sessions did not save their agent. Usage is the strongest signal for mixed
    // histories, followed by a model choice and then the one resume id on the record.
    private static func inferredAgent(claudeSessionID: String?, codexSessionID: String?,
                                      settings: SessionSettings?, usage: SessionUsage?) -> AgentKind {
        if let latest = usage?.latestAgent { return latest }
        if ModelChoice.valid(settings?.model, for: .codex) != nil { return .codex }
        if ModelChoice.valid(settings?.model, for: .claudeCode) != nil { return .claudeCode }
        if codexSessionID != nil, claudeSessionID == nil { return .codex }
        return .claudeCode
    }
}
