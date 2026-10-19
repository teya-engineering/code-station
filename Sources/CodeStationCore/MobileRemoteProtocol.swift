import Foundation

// The wire format between the Mac and a paired browser: what the phone is sent, and the
// commands it sends back. A change to any type here is a change the phone has to
// understand, which is why they are kept apart from the controller that fills them in.

// What the phone asks for. The type names the command and says which of the other
// fields matter; a command the Mac does not know fails to decode rather than being
// guessed at.
public struct RemoteCommand: Decodable, Equatable {
    public enum Kind: String, Decodable {
        case authenticate, openSession, closeSession, createSession, resync
        case sendPrompt, stopTurn, answerPermission, openConversation
    }

    public enum Answer: String, Codable, Sendable {
        // Allow, and give the session the folder the call reaches outside its own
        // (`RemotePermission.outsideDirectory`), for this turn and every one after.
        case allowOnce, allowAlways, deny, answers, allowAddingDirectory
    }

    public enum Conversation: String, Codable, Sendable { case main, design }

    // A file picked or pasted on the phone. The browser cannot hand over a path, so the
    // bytes travel inside the command as base64 and are written to disk on the Mac.
    public struct Upload: Decodable, Equatable {
        public let name: String
        public let data: String
    }

    public var conversation: Conversation?
    public let type: Kind
    public var version: Int?
    public var secret: String?
    public var prompt: String?
    public var attachments: [Upload]?
    public var requestID: String?
    public var answer: Answer?
    public var answers: [String: String]?
    public var sessionID: String?
    public var projectID: String?
    public var worktree: Bool?
}

// The list a browsing code opens on. It is compared with the last one sent before it goes
// out, so a phone sitting on the list costs nothing until something in it moves.
//
// It is Codable both ways because the station commands façade hands it to a front end
// too, and that front end may one day sit on the far side of a socket.
public struct RemoteDirectory: Codable, Equatable, Sendable {
    public let type = "directory"
    public let version = 1
    public let title: String
    public let scope: String
    public let canCreate: Bool
    public let projects: [RemoteProject]
    // The GUI's sidebar tree, for a front end that draws one: projects, tasks and
    // workspaces in the order the shared sort gives, pinned first, each with its own
    // sessions. Only the station's clients are sent it; the phone reads `projects`.
    public var containers: [RemoteContainer]?
    // How the shared preferences arrange that tree.
    public var arrangement: RemoteArrangement?
    // What the cleanup strips at the foot of the sidebar say. Only the station's clients
    // are sent it.
    public var cleanup: RemoteCleanup?
    // Who the host is handing the station over to, while it is (ADR-0003). A list from
    // the next host has none, which is how a front end knows the move is over.
    public var handingOverTo: String?

    public init(title: String, scope: String, canCreate: Bool, projects: [RemoteProject],
                containers: [RemoteContainer]? = nil, arrangement: RemoteArrangement? = nil) {
        self.title = title
        self.scope = scope
        self.canCreate = canCreate
        self.projects = projects
        self.containers = containers
        self.arrangement = arrangement
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, title, scope, canCreate, projects, containers, arrangement, cleanup, handingOverTo
    }

    // The type and version are fixed for this struct, so they are written but not read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        scope = try container.decode(String.self, forKey: .scope)
        canCreate = try container.decode(Bool.self, forKey: .canCreate)
        projects = try container.decode([RemoteProject].self, forKey: .projects)
        containers = try container.decodeIfPresent([RemoteContainer].self, forKey: .containers)
        arrangement = try container.decodeIfPresent(RemoteArrangement.self, forKey: .arrangement)
        cleanup = try container.decodeIfPresent(RemoteCleanup.self, forKey: .cleanup)
        handingOverTo = try container.decodeIfPresent(String.self, forKey: .handingOverTo)
    }
}

// What the two cleanup strips at the foot of the GUI's sidebar say: the sessions gone
// quiet past the shared age, or the cohort the sweep is about to take, and the worktrees
// no session owns any more.
public struct RemoteCleanup: Codable, Equatable, Sendable {
    // Sessions older than `oldSessionDays`, not busy and not held back by a snooze.
    public var oldSessions = 0
    public var oldSessionDays = 0
    // Projects whose snooze holds old sessions back.
    public var snoozedProjects = 0
    // The cohort the old-session sweep will delete, and when, while one waits.
    public var oldSessionsDeleting: Int?
    public var oldSessionsDeletingAt: Date?
    public var orphanedWorktrees = 0
    public var orphanedBytes: Int64 = 0
    // When automatic pruning takes the orphans, while it is on.
    public var orphansPruneAt: Date?

