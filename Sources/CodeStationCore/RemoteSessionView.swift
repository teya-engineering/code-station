import Foundation

// What a reader of one open session is shown, and how to tell it only what moved since.
// The phone remote and the station commands façade both build their snapshots and
// updates here, so the two cannot drift apart on what a session looks like.

// Everything a reader of a session sees at one moment.
public struct RemoteSessionState {
    public let header: RemoteHeader
    public let order: [String]
    public let messages: [RemoteMessage]
    public let digests: [String: RemoteMessageDigest]
    public let queued: [RemoteQueuedPrompt]
    public let permission: RemotePermission?

    // The session as a reader sees it now, or nil once it is gone. `messageLimit` keeps
    // only the newest messages, which is what a phone wants; nil keeps all of them.
    @MainActor
    public static func make(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner,
                            gitStats: GitStatsCache, messageLimit: Int? = nil,
                            preferences: UserDefaults = Preferences.defaults) -> RemoteSessionState? {
        guard let session = store.session(sessionID),
              let project = store.project(session.projectID) else { return nil }
        let allMessages = store.transcript(of: sessionID)
        let projectPath = store.workingDirectories(for: session).first ?? project.path
        let kept = messageLimit.map { Array(allMessages.suffix($0)) } ?? allMessages
        let visibleMessages = kept.map { RemoteMessage($0, projectPath: projectPath) }
        let queued = runner.queued(sessionID)
        let state = runner.state(sessionID)
        let tone = RemoteSessionMarker.tone(sessionID, store: store, runner: runner)
        let tree = RemoteWorkingTree(session, store: store, gitStats: gitStats)
        let facts = RemoteSessionFacts(session, project: project, messages: allMessages, store: store,
                                       runner: runner, preferences: preferences)
        var header = RemoteHeader(
            title: session.title,
            project: project.name,
            agent: session.agent.title,
            branch: tree.branch,
            state: tone.word,
            // The reader counts the elapsed time itself so a running session does not
            // need a fresh header every minute just to age its own label.
            since: tone == .running
                ? (allMessages.last { $0.role == .user }?.date ?? session.lastActivity)
                : session.lastActivity,
            failure: RemoteSessionMarker.failure(state),
            isBusy: state.isBusy,
            added: tree.added,
            removed: tree.removed,
            context: session.usage?.contextFraction(for: session.agent),
            queuedPrompts: queued.count,
            hasEarlierMessages: allMessages.count > visibleMessages.count,
            container: facts.container,
            containerKind: facts.containerKind,
            isTroubleshooting: facts.isTroubleshooting,
            model: facts.model,
            cost: facts.cost,
            pullRequests: facts.pullRequests,
            files: tree.files,
            agentsRunning: facts.agentsRunning,
            agentsFailed: facts.agentsFailed)
        header.canCompact = runner.canCompactContext(sessionID, store: store)
        header.canClear = runner.canClearContext(sessionID, store: store)
        header.tabs = RemoteSessionTab.tabs(for: session, store: store)
        header.warnings = RemoteWarning.warnings(for: session, project: project, store: store, runner: runner)
        header.agentToolID = facts.agentToolID
        header.upkeep = RemoteSessionUpkeep.make(sessionID, store: store, runner: runner, messages: allMessages)
        return RemoteSessionState(
            header: header,
            order: visibleMessages.map(\.id),
            messages: visibleMessages,
            digests: Dictionary(visibleMessages.map { ($0.id, RemoteTranscriptDiff.digest(of: $0)) },
                                uniquingKeysWith: { first, _ in first }),
            queued: queued.map(RemoteQueuedPrompt.init),
            permission: runner.question(sessionID).map {
                var permission = RemotePermission($0, runsIn: [project.name, tree.branch].compactMap { $0 }
                    .joined(separator: " / "))
                if !$0.isQuestion { permission.outsideDirectory = $0.directoryOutside(store.workingDirectories(for: session)) }
                return permission
            })
    }
}

