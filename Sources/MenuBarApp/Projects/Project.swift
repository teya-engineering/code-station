import Foundation

// What a task does when it is run: the prompt handed to a fresh session, and the run
// choices that session starts with. Nil choices follow the app defaults at run time.
// Only ad-hoc projects carry one.
//
// A prompt can leave holes for the run to fill - see TaskTemplate. `inputs` says how each
// hole is asked for, and `lastValues` is what the last run put in them, so running the
// same thing again is a confirmation rather than a retype.
struct TaskSpec: Codable, Equatable {
    var prompt: String
    var agent: AgentKind?
    var agentAvatarName: String?
    var model: String?
    var effort: String?
    var permissionMode: String?
    var codexSandboxMode: String?
    var inputs: [TaskInput] = []
    var lastValues: [String: String] = [:]
    var schedule: TaskSchedule?

    init(prompt: String, agent: AgentKind? = nil, agentAvatarName: String? = nil,
         model: String? = nil, effort: String? = nil, permissionMode: String? = nil,
         codexSandboxMode: String? = nil, inputs: [TaskInput] = [],
         lastValues: [String: String] = [:], schedule: TaskSchedule? = nil) {
        self.prompt = prompt
        self.agent = agent
        self.agentAvatarName = agentAvatarName
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.codexSandboxMode = codexSandboxMode
        self.inputs = inputs
        self.lastValues = lastValues
        self.schedule = schedule
    }

    // Tasks saved before a prompt could ask for anything hold neither list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(String.self, forKey: .prompt)
        agent = try container.decodeIfPresent(AgentKind.self, forKey: .agent)
        agentAvatarName = try container.decodeIfPresent(String.self, forKey: .agentAvatarName)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        codexSandboxMode = try container.decodeIfPresent(String.self, forKey: .codexSandboxMode)
        inputs = try container.decodeIfPresent([TaskInput].self, forKey: .inputs) ?? []
        lastValues = try container.decodeIfPresent([String: String].self, forKey: .lastValues)
            ?? [:]
        schedule = try container.decodeIfPresent(TaskSchedule.self, forKey: .schedule)
    }
}

// A project is just a folder on disk. A session runs Claude Code either directly in
// this directory or in a worktree of its own - see ChatSession.worktreePath.
struct Project: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case project
        case adHoc
    }

    var id: UUID
    var name: String
    var path: String
    var kind: Kind
    // The saved prompt behind a task. Nil on normal projects, and on tasks created
    // before prompts existed, which read as an empty prompt.
    var task: TaskSpec?

    var url: URL { URL(fileURLWithPath: path) }

    // Shown in the sidebar under the project name.
    var collapsedPath: String { path.abbreviatedPath }

    // Only a git checkout can back a worktree session. `.git` is a directory in a normal
    // clone and a file in a worktree or submodule, so test for either.
    var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }

    init(id: UUID = UUID(), name: String, path: String, kind: Kind = .project,
         task: TaskSpec? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.task = task
    }

    // Folder name is a good enough default title.
    init(url: URL) {
        self.init(name: url.lastPathComponent, path: url.path)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, kind, task
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? Self.legacyKind(for: path)
        task = try container.decodeIfPresent(TaskSpec.self, forKey: .task)
    }

    // Ad-hoc tasks created before the kind was stored can be identified by the private
    // directory the app has always used for them. User-selected folders keep their normal
    // project kind even when older index files do not contain this field.
    private static func legacyKind(for path: String) -> Kind {
        let parent = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        let taskRoot = AppPaths.support
            .appendingPathComponent("ad-hoc-tasks", isDirectory: true)
            .standardizedFileURL
        return parent == taskRoot ? .adHoc : .project
    }
}

// A workspace is a reusable group of projects. The lead project supplies the working
// directory for every session, while the other projects are attached to the agent.
// Membership is stored here, but each session takes its own snapshot so changing a
// workspace never changes where an existing conversation runs.
struct ProjectWorkspace: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var projectIDs: [UUID]
    var leadProjectID: UUID
    // Each session can still override its checkout mode. These are only the choices
    // preselected when a session starts, which keeps repeated workspace setup quick.
    var worktreeProjectIDs: [UUID]

    init(id: UUID = UUID(), name: String, projectIDs: [UUID], leadProjectID: UUID,
         worktreeProjectIDs: [UUID]? = nil) {
        self.id = id
        self.name = name
        self.projectIDs = projectIDs
        self.leadProjectID = leadProjectID
        self.worktreeProjectIDs = worktreeProjectIDs ?? projectIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, projectIDs, leadProjectID, worktreeProjectIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectIDs = try container.decode([UUID].self, forKey: .projectIDs)
        leadProjectID = try container.decode(UUID.self, forKey: .leadProjectID)
        // Workspaces written before checkout defaults existed already opened every Git
        // repository as a worktree, so selecting every member preserves that behavior.
        worktreeProjectIDs = try container.decodeIfPresent([UUID].self,
                                                            forKey: .worktreeProjectIDs)
            ?? projectIDs
    }
}