    public init(oldSessions: Int = 0, oldSessionDays: Int = 0, snoozedProjects: Int = 0,
                oldSessionsDeleting: Int? = nil, oldSessionsDeletingAt: Date? = nil,
                orphanedWorktrees: Int = 0, orphanedBytes: Int64 = 0, orphansPruneAt: Date? = nil) {
        self.oldSessions = oldSessions
        self.oldSessionDays = oldSessionDays
        self.snoozedProjects = snoozedProjects
        self.oldSessionsDeleting = oldSessionsDeleting
        self.oldSessionsDeletingAt = oldSessionsDeletingAt
        self.orphanedWorktrees = orphanedWorktrees
        self.orphanedBytes = orphanedBytes
        self.orphansPruneAt = orphansPruneAt
    }
}

// Why a session belongs in the Needs you stack and the running count's menu, with the
// few words the GUI's card puts under its title ("permission · bash", "question · …",
// "finished while away", "running").
public struct RemoteNotice: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case needsInput, running, finished
    }

    public let kind: Kind
    public let reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

extension RemoteNotice.Kind {
    public init(_ notice: SessionNotice) {
        switch notice {
        case .needsInput: self = .needsInput
        case .running: self = .running
        case .finished: self = .finished
        }
    }
}

// One row of the sidebar tree with the sessions under it. A workspace's sessions sit
// under the workspace; a project or task lists only the sessions of its own.
public struct RemoteContainer: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        // A task is a project made for a reusable prompt (an ad-hoc project).
        case project, task, workspace
    }

    public let id: String
    public let kind: Kind
    public let name: String
    // The folder, shortened with a tilde, or for a workspace its projects' names.
    public let path: String
    // Pinned by the person. A container holding a pinned session is also ordered first,
    // without being pinned itself.
    public let isPinned: Bool
    public let isMissing: Bool
    // How many of its sessions wait to be read.
    public let unread: Int
    // Pinned first, then the most recently active.
    public let sessions: [RemoteSessionRow]
    // A task's timer, when it has one. Optional, so a reader that predates it simply
    // ignores it.
    public var schedule: RemoteSchedule?
    // How many of its sessions say NEEDS YOU, and how many are running, for the marks a
    // folded row wears in place of its cards.
    public var needsYou = 0
    public var running = 0
    // A workspace's member projects, by name, which the sidebar filter matches as the
    // GUI's does. Nil for a project or task.
    public var members: [String]?
    // A project's or task's folder in full, on the host's machine, for a shell opened
    // there. Nil for a workspace.
    public var folder: String?
    // Until when its cleanup is snoozed, while it is. Nil for a workspace.
    public var snoozedUntil: Date?

    public init(id: String, kind: Kind, name: String, path: String, isPinned: Bool,
                isMissing: Bool, unread: Int, sessions: [RemoteSessionRow],
                schedule: RemoteSchedule? = nil, needsYou: Int = 0, running: Int = 0,
                members: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.isPinned = isPinned
        self.isMissing = isMissing
        self.unread = unread
        self.sessions = sessions
        self.schedule = schedule
        self.needsYou = needsYou
        self.running = running
        self.members = members
    }

    // The same container holding other sessions, as a filter narrows it.
    public func holding(_ sessions: [RemoteSessionRow]) -> RemoteContainer {
        RemoteContainer(id: id, kind: kind, name: name, path: path, isPinned: isPinned,
                        isMissing: isMissing, unread: unread, sessions: sessions,
                        schedule: schedule, needsYou: needsYou, running: running, members: members)
            .with(folder: folder, snoozedUntil: snoozedUntil)
    }

    func with(folder: String?, snoozedUntil: Date?) -> RemoteContainer {
        var container = self
        container.folder = folder
        container.snoozedUntil = snoozedUntil
        return container
    }
}