// The cheap gate in front of a rebuild: everything a reader's view depends on, read
// without walking the transcript. An idle session costs a comparison per tick, nothing
// more.
public struct RemoteSessionMarker: Equatable {
    let transcript: Int
    let session: String
    let project: String
    let agent: String
    let branch: String
    let state: String
    let failure: String
    let added: Int
    let removed: Int
    let context: Double
    let question: String?
    let queued: [UUID]
    // What the top bar shows that the fields above do not cover. The agents it counts
    // move with the transcript's revision and with the runner's tools and agents at work.
    var files: Int?
    var container: String?
    var isTroubleshooting = false
    var model: String?
    var cost: Double?
    var pullRequests: [PullRequest] = []
    var runningTools: [String] = []
    var runningAgents: Set<String> = []
    var canCompact = false
    var canClear = false
    var tabs: [RemoteSessionTab] = []
    var warnings: [RemoteWarning] = []
    var upkeep: RemoteSessionUpkeep?

    @MainActor
    public static func make(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner,
                            gitStats: GitStatsCache,
                            preferences: UserDefaults = Preferences.defaults) -> RemoteSessionMarker {
        let session = store.session(sessionID)
        let tree = session.map { RemoteWorkingTree($0, store: store, gitStats: gitStats) }
            ?? RemoteWorkingTree(branch: nil, added: 0, removed: 0)
        let spent = session?.usage?.costUSD ?? 0
        let showsCost = session.map { Preferences.showCost(for: $0.agent, in: preferences) } ?? false
        return RemoteSessionMarker(
            transcript: store.transcriptRevision(sessionID),
            session: session?.title ?? "",
            project: session.flatMap { store.project($0.projectID)?.name } ?? "",
            agent: session?.agent.title ?? "",
            branch: tree.branch ?? "",
            state: tone(sessionID, store: store, runner: runner).word,
            failure: failure(runner.state(sessionID)) ?? "",
            added: tree.added,
            removed: tree.removed,
            context: session.flatMap { $0.usage?.contextFraction(for: $0.agent) } ?? -1,
            question: runner.question(sessionID)?.id,
            queued: runner.queued(sessionID).map(\.id),
            files: tree.files,
            container: session?.workspaceID.flatMap(store.workspace)?.name,
            isTroubleshooting: session?.isTroubleshooting ?? false,
            model: session.flatMap { $0.usage?.model(for: $0.agent) },
            cost: showsCost && spent > 0 ? spent : nil,
            pullRequests: session?.pullRequests ?? [],
            runningTools: runner.runningTools(sessionID).map(\.id),
            runningAgents: runner.runningAgents(sessionID),
            canCompact: runner.canCompactContext(sessionID, store: store),
            canClear: runner.canClearContext(sessionID, store: store),
            tabs: session.map { RemoteSessionTab.tabs(for: $0, store: store) } ?? [],
            warnings: session.flatMap { session in
                store.project(session.projectID).map {
                    RemoteWarning.warnings(for: session, project: $0, store: store, runner: runner)
                }
            } ?? [],
            upkeep: session == nil ? nil
                : RemoteSessionUpkeep.make(sessionID, store: store, runner: runner, messages: nil))
    }

    // The tone of exactly this conversation. A reader may be on a Design conversation,
    // so this does not hand the row over to a companion the way the list does.
    @MainActor
    static func tone(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner) -> SessionTone {
        let state = runner.state(sessionID)
        return SessionTone(busy: state.isBusy, needsInput: runner.question(sessionID) != nil,
                           finished: store.isUnread(sessionID), waiting: state == .waiting,
                           waitIsStale: runner.waitIsStale(sessionID))
    }

    // The state word has no room for why a turn stopped, so a failure travels beside it.
    static func failure(_ state: SessionState) -> String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}

// What one reader has already been sent. Holding digests rather than a copy of the
// transcript keeps the cost of a reader flat as the session grows.
public struct RemoteSessionBaseline {
    public var marker: RemoteSessionMarker
    var header: RemoteHeader
    var order: [String]
    var messages: [String: RemoteMessageDigest]
    var queued: [RemoteQueuedPrompt]
    var permissionID: String?

    public init(state: RemoteSessionState, marker: RemoteSessionMarker) {
        self.marker = marker
        header = state.header
        order = state.order
        messages = state.digests
        queued = state.queued
        permissionID = state.permission?.id
    }