// One project as it was opened for a workspace session. A nil worktree path means the
// project folder itself, which keeps plain folders useful without pretending they can
// be isolated. The first item is always the lead project.
struct SessionProject: Identifiable, Codable, Equatable {
    var projectID: UUID
    var worktreePath: String?
    var worktreeBranch: String?

    var id: UUID { projectID }
}

extension String {
    func pathRelative(to directory: String) -> String? {
        let path = URL(fileURLWithPath: self).standardizedFileURL.path
        let directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard path != directory else { return "" }

        let prefix = directory == "/" ? "/" : directory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let relativePath = pathRelative(to: home) else { return self }
        return relativePath.isEmpty ? "~" : "~/\(relativePath)"
    }
}

enum MessageRole: String, Codable, Sendable {
    case user, assistant, system, instructions
}

// One tool call inside an assistant turn. `result` stays nil until Claude Code
// reports the tool_result, so the UI can show a call as still in flight.
struct ToolUse: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var input: String
    var result: String?
    var isError: Bool = false
    // How much of the turn's text had been written when this call started. It is the
    // only record of where the call belongs, since text and calls are kept apart.
    // Optional so conversations written before the app tracked it still decode; those
    // read as "before anything was said", which is how they have always been drawn.
    var textOffset: Int?
    // The call that started the agent which made this one, when it was not the main
    // loop that made it. Every call of a whole fan-out arrives in the same flat stream,
    // so this is the only thing that says which agent was working.
    var parentID: String?
    // The last thing an agent said while it worked, kept only for the call that started
    // it. A fan-out can run for many minutes with nothing else to show for it.
    var status: String?
    // Where in the file an edit landed, counted from 1. Neither CLI says, so it is read
    // off disk the moment the call reports in, while what is on disk is still what the
    // call wrote. Nil when the file could not be read or the call was not an edit, which
    // is what leaves a diff without a line gutter.
    var editStartLine: Int?
    // What the call left behind on disk, for a call whose own input does not say. Filled
    // in once the snapshot behind it comes back, which is a beat after the result. Nil for
    // an edit, which describes its own change, and for a call that changed nothing.
    var written: WrittenChange?

    var isRunning: Bool { result == nil }

    // Calls that stand for an agent rather than for work done in this conversation.
    // Their rows read as a container: what matters is what ran inside them.
    static let agentTools: Set<String> = ["Task", "Agent", "Workflow"]

    var startsAgents: Bool { Self.agentTools.contains(name) }

    // Calls that arrive carrying the change they are about to make. Everything else has to
    // be measured against the working tree to know what it did.
    static let editTools: Set<String> = ["Edit", "Write", "Delete"]
}

// A change git saw a call make, worked out by comparing the working tree before and after
// it ran. Kept with the call rather than derived again on demand: the trees it came from
// are unreachable the moment they are taken, and the worktree itself may be gone by the
// time anyone reads the conversation back.
struct WrittenChange: Codable, Equatable, Sendable {
    var files = 0
    var added = 0
    var removed = 0
    // The change itself, as a unified patch covering every file. Nil when it was too large
    // to be worth reading inline, which leaves the counts above and nothing to unfold.
    var patch: String?
}

// One call and everything that ran inside it. A turn's calls are stored flat, in the
// order the stream gave them, and this is that list read as what it really is.
struct ToolNode: Identifiable {
    let tool: ToolUse
    var children: [ToolNode] = []
    // Where the call sat in the turn's flat list, which is the order it happened in.
    // Kept so the newest call of a whole subtree can be found again once the list has
    // been folded into a tree and the order between branches is gone.
    var order = 0

    var id: String { tool.id }

    // Every call inside this one, however deep.
    var callCount: Int { children.reduce(children.count) { $0 + $1.callCount } }

    // Every call inside this one that stood up an agent, counted as deep as calls are.
    var agentCount: Int {
        children.reduce(0) { $0 + ($1.tool.startsAgents ? 1 : 0) + $1.agentCount }
    }

    // Read by the folded block, which has to flag a failure it is otherwise hiding.
    var hasError: Bool { tool.isError || children.contains(where: \.hasError) }

    // Also read by the folded block, which stays open while there is work to watch. An
    // agent sent to the background hands back its own result at once and keeps going, so
    // the only calls still in flight can be its children.
    var hasRunning: Bool { tool.isRunning || children.contains(where: \.hasRunning) }

    // The newest call anywhere inside this one: what the agents are doing right now.
    var newestDescendant: ToolNode? {
        children.flatMap { [$0] + ($0.newestDescendant.map { [$0] } ?? []) }
            .max { $0.order < $1.order }
    }
}