// How much of a session's work is walled off in worktrees of its own: every checkout
// (the GUI's WT chip) or only some, so it still shares a folder (MIXED).
public enum RemoteWorktree: String, Codable, Sendable {
    case all, partial
}

// The sort and grouping the person chose for the sidebar, shared by every front end,
// with what the GUI remembers of its folding and how many cards it shows. Folding and
// "See more" are view state per front end; these are only where each one starts.
public struct RemoteArrangement: Codable, Equatable, Sendable {
    public let sort: ProjectSort
    public let grouping: ProjectGrouping
    // How many session cards a container shows before "See N more…".
    public var sessionLimit = SidebarSessionLimit.defaultLimit
    // The By Type sections folded down to their heading.
    public var collapsedSections: Set<SidebarGroup> = []
    // The containers opened or closed by hand, by id. One with no entry is open when it
    // is a workspace or the current project, and closed otherwise.
    public var expansion: [String: Bool] = [:]

    public init(sort: ProjectSort, grouping: ProjectGrouping,
                sessionLimit: Int = SidebarSessionLimit.defaultLimit,
                collapsedSections: Set<SidebarGroup> = [], expansion: [String: Bool] = [:]) {
        self.sort = sort
        self.grouping = grouping
        self.sessionLimit = sessionLimit
        self.collapsedSections = collapsedSections
        self.expansion = expansion
    }
}

public struct RemoteProject: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let tint: String
    public let tintInk: String
    // Whether a session here can have a checkout of its own, which is the one choice the
    // phone offers when starting one.
    public let isGit: Bool
    public let isMissing: Bool
    public let sessions: [RemoteSessionRow]
    // A task's timer, when it has one. Optional, so a reader that predates it simply
    // ignores it.
    public var schedule: RemoteSchedule?

    public init(id: String, name: String, path: String, tint: String, tintInk: String, isGit: Bool, isMissing: Bool, sessions: [RemoteSessionRow], schedule: RemoteSchedule? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.tint = tint
        self.tintInk = tintInk
        self.isGit = isGit
        self.isMissing = isMissing
        self.sessions = sessions
        self.schedule = schedule
    }
}

// A task's timer as a front end shows it. A run that needs confirmation waits here until
// a front end answers it (`StationInterface.confirmScheduledRun`).
public struct RemoteSchedule: Codable, Equatable, Sendable {
    // What the timer is set to, as the GUI words it ("Every 15 minutes").
    public let summary: String
    // Whether the timer is on and still has runs to make.
    public let isActive: Bool
    // Whether a due run is waiting for a person to confirm, skip it or turn the timer off.
    public let isWaiting: Bool
    // When the next run is due, while the timer is on and nothing is waiting.
    public let nextRunAt: Date?

    public init(summary: String, isActive: Bool, isWaiting: Bool, nextRunAt: Date?) {
        self.summary = summary
        self.isActive = isActive
        self.isWaiting = isWaiting
        self.nextRunAt = nextRunAt
    }

    public init(_ schedule: TaskSchedule) {
        self.init(summary: schedule.summary, isActive: schedule.isActive,
                  isWaiting: schedule.isActive && schedule.isWaitingForConfirmation,
                  nextRunAt: schedule.isActive ? schedule.nextRunAt : nil)
    }
}