    // Only the parts of `state` this reader has not seen. A message it never had goes
    // whole; one that grew goes as a patch where it can.
    public func update(to state: RemoteSessionState) -> RemoteUpdate {
        var changed: [RemoteChange] = []
        for message in state.messages {
            guard let current = state.digests[message.id] else { continue }
            guard let previous = messages[message.id] else {
                changed.append(.full(message))
                continue
            }
            guard previous != current else { continue }
            changed.append(RemoteTranscriptDiff.change(from: previous, to: current,
                                                       message: message))
        }
        return RemoteUpdate(
            header: header == state.header ? nil : state.header,
            order: order == state.order ? nil : state.order,
            changed: changed.isEmpty ? nil : changed,
            queued: queued == state.queued ? nil : state.queued,
            permission: permissionID == state.permission?.id ? nil : state.permission,
            permissionCleared: permissionID != nil && state.permission == nil ? true : nil)
    }
}

// What the status strip says about the working tree: the branch it is on and the lines
// it has gained and lost. Git's own count once it has answered, and the transcript's
// running total until then, so a reader has a number from the first frame.
struct RemoteWorkingTree {
    let branch: String?
    let added: Int
    let removed: Int
    // Nil until the tree has been read: the transcript's total has no file count.
    var files: Int?

    init(branch: String?, added: Int, removed: Int, files: Int? = nil) {
        self.branch = branch
        self.added = added
        self.removed = removed
        self.files = files
    }

    @MainActor
    init(_ session: ChatSession, store: ProjectStore, gitStats: GitStatsCache) {
        let snapshots = store.workingDirectories(for: session).compactMap { gitStats.snapshot(at: $0) }
        let branch = snapshots.first?.branch
            ?? session.worktreeBranch
            ?? session.sessionProjects?.compactMap(\.worktreeBranch).first
        guard !snapshots.isEmpty else {
            self.init(branch: branch, added: session.summary.added, removed: session.summary.removed)
            return
        }
        self.init(branch: branch,
                  added: snapshots.reduce(0) { $0 + $1.totalAdded },
                  removed: snapshots.reduce(0) { $0 + $1.totalRemoved },
                  files: snapshots.reduce(0) { $0 + $1.files.count })
    }
}

// What the top bar says about a session besides its title and state, read the way the
// GUI's identity deck reads it: the container, the troubleshoot mark, the model, the
// cost where it is shown, the pull requests and the agents at work or failed.
struct RemoteSessionFacts: Equatable {
    var container: String
    var containerKind: RemoteContainer.Kind
    var isTroubleshooting: Bool
    var model: String?
    var cost: Double?
    var pullRequests: [PullRequest]
    var agentsRunning: Int
    var agentsFailed: Int
    var agentToolID: String?

    @MainActor
    init(_ session: ChatSession, project: Project, messages: [ChatMessage], store: ProjectStore,
         runner: SessionRunner, preferences: UserDefaults) {
        if let workspace = session.workspaceID.flatMap(store.workspace) {
            container = workspace.name
            containerKind = .workspace
        } else {
            container = project.name
            containerKind = project.kind == .adHoc ? .task : .project
        }
        isTroubleshooting = session.isTroubleshooting
        model = session.usage?.model(for: session.agent).map { runner.modelTitle($0) }
        // Codex reports no cost, and $0.00 there would read as free rather than unknown.
        let spent = session.usage?.costUSD ?? 0
        cost = Preferences.showCost(for: session.agent, in: preferences) && spent > 0 ? spent : nil
        pullRequests = session.pullRequests
        // As the GUI's agents indicator counts them: failures only since the last prompt.
        let agents = WorkingSetSummary.activities(
            in: messages, activeTools: runner.runningTools(session.id),
            backgroundTasks: [], runningAgentIDs: runner.runningAgents(session.id),
            projectPath: store.workingDirectory(for: session) ?? "")
        let latestPrompt = messages.last(where: { $0.role == .user })?.date ?? .distantPast
        let running = agents.filter { $0.state == .running }
        let failed = agents.filter { $0.state == .failed && ($0.startedAt ?? .distantPast) >= latestPrompt }
        agentsRunning = running.count
        agentsFailed = failed.count
        agentToolID = (running.first ?? failed.first)?.sourceTool?.id
    }
}