// One stretch of the model's reasoning, kept apart from what it said out loud. The
// offsets record where in the turn it happened, the same way a tool call carries its
// text offset, so the turn can be read back in the order it ran.
struct ThinkingSegment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var text: String
    // How much of the turn's text had been written when this arrived.
    var textOffset = 0
    // How many calls the turn had made when this arrived. Text alone cannot place a
    // thought between two rounds of calls that spoke no words between them.
    var toolOffset = 0
}

// A run of the turn laid out in the order it happened: some text Claude wrote, a stretch
// of thinking, or the calls it made at that point. Adjacent calls that started at the
// same point ran as one round, so they stay together and are drawn as a single spine.
enum MessageBlock: Identifiable {
    case prose(id: Int, text: String)
    case thinking(id: Int, text: String)
    case tools(id: Int, [ToolNode])

    var id: Int {
        switch self {
        case .prose(let id, _), .thinking(let id, _), .tools(let id, _): return id
        }
    }
}

// The resume ids as they stood before a prompt ran, written on that prompt's message.
// Claude Code forks a new id on every resumed turn, so an id recorded here keeps
// pointing at the conversation as it was then - which is what makes rewinding to the
// message, or forking a new session from it, possible. Codex reuses one thread for the
// whole conversation, so a Codex turn cannot be wound back; the agent that ran the
// turn is recorded to tell the two apart.
struct ConversationCheckpoint: Codable, Equatable, Sendable {
    var agent: AgentKind
    var claudeSessionID: String?
    var codexSessionID: String?
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var role: MessageRole
    var text: String = ""
    var tools: [ToolUse] = []
    var date: Date = Date()
    // Paths of the files sent with a user turn. Optional so conversations written before
    // the app could take attachments still decode.
    var attachments: [String]?
    // The model's reasoning, in the order it happened. Optional so conversations written
    // before the app kept thinking still decode.
    var thinking: [ThinkingSegment]?
    // Where the conversation stood when this prompt ran. Only prompts that start a turn
    // carry one; a prompt sent into a turn already running does not mark a point the
    // conversation could go back to.
    var checkpoint: ConversationCheckpoint?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tools.isEmpty
            && (attachments?.isEmpty ?? true)
            && (thinking?.isEmpty ?? true)
    }

    // The turn's calls read as a tree: a call an agent made hangs under the call that
    // started that agent. A child whose parent is not in the turn is left at the top
    // level rather than dropped, so a stream that lost an event still shows the work.
    var toolTree: [ToolNode] {
        let positions = Dictionary(tools.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        var childrenOf: [String: [ToolUse]] = [:]
        var roots: [ToolUse] = []
        for tool in tools {
            if let parent = tool.parentID, parent != tool.id, positions[parent] != nil {
                childrenOf[parent, default: []].append(tool)
            } else {
                roots.append(tool)
            }
        }
        // Only a root can be reached from a root, and a call has one parent, so a chain
        // that pointed back at itself would sit outside this walk entirely - it cannot
        // recur forever.
        func node(_ tool: ToolUse) -> ToolNode {
            ToolNode(tool: tool,
                     children: (childrenOf[tool.id] ?? []).map(node),
                     order: positions[tool.id] ?? 0)
        }
        return roots.map(node)
    }

    // The turn put back together in the order it came in. The stream gives text, thinking
    // and calls as separate events and the app stores them apart, so this is what stops a
    // call the model made after speaking from being drawn above what it said.
    var blocks: [MessageBlock] {
        var blocks: [MessageBlock] = []
        // Where in the text the last block ended. Calls and thoughts arrive in order, so
        // this only ever moves forwards - which is what lets the walk stay linear: the
        // index advances from where it is instead of being measured from the start.
        var cursor = 0
        var cursorIndex = text.startIndex
        let length = text.count

        func emitProse(upTo offset: Int) {
            let end = min(max(offset, cursor), length)
            guard end > cursor else { return }
            let endIndex = text.index(cursorIndex, offsetBy: end - cursor)
            blocks.append(.prose(id: blocks.count, text: String(text[cursorIndex..<endIndex])))
            cursor = end
            cursorIndex = endIndex
        }

        // Both lists are already in the order they happened, so this is a plain merge.
        // A thought that arrived before a call goes ahead of it. It also ends the prior
        // round, even when no prose was written between the calls.
        var thoughts = ArraySlice(thinking ?? [])
        func emitThoughts(beforeText textOffset: Int, tool toolOrder: Int) {
            while let thought = thoughts.first,
                  thought.textOffset < textOffset
                    || (thought.textOffset == textOffset && thought.toolOffset <= toolOrder) {
                emitProse(upTo: thought.textOffset)
                blocks.append(.thinking(id: blocks.count, text: thought.text))
                thoughts.removeFirst()
            }
        }

        // Only the calls the main loop made set the shape of the turn. What ran inside
        // an agent is drawn under the call that started it, wherever that call sits.
        for node in toolTree {
            let textOffset = node.tool.textOffset ?? 0
            emitThoughts(beforeText: textOffset, tool: node.order)
            emitProse(upTo: textOffset)

            // Adjacent calls at the same text offset were one round. A thought or prose
            // block between them keeps separate steps separate.
            if case .tools(let id, var round)? = blocks.last,
               (round.first?.tool.textOffset ?? 0) == textOffset {
                round.append(node)
                blocks[blocks.count - 1] = .tools(id: id, round)
            } else {
                blocks.append(.tools(id: blocks.count, [node]))
            }
        }
        for thought in thoughts {
            emitProse(upTo: thought.textOffset)
            blocks.append(.thinking(id: blocks.count, text: thought.text))
        }

        if cursor < length {
            blocks.append(.prose(id: blocks.count, text: String(text[cursorIndex...])))
        }
        return blocks
    }
}

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