public struct RemoteSessionRow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let agent: String
    public let workspace: String?
    public let branch: String?
    public let state: String
    public var conversation: RemoteCommand.Conversation = .main
    public let lastActivity: Date
    public let added: Int
    public let removed: Int
    // Why the session's last turn failed, when it did. The state word already asks for
    // the person; this says what went wrong. Optional, so a reader that predates it
    // simply ignores it.
    public var failure: String?
    // What the agent is waiting on the person for, when it is: "permission" or
    // "question", as `RemotePermission.kind` names them. NEEDS YOU also covers a turn
    // that has only finished, so this is what tells a blocked agent apart from it.
    // Optional, like `failure`.
    public var needsInput: String?
    // Pinned by the person, which keeps it first in its container.
    public var isPinned = false
    // A finished turn nobody has seen yet, or marked by the person to come back to.
    public var isUnread = false
    // The line under a card's title: the call in flight ("Bash · swift build"), what
    // holds the turn open, or the last call. Nil when there is nothing to say.
    public var activity: String?
    // Whether the session works in worktrees of its own, wholly or in part. Nil when it
    // works in the project folders.
    public var worktree: RemoteWorktree?
    // A session started to diagnose a problem (the GUI's TROUBLESHOOT chip).
    public var isTroubleshooting = false
    // A folder the session works in holds work not yet committed. Only the station's
    // tree fills it, once the folder has been looked at.
    public var hasUncommittedChanges = false
    // Why the session belongs in the Needs you stack or the running count, when it does.
    public var notice: RemoteNotice?
    // The folder the session works in (its lead checkout), on the host's machine, for a
    // shell opened there. Only the station's tree fills it.
    public var folder: String?

    public init(id: String, title: String, agent: String, workspace: String?, branch: String?, state: String, conversation: RemoteCommand.Conversation = .main, lastActivity: Date, added: Int, removed: Int, failure: String? = nil, needsInput: String? = nil, isPinned: Bool = false, isUnread: Bool = false) {
        self.id = id
        self.title = title
        self.agent = agent
        self.workspace = workspace
        self.branch = branch
        self.state = state
        self.conversation = conversation
        self.lastActivity = lastActivity
        self.added = added
        self.removed = removed
        self.failure = failure
        self.needsInput = needsInput
        self.isPinned = isPinned
        self.isUnread = isUnread
    }
}

public struct RemoteHeader: Codable, Equatable, Sendable {
    public let title: String
    public let project: String
    public let agent: String
    public let branch: String?
    public let state: String
    // What the elapsed time on the strip counts from: the start of the turn while one is
    // running, and the last thing that happened otherwise.
    public let since: Date
    public let failure: String?
    public let isBusy: Bool
    public let added: Int
    public let removed: Int
    public let context: Double?
    public let queuedPrompts: Int
    public let hasEarlierMessages: Bool
    // What the top bar over a session shows besides the above, as the GUI's identity deck
    // does. All optional, so an older reader and an older host still understand each other.
    // The workspace the session belongs to, or its project.
    public var container: String?
    public var containerKind: RemoteContainer.Kind?
    public var isTroubleshooting: Bool?
    // The model's title, once the agent has said which one it runs.
    public var model: String?
    // What the session has spent, left out when the agent reports none or the shared
    // settings hide cost for that agent.
    public var cost: Double?
    public var pullRequests: [PullRequest]?
    // How many files the working tree has changed. Nil until git has answered for it.
    public var files: Int?
    // Agents the session started that are working now, and ones that failed since the
    // last prompt.
    public var agentsRunning: Int?
    public var agentsFailed: Int?
    // What the session offers besides a prompt: rename, pin, continue, rewind, the recap
    // and the suggested next prompt (see `RemoteSessionUpkeep`).
    public var upkeep: RemoteSessionUpkeep?
    // Whether the GUI's context actions are on offer now: Compact (Claude Code only) and
    // Clear, each only with a conversation to act on and no turn running.
    public var canCompact: Bool?
    public var canClear: Bool?
    // The tabs that apply to the session, in the GUI's order (see `RemoteSessionTab`).
    public var tabs: [RemoteSessionTab]?
    // What the GUI's warning strip says under the decks, most pressing first.
    public var warnings: [RemoteWarning]?
    // The tool call of the agent the agents indicator jumps to: the first running one,
    // or else the first that failed since the last prompt.
    public var agentToolID: String?

    public init(title: String, project: String, agent: String, branch: String?, state: String, since: Date, failure: String?, isBusy: Bool, added: Int, removed: Int, context: Double?, queuedPrompts: Int, hasEarlierMessages: Bool,
                container: String? = nil, containerKind: RemoteContainer.Kind? = nil, isTroubleshooting: Bool? = nil,
                model: String? = nil, cost: Double? = nil, pullRequests: [PullRequest]? = nil, files: Int? = nil,
                agentsRunning: Int? = nil, agentsFailed: Int? = nil) {
        self.container = container
        self.containerKind = containerKind
        self.isTroubleshooting = isTroubleshooting
        self.model = model
        self.cost = cost
        self.pullRequests = pullRequests
        self.files = files
        self.agentsRunning = agentsRunning
        self.agentsFailed = agentsFailed
        self.title = title
        self.project = project
        self.agent = agent
        self.branch = branch
        self.state = state
        self.since = since
        self.failure = failure
        self.isBusy = isBusy
        self.added = added
        self.removed = removed
        self.context = context
        self.queuedPrompts = queuedPrompts
        self.hasEarlierMessages = hasEarlierMessages
    }
}

public struct RemoteSnapshot: Codable, Equatable, Sendable {
    public let type = "snapshot"
    public let version = 1
    public let sessionID: String
    // Whether there is a list to go back to, which is what puts the back arrow on the
    // header of a session opened from a project or from the whole app.
    public let canBrowse: Bool
    public var conversation: RemoteCommand.Conversation = .main
    public var scope: String = "This session only"
    public let header: RemoteHeader
    public let messages: [RemoteMessage]
    public let queued: [RemoteQueuedPrompt]
    public let permission: RemotePermission?

    public init(sessionID: String, canBrowse: Bool = true, conversation: RemoteCommand.Conversation = .main, scope: String = "All projects", header: RemoteHeader, messages: [RemoteMessage], queued: [RemoteQueuedPrompt], permission: RemotePermission?) {
        self.sessionID = sessionID
        self.canBrowse = canBrowse
        self.conversation = conversation
        self.scope = scope
        self.header = header
        self.messages = messages
        self.queued = queued
        self.permission = permission
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, sessionID, canBrowse, conversation, scope, header, messages, queued, permission
    }

    // The type and version are fixed for this struct, so they are written but not read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        canBrowse = try container.decode(Bool.self, forKey: .canBrowse)
        conversation = try container.decodeIfPresent(RemoteCommand.Conversation.self, forKey: .conversation) ?? .main
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        header = try container.decode(RemoteHeader.self, forKey: .header)
        messages = try container.decode([RemoteMessage].self, forKey: .messages)
        queued = try container.decode([RemoteQueuedPrompt].self, forKey: .queued)
        permission = try container.decodeIfPresent(RemotePermission.self, forKey: .permission)
    }
}

// Only the parts that moved. An absent field means the phone should keep what it has, which
// is why a cleared permission needs a flag of its own rather than a missing one.
public struct RemoteUpdate: Codable, Equatable, Sendable {
    public let type = "update"
    public let version = 1
    public var header: RemoteHeader?
    public var order: [String]?
    public var changed: [RemoteChange]?
    public var queued: [RemoteQueuedPrompt]?
    public var permission: RemotePermission?
    public var permissionCleared: Bool?

    public var isEmpty: Bool {
        header == nil && order == nil && changed == nil && queued == nil
            && permission == nil && permissionCleared == nil
    }

    public init(header: RemoteHeader? = nil, order: [String]? = nil, changed: [RemoteChange]? = nil, queued: [RemoteQueuedPrompt]? = nil, permission: RemotePermission? = nil, permissionCleared: Bool? = nil) {
        self.header = header
        self.order = order
        self.changed = changed
        self.queued = queued
        self.permission = permission
        self.permissionCleared = permissionCleared
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, header, order, changed, queued, permission, permissionCleared
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(RemoteHeader.self, forKey: .header)
        order = try container.decodeIfPresent([String].self, forKey: .order)
        changed = try container.decodeIfPresent([RemoteChange].self, forKey: .changed)
        queued = try container.decodeIfPresent([RemoteQueuedPrompt].self, forKey: .queued)
        permission = try container.decodeIfPresent(RemotePermission.self, forKey: .permission)
        permissionCleared = try container.decodeIfPresent(Bool.self, forKey: .permissionCleared)
    }
}

public struct RemoteQueuedPrompt: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let attachments: [String]

    public init(_ prompt: SessionRunner.QueuedPrompt) {
        id = prompt.id.uuidString
        text = prompt.text
        attachments = prompt.attachments.map(\.name)
    }
}

// A "full" change replaces the message outright. A "patch" carries only the fields it names:
// text to add to the end, and the tools whose contents moved.
public struct RemoteChange: Codable, Equatable, Sendable {
    public let kind: String
    public let id: String
    public var role: String?
    public var date: Date?
    public var text: String?
    public var textAppend: String?
    public var attachments: [String]?
    public var blocks: [RemoteBlock]?
    public var tools: [RemoteTool]?