// A conversation with one coding agent in a project's directory. The agent is chosen
// when the session is created and stays with it, so every visible turn belongs to the
// same underlying conversation.
//
// The conversation itself is kept in a file of its own rather than in this record, so
// the app can hold every session it has ever had while only the open one costs anything.
struct ChatSession: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var projectID: UUID
    var title: String = "New session"
    var isTroubleshooting = false
    var agent: AgentKind
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
    // Optional so conversations written before the app had either still decode. Both
    // read as "nothing chosen yet" and "nothing spent yet".
    var settings: SessionSettings?
    var usage: SessionUsage?
    // The bot selected for this session. Bot filenames stay stable across launches,
    // while Non-bot has a reserved name that uses no image.
    var agentAvatarName: String?
    // Set when the agent opens a pull request from this session.
    var pullRequest: PullRequest?
    // What this run of a task was given for the holes in its prompt. The prompt itself is
    // in the transcript; this is kept so the run list can say what each run was about
    // without opening it.
    var taskValues: [String: String]?
    var summary = SessionSummary()

    // Empty until the store loads it, and empty again once nothing holds this session,
    // so nothing outside ProjectStore should reach for it: ask the store instead, which
    // is what guarantees there is a transcript here to read.
    var messages: [ChatMessage] = []
    var transcriptLoaded = false

    // When something last happened here, used for the sidebar's relative times.
    var lastActivity: Date { summary.lastMessageAt ?? createdAt }

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
        let line = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return }
        title = words.count > 48 ? String(words.prefix(48)) + "…" : words
    }

    // The transcript is read and written on its own, so it is not part of what a session
    // encodes to. It is still decoded: a file written before the split holds every
    // conversation inline, and that is what the store moves out on the first launch.
    private enum CodingKeys: String, CodingKey {
        case id, projectID, title, isTroubleshooting, agent
        case claudeSessionID, codexSessionID, createdAt
        case worktreePath, worktreeBranch
        case workspaceID, sessionProjects, settings, usage, agentAvatarName
        case pullRequest, taskValues, summary, messages
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
        isTroubleshooting = try container.decodeIfPresent(Bool.self, forKey: .isTroubleshooting)
            ?? false
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
        try container.encode(isTroubleshooting, forKey: .isTroubleshooting)
        try container.encode(agent, forKey: .agent)
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

enum SessionState: Equatable {
    case idle
    case starting
    case streaming
    // Codex reported a transport interruption but its process is still trying to finish
    // the turn. The message is kept visible until progress resumes or the turn ends.
    case reconnecting(String)
    // Codex has produced no output for long enough to be considered unresponsive, with
    // no command, question, or background task that would make silence expected.
    case stalled
    // Stop has been requested, but the process still owns its working directory until
    // termination is confirmed.
    case stopping
    // The turn has answered, but a background task it started is still running. The
    // process is held open so the task's completion can wake the agent again.
    case waiting
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .streaming, .reconnecting, .stalled, .stopping, .waiting: true
        case .idle, .failed: false
        }
    }
}

// Why a session belongs in the activity menu. A question outranks a run because it tells
// the user there is something to do, and a live run outranks an older unseen completion.
enum SessionNotice: Int, Equatable {
    case needsInput
    case running
    case finished

    init?(isBusy: Bool, needsInput: Bool, finishedUnseen: Bool) {
        if needsInput {
            self = .needsInput
        } else if isBusy {
            self = .running
        } else if finishedUnseen {
            self = .finished
        } else {
            return nil
        }
    }
}

// What the left sidebar can have selected.
enum SidebarSelection: Hashable {
    case home
    case session(UUID)
    case workspace(UUID)
}