    public static func full(_ message: RemoteMessage) -> RemoteChange {
        RemoteChange(kind: "full", id: message.id, role: message.role, date: message.date,
                     text: message.text, attachments: message.attachments,
                     blocks: message.blocks)
    }

    public static func patch(id: String, textAppend: String?, tools: [RemoteTool]?) -> RemoteChange {
        RemoteChange(kind: "patch", id: id, textAppend: textAppend, tools: tools)
    }
}

public struct RemoteMessageDigest: Equatable {
    public let role: String
    public let date: Date
    public let textCount: Int
    public let textHash: Int
    public let structure: Int
    public let attachments: Int
    public let toolOrder: [String]
    public let tools: [String: Int]
}

public enum RemoteTranscriptDiff {
    public static func digest(of message: RemoteMessage) -> RemoteMessageDigest {
        RemoteMessageDigest(
            role: message.role,
            date: message.date,
            textCount: message.text.count,
            textHash: message.text.hashValue,
            structure: message.structureDigest,
            attachments: message.attachments.hashValue,
            toolOrder: message.tools.map(\.id),
            tools: Dictionary(message.tools.map { ($0.id, $0.digest) },
                              uniquingKeysWith: { first, _ in first }))
    }

    // A live answer grows one chunk at a time, so the usual change is a longer text with
    // everything else untouched. Anything that rewrites what the phone already drew falls
    // back to the whole message, since patching it would need the old text to undo.
    public static func change(from previous: RemoteMessageDigest, to current: RemoteMessageDigest,
                       message: RemoteMessage) -> RemoteChange {
        guard previous.role == current.role,
              previous.date == current.date,
              previous.structure == current.structure,
              previous.attachments == current.attachments,
              previous.toolOrder == current.toolOrder,
              current.textCount >= previous.textCount else { return .full(message) }

        var appended: String?
        if previous.textHash != current.textHash {
            let kept = String(message.text.prefix(previous.textCount))
            guard kept.hashValue == previous.textHash else { return .full(message) }
            appended = String(message.text.dropFirst(previous.textCount))
        }

        let tools = message.tools.filter { previous.tools[$0.id] != current.tools[$0.id] }
        return .patch(id: message.id, textAppend: appended, tools: tools.isEmpty ? nil : tools)
    }
}

public struct RemoteMessage: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    // Variable so a reader can lay a patch over what it already has.
    public var text: String
    public let date: Date
    public let attachments: [String]
    public var blocks: [RemoteBlock]

    public var tools: [RemoteTool] { blocks.flatMap { $0.tools ?? [] } }

    // Prose is already covered by the text digest. This only records the layout around
    // it, so an answer can still stream as small append patches while its last prose block
    // grows.
    public var structureDigest: Int {
        var hasher = Hasher()
        for block in blocks {
            hasher.combine(block.kind)
            if block.kind == "thinking" { hasher.combine(block.text) }
            if block.kind == "tools" { block.tools?.forEach { hasher.combine($0.id) } }
        }
        return hasher.finalize()
    }

    public init(id: String, role: String, text: String, date: Date, attachments: [String] = [],
                blocks: [RemoteBlock]) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.attachments = attachments
        self.blocks = blocks
    }

    public init(_ message: ChatMessage, projectPath: String = "") {
        id = message.id.uuidString
        role = message.role.rawValue
        text = message.text
        date = message.date
        attachments = (message.attachments ?? []).map { URL(fileURLWithPath: $0).lastPathComponent }
        blocks = message.blocks.map { RemoteBlock($0, projectPath: projectPath) }
    }
}

// The Mac has already rebuilt the separate text, thought and tool streams in their true
// order. Sending that result keeps the phone on the same ordering rules, including Unicode
// text offsets and calls made by child agents.
public struct RemoteBlock: Codable, Equatable, Sendable {
    public let kind: String
    public var text: String?
    public var tools: [RemoteTool]?

    public init(kind: String, text: String? = nil, tools: [RemoteTool]? = nil) {
        self.kind = kind
        self.text = text
        self.tools = tools
    }

    public init(_ block: MessageBlock, projectPath: String) {
        switch block {
        case .prose(_, let text):
            kind = "prose"
            self.text = text
            tools = nil
        case .thinking(_, let text):
            kind = "thinking"
            self.text = text
            tools = nil
        case .tools(_, let nodes):
            kind = "tools"
            text = nil
            tools = nodes
                .flatMap(Self.flatten)
                .sorted { $0.order < $1.order }
                .map { RemoteTool($0.tool, projectPath: projectPath) }
        }
    }

    private static func flatten(_ node: ToolNode) -> [ToolNode] {
        [node] + node.children.flatMap(flatten)
    }
}

public struct RemoteTool: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    // The one argument the row is about, read the way the desktop spine reads it, so a
    // call names itself the same on both screens.
    public let argument: String
    public let added: Int?
    // Lines the call took away. Optional, so a reader that predates it ignores it.
    public var removed: Int?
    public let input: String
    public let result: String?
    public let isError: Bool
    public let isRunning: Bool

    public var digest: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(input)
        hasher.combine(result)
        hasher.combine(isError)
        hasher.combine(isRunning)
        return hasher.finalize()
    }

    public init(id: String, name: String, argument: String, added: Int? = nil, removed: Int? = nil,
                input: String = "", result: String? = nil, isError: Bool = false,
                isRunning: Bool = false) {
        self.id = id
        self.name = name
        self.argument = argument
        self.added = added
        self.removed = removed
        self.input = input
        self.result = result
        self.isError = isError
        self.isRunning = isRunning
    }

    public init(_ tool: ToolUse, projectPath: String = "") {
        let presentation = ToolPresentation(tool: tool, projectPath: projectPath)
        id = tool.id
        name = tool.name
        argument = presentation.argument
        added = presentation.added
        removed = presentation.removed
        input = tool.input
        result = tool.result
        isError = tool.isError
        isRunning = tool.isRunning
    }
}

public struct RemotePermission: Codable, Equatable, Sendable {
    public struct Question: Codable, Equatable, Sendable {
        public struct Option: Codable, Equatable, Sendable {
            public let label: String
            public let description: String
        }

        public let header: String
        public let text: String
        public let multiSelect: Bool
        public let options: [Option]
    }

    public let id: String
    // Which of the two asks this is, since the sheet names itself after it.
    public let kind: String
    public let toolName: String
    public let title: String
    public let lead: String
    public let subject: String
    public let detail: String
    // The branch the call would run on, or the project when the session has no worktree.
    public let runsIn: String
    public let alwaysTitle: String?
    public let questions: [Question]
    // The folder the call reaches outside the session's, which allowing can add to it,
    // as the GUI's card offers in place of "always". Nil when it reaches none.
    public var outsideDirectory: String?

    public init(_ request: PermissionRequest, runsIn: String) {
        id = request.id
        kind = request.isQuestion ? "question" : "permission"
        toolName = request.toolName
        title = request.title
        lead = request.toolName == "Bash"
            ? "The agent wants to run:"
            : "The agent wants to use \(request.title):"
        subject = request.subject
        detail = request.detail
        self.runsIn = runsIn
        alwaysTitle = request.alwaysTitle
        questions = request.questions.map {
            Question(header: $0.header, text: $0.text, multiSelect: $0.multiSelect,
                     options: $0.options.map {
                         Question.Option(label: $0.label, description: $0.description)
                     })
        }
    }
}

public struct RemoteError: Encodable {
    public let type = "error"
    public let message: String
    public var code: String = "commandFailed"

    public init(message: String, code: String = "") {
        self.message = message
        self.code = code
    }
}

public struct RemoteDesign: Encodable, Equatable {
    public let type = "design"
    public let sessionID: String
    public let title: String
    public let revision: String
    public let hasConversation: Bool
    public let screens: [Screen]

    public struct Screen: Encodable, Equatable {
        public let id: String
        public let title: String
        public let url: String

        public init(id: String, title: String, url: String) {
            self.id = id
            self.title = title
            self.url = url
        }
    }

    public init(sessionID: String, title: String, revision: String, hasConversation: Bool, screens: [Screen]) {
        self.sessionID = sessionID
        self.title = title
        self.revision = revision
        self.hasConversation = hasConversation
        self.screens = screens
    }
}

// Only published screens and browser assets may cross the pairing boundary. Resolving
// symlinks as well as dot segments keeps a design from exposing files outside its folder.
public enum RemoteDesignArtifacts {
    public static let contentTypes = [
        "html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "woff": "font/woff", "woff2": "font/woff2",
    ]
}
