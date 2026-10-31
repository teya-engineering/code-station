import Darwin
import Foundation
import Observation

// Owns agent connections and turn execution. Replies stream into ProjectStore;
// unsent input belongs to the composer and resolved launch settings to AgentLaunchConfiguration.
@MainActor
@Observable
final class SessionRunner {
    let catalog: AgentCatalog

    var agent: AgentKind {
        get { catalog.agent }
        set { catalog.agent = newValue }
    }

    var defaults: SessionSettings {
        get { catalog.defaults }
        set { catalog.defaults = newValue }
    }

    var discoveredModels: [AgentKind: [ModelChoice.Option]] { catalog.discoveredModels }

    // The account's usage windows belong to an agent account rather than a session.
    // Claude Code sends them while a turn runs, so they are kept apart from Codex's
    // account usage instead of allowing the last reporting CLI to replace the other.
    private(set) var rateLimits: [AgentKind: [String: RateLimit]] = [:]
    private(set) var rateLimitsUpdatedAt: [AgentKind: Date] = [:]
    // Each event carries a snapshot of every window at the time it was sent, so only the
    // newest one speaks for the account. Older events of another kind hold older snapshots.
    private(set) var latestRateLimit: [AgentKind: RateLimit] = [:]

    // Everything the runner keeps about one session, in one place so that removing the
    // session is one delete and nothing is left behind. Most of it outlives any single
    // turn: the queue, what the last turn left to pick up, which nudge was waved away. The
    // turn itself and what it is doing right now are cleared when it ends.
    //
    // Observed one session and one field at a time. A tool call starting in one session
    // then redraws only what shows that session's tools, rather than every row that reads
    // the state of any session at all.
    @Observable
    fileprivate final class SessionRecord {
        var state: SessionState = .idle
        var turn: Turn?
        // Which avatar the next turn wears. Each turn takes the next number in order.
        var nextAvatarSequence = 0
        // The tool calls the turn is inside, oldest first. Parallel calls can nest more
        // than one.
        var runningTools: [ToolUse] = []
        // Everything the agent is waiting on, oldest first. Parallel tool calls can park
        // more than one at a time, and each is answered on its own.
        var asked: [PermissionRequest] = []
        // The agents the CLI says are still running, by the id it gave them when they
        // started. An agent sent to the background answers its own call at once and keeps
        // working, so this is the only thing that says a fan-out is still going.
        var agentsAtWork: Set<String> = []
        // What has been typed but not run yet, oldest first. Everything goes through here,
        // so a prompt typed mid-turn keeps its place behind the ones before it.
        var queue: [QueuedPrompt] = []
        // Design and Build share one checkout. A turn for one side waits here while the
        // other side is using it, then starts as soon as that turn releases the directory.
        var waitsForDesignWorkflowDirectory = false
        // The process groups this session's turns started and did not take with them.
        // A turn ending is no reason to stop a server somebody meant to leave running,
        // so they are carried until the session itself goes.
        var startedGroups: [ProcessIdentity] = []
        var isBeingRemoved = false
        // The turn that ended short and left a conversation that can be picked up again.
        // The offer stands until the next prompt is sent.
        var continuable: ResumeReason?
        // The transcript note a running compaction is writing itself into, so its outcome
        // replaces it rather than piling a second line underneath.
        var compactNoticeID: UUID?
        // Whether the current context-limit nudge has been dismissed.
        var nudgeDismissed = false
        // The next prompt the agent expects, offered under the composer. It belongs to
        // the turn that has just ended, so the next one starting takes it away.
        var suggestion: String?
        // What a held-open turn is waiting for. Kept beside the turn rather than on it: a
        // turn is a class, so a task list changing inside one is not a change any screen
        // would be told about, and the rows that name the wait would go stale.
        var wait: Wait?
        // How the last turn the user asked for ended, for the seal under its answer. Held
        // in memory only, since nothing on disk says when a turn started.
        var lastEnding: TurnEnding?

        // A turn inside a command, parked on a question or holding for a task is quiet
        // for a reason. Only silence with none of those is a turn that has stopped moving.
        func expectsSilence(from turn: Turn) -> Bool {
            !runningTools.isEmpty || !asked.isEmpty || !turn.pendingTasks.isEmpty
                || turn.waitingOnTasks
        }
    }

    private var records: [UUID: SessionRecord] = [:]

    // A record is a class, so `records[id, default: SessionRecord()].x = y` would set `x`
    // on a fresh record and throw it away. A write that may be the session's first goes
    // through here instead.
    private func recordAddingIfMissing(_ sessionID: UUID) -> SessionRecord {
        if let record = records[sessionID] { return record }
        let record = SessionRecord()
        records[sessionID] = record
        return record
    }

    let composer = SessionComposerStore()
    // Comments left on each session's changes, waiting to be sent back to its agent.
    let reviews: ReviewCommentStore
    // Second opinions on plans and answers in Chat, waiting for the person to send them.
    let opinions = ChatOpinionStore()
    // Second opinions on each Design session's screens, with the notes they pinned.
    let designOpinions = DesignOpinionStore()

    // How wide the canvas is showing the design, in CSS pixels. The agent writes HTML it
    // never sees rendered, so without this it designs for a window it imagined and the
    // layout overflows the pane the user actually has open. Only known while the canvas
    // is on screen, and left unset rather than guessed when it is not. Nothing on screen
    // reads it, so a resize does not have to redraw anything.
    @ObservationIgnored private var canvasWidths: [UUID: Double] = [:]

    @ObservationIgnored private let configs: ConfigStore?
    @ObservationIgnored private let codexContextReader = CodexContextReader()
    @ObservationIgnored private var codexContextRefreshes:
        [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private let stalledAfter: TimeInterval
    @ObservationIgnored private let stallCheckInterval: Duration
    // How long a held-open turn may sit with none of its tasks reporting before the wait
    // is called stuck. Longer than the stall threshold because a wait is legitimately
    // quiet: the turn has answered, and a build or a test run owes nothing until it ends.
    @ObservationIgnored private let waitingStaleAfter: TimeInterval
    // Nothing on screen shows the timer, so it is kept out of the record and unobserved,
    // the same as the Codex context refreshes.
    @ObservationIgnored private var waitWatchdogs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let memoryLimit: () -> UInt64
    @ObservationIgnored private let midTurnPromptDelivery: () -> PromptDelivery
    let followUps: SessionFollowUps
    // Called once for every turn that ends, however it ended.
    @ObservationIgnored var onTurnEnded: (UUID) -> Void = { _ in }

    // How a CLI says it no longer holds the conversation we asked to resume. Codex has
    // no such message: a thread it cannot find is a failed turn like any other.
    nonisolated static func lostConversation(_ agent: AgentKind) -> String? {
        switch agent {
        case .claudeCode: "No conversation found with session ID"
        case .codex: nil
        case .copilot: "No session, task, or name matched"
        }
    }
    // How each CLI says its login has lapsed. Matched loosely and without case, since the
    // wording shifts between releases; a miss only costs the shortcut, because the account
    // is also read again after every failed turn.
    nonisolated static func signedOut(_ agent: AgentKind, message: String) -> Bool {
        let phrases = switch agent {
        case .claudeCode: ["failed to authenticate", "oauth token has expired",
                           "invalid api key", "please run /login"]
        case .codex: ["codex login", "not logged in", "login has expired",
                      "refresh token", "401 unauthorized"]
        case .copilot: ["copilot login", "not authenticated", "not logged in",
                        "no authentication information"]
        }
        let lowered = message.lowercased()
        return phrases.contains { lowered.contains($0) }
    }
    // How each CLI refuses a flag or config value it does not know, which is how an
    // install older than the app needs usually shows itself. Copilot's prompt mode takes
    // an unknown flag for an unquoted prompt and says so instead.
    nonisolated static func rejectedArguments(_ message: String) -> Bool {
        ["unknown option '", "unexpected argument '", "unknown variant `", "Invalid command format."]
            .contains { message.contains($0) }
    }
    static let recoveryPrompt = """
    Inspect the current state and continue only the unfinished parts of the previous request. Do not repeat work or side effects that are already complete.
    """

    private let persistentAgentSessions: Bool

    init(preferences: UserDefaults = .standard, configs: ConfigStore? = nil, persistentAgentSessions: Bool = true, paths: [AgentKind: String]? = nil,
         discoveredModels: [AgentKind: [ModelChoice.Option]] = [:],
         stalledAfter: TimeInterval = 5 * 60,
         stallCheckInterval: Duration = .seconds(5),
         waitingStaleAfter: TimeInterval = 10 * 60,
         memoryLimit: (() -> UInt64)? = nil,
         automaticRecapsEnabled: (() -> Bool)? = nil,
         automaticTitlesEnabled: (() -> Bool)? = nil,
         promptSuggestionsEnabled: (() -> Bool)? = nil,
         midTurnPromptDelivery: (() -> PromptDelivery)? = nil) {
        self.configs = configs
        self.persistentAgentSessions = persistentAgentSessions
        // A runner that keeps nothing between launches, as tests make, keeps no review either.
        reviews = ReviewCommentStore(url: persistentAgentSessions
            ? AppPaths.supportFile("review-comments.json") : nil)
        catalog = AgentCatalog(paths: paths, discoveredModels: discoveredModels, preferences: preferences)
        self.stalledAfter = stalledAfter
        self.stallCheckInterval = stallCheckInterval
        self.waitingStaleAfter = waitingStaleAfter
        self.memoryLimit = memoryLimit ?? { Preferences.sessionMemoryLimit(in: preferences).bytes() }
        self.midTurnPromptDelivery = midTurnPromptDelivery
            ?? { Preferences.midTurnPromptDelivery(in: preferences) }
        followUps = SessionFollowUps(
            automaticRecapsEnabled: automaticRecapsEnabled ?? { Preferences.sessionRecapsEnabled(in: preferences) },
            automaticTitlesEnabled: automaticTitlesEnabled ?? { Preferences.sessionTitlesEnabled(in: preferences) },
            promptSuggestionsEnabled: promptSuggestionsEnabled ?? { Preferences.promptSuggestionsEnabled(in: preferences) })
    }

    func defaults(for agent: AgentKind) -> SessionSettings { catalog.defaults(for: agent) }
    func setDefaults(_ defaults: SessionSettings, for agent: AgentKind) {
        catalog.setDefaults(defaults, for: agent)
    }
    func isAvailable(_ agent: AgentKind) -> Bool { catalog.isAvailable(agent) }
    func refreshAvailableAgents() { catalog.refreshAvailableAgents() }
    func discoverModels(for agent: AgentKind) async { await catalog.discoverModels(for: agent) }
    func refreshDiscoveredModels() async { await catalog.refreshDiscoveredModels() }

    // The seat a session's own agent works in, which a second opinion's independence is
    // measured against. Read the way a launch reads it, falling back to the model the
    // agent last reported running on.
    func author(of session: ChatSession) -> SecondOpinion.Reviewer {
        let model = validModel(session.settings?.model, for: session.agent)
            ?? session.usage?.model(for: session.agent)
        let effort = validEffort(session.settings?.effort ?? defaults(for: session.agent).effort,
                                 for: session.agent, model: model)
        return SecondOpinion.Reviewer(agent: session.agent, model: model, effort: effort)
    }

    func modelOptions(for agent: AgentKind) -> [ModelChoice.Option] { catalog.modelOptions(for: agent) }
    func validModel(_ id: String?, for agent: AgentKind) -> String? { catalog.validModel(id, for: agent) }
    func modelTitle(_ id: String?) -> String { catalog.modelTitle(id) }
    func effortOptions(for agent: AgentKind, model: String?) -> [EffortChoice.Option] {
        catalog.effortOptions(for: agent, model: model)
    }
    func validEffort(_ id: String?, for agent: AgentKind, model: String?) -> String? {
        catalog.validEffort(id, for: agent, model: model)
    }
    func effortTitle(_ id: String?, for agent: AgentKind, model: String?) -> String {
        catalog.effortTitle(id, for: agent, model: model)
    }
    var availableAgents: [AgentKind] { catalog.availableAgents }
    func agentForNewSession(selected: AgentKind?) -> AgentKind? { catalog.agentForNewSession(selected: selected) }
    var available: Bool { catalog.available }

    func state(_ sessionID: UUID) -> SessionState { records[sessionID]?.state ?? .idle }

    func runningTool(_ sessionID: UUID) -> ToolUse? { records[sessionID]?.runningTools.last }

    // The full set is used where parallel agent calls need a row of their own.
    func runningTools(_ sessionID: UUID) -> [ToolUse] { records[sessionID]?.runningTools ?? [] }

    // Which of the agents this session started are still working, for the rows that
    // stand for them.
    func runningAgents(_ sessionID: UUID) -> Set<String> { records[sessionID]?.agentsAtWork ?? [] }

    func avatarSequence(_ sessionID: UUID) -> Int? { records[sessionID]?.turn?.avatarSequence }

    func refreshContext(_ sessionID: UUID, store: ProjectStore) {
        guard let session = store.session(sessionID), session.agent == .codex,
              let threadID = session.codexSessionID else { return }
        refreshCodexContext(threadID: threadID, sessionID: sessionID, store: store)
    }

    private func setState(_ state: SessionState, for sessionID: UUID) {
        guard self.state(sessionID) != state else { return }
        recordAddingIfMissing(sessionID).state = state
    }

    // When this session last heard anything at all from the CLI. A turn that is working
    // says something every few seconds, so a long gap here is the one visible difference
    // between a slow turn and one that has stopped moving.
    func lastActivity(_ sessionID: UUID) -> Date? { records[sessionID]?.turn?.lastActivity }

    // When the turn this session is running now began, for the strip that counts it up.
    func turnStarted(_ sessionID: UUID) -> Date? { records[sessionID]?.turn?.startedAt }

    func lastTurnEnding(_ sessionID: UUID) -> TurnEnding? { records[sessionID]?.lastEnding }

    // The tasks a held-open turn is waiting for, which is what the wait can be named
    // after. Empty for every other state, including a turn that started a task and is
    // still working alongside it.
    func backgroundTasks(_ sessionID: UUID) -> [BackgroundTask] {
        records[sessionID]?.wait?.tasks ?? []
    }

    // Tasks are live as soon as the CLI reports them. The narrower backgroundTasks view
    // above remains for places that specifically describe a turn parked on those tasks.
    func activeBackgroundTasks(_ sessionID: UUID) -> [BackgroundTask] {
        records[sessionID]?.turn?.pendingTasks ?? []
    }

    // When the wait began, so a parked session counts from the moment it stopped working
    // rather than from the start of the turn.
    func waitingSince(_ sessionID: UUID) -> Date? { records[sessionID]?.wait?.since }

    // Whether the wait has gone on long enough that it is not going to end by itself. A
    // task that never reports leaves the turn held open for good, so the state light has
    // to stop reading as a live session and start asking for someone.
    func waitIsStale(_ sessionID: UUID) -> Bool { records[sessionID]?.wait?.isStale ?? false }

    // Lets go of a turn that is only being held open for its tasks. The tasks are the
    // CLI's own children, so there is no way to keep them and end the turn: closing the
    // input is an ordinary end of turn, and the CLI stops them on its way out. The wait is
    // dropped on the click rather than on the exit that follows, so nothing on screen goes
    // on offering to end something that is already ending.
    func endWait(_ sessionID: UUID) {
        guard let record = records[sessionID], let wait = record.wait,
              let turn = record.turn else { return }
        SessionLog.note("wait ended by hand with \(wait.tasks.count) tasks running",
                        session: sessionID)
        endHold(turn, sessionID: sessionID)
        turn.endingWait = true
        if let connection = turn.connection {
            if !connection.cancelTasks() {
                requestStop(sessionID, failure: "Could not stop the agent's background tasks.")
            }
        } else {
            stopStartedGroups(sessionID, reason: "wait ended by hand")
            turn.closeInput()
        }
    }

    // The card offering this says that ending the turn stops the tasks it started, and a
    // wait nothing is going to end is the reason most people press it. Closing the input
    // only ends the CLI: a command sitting in a group of its own carries on, holding a
    // port or a lock, and the next turn meets it as something it never started.
    private func stopStartedGroups(_ sessionID: UUID, reason: String) {
        let groups = startedGroups(sessionID)
        records[sessionID]?.startedGroups = []
        guard !groups.isEmpty else { return }
        SessionLog.note("\(reason): stopping \(counted(groups.count, "process group")) "
                        + "the session started", session: sessionID)
        ShellRegistry.tasks.retire(groups)
    }

    // What the session has running outside the CLI's own group: the turn's own leaders as
    // the guard last saw them, behind the ones carried over from the turns before it.
    private func startedGroups(_ sessionID: UUID) -> [ProcessIdentity] {
        guard let record = records[sessionID] else { return [] }
        let live = record.turn?.memoryGuard?.startedGroups ?? []
        var kept: [ProcessIdentity] = []
        for group in record.startedGroups + live where group.isAlive && !kept.contains(group) {
            kept.append(group)
        }
        return kept
    }

    // What this session is waiting on the person for, if anything.
    func question(_ sessionID: UUID) -> PermissionRequest? { records[sessionID]?.asked.first }

    // Sends the answer back down the pipe the turn is parked on. An answered question is
    // also written into the transcript: the answers travel inside the tool's own input,
    // where nothing in the conversation would ever show them.
    func answer(_ request: PermissionRequest, with answer: PermissionAnswer,
                sessionID: UUID, store: ProjectStore) {
        guard let record = records[sessionID], let turn = record.turn,
              record.asked.contains(where: { $0.id == request.id }) else { return }
        records[sessionID]?.asked.removeAll { $0.id == request.id }
        AppNotifier.shared.clear(sessionID: store.userFacingSessionID(for: sessionID))
        SessionLog.note("answered \(request.toolName) \(request.id) with \(answer.logLabel)",
                        session: sessionID)

        // Approving a plan ends plan mode in both places it lives: in the process that asked,
        // and in the session's settings, which every later turn is started from.
        var settingsAfterPlan: SessionSettings?
        var leavingPlanFor: PermissionMode?
        if request.toolName == "ExitPlanMode", answer.allows,
           let session = store.session(sessionID) {
            var settings = session.settings ?? SessionSettings()
            if settings.permissionMode == .plan {
                settings.permissionMode = nil
            }
            settingsAfterPlan = settings
            leavingPlanFor = PermissionMode.afterPlan(
                settings.permissionMode ?? defaults(for: session.agent).permissionMode)
        }

        let sent = turn.connection.map { $0.answer(request, with: answer) }
            ?? request.responseLine(answer, leavingPlanFor: leavingPlanFor).map(turn.write) ?? false
        guard sent else {
            requestStop(
                sessionID,
                failure: "Could not send the answer to \(turn.agent.title). The turn has been stopped.")
            return
        }

        if let settingsAfterPlan { store.setSettings(settingsAfterPlan, for: sessionID) }

        // The answer opened the folder for the process that asked. Keeping it on the
        // session is what carries it into every turn after this one.
        if case .allowAddingDirectory(let directory) = answer {
            store.grantDirectory(directory, to: sessionID)
        }

        // The turn goes on writing after this, and what it writes has to read as having
        // come after the answer rather than above it.
        if case .answers(let given) = answer, !given.isEmpty,
           let carriesOn = store.recordAnswer(PermissionRequest.transcript(of: given),
                                              in: sessionID, continuing: turn.messageID) {
            turn.messageID = carriesOn
        }
        // What a plan was sent back with travels as the refusal's reason, which the
        // conversation would otherwise never show.
        if case .revise(let feedback) = answer,
           let carriesOn = store.recordAnswer(feedback, in: sessionID, continuing: turn.messageID) {
            turn.messageID = carriesOn
        }
    }

    // A turn that has answered and is being held open for the tasks it started.
    fileprivate struct Wait {
        var tasks: [BackgroundTask]
        // When the answer landed. The turn's own start says nothing about this: most of a
        // held-open turn can be work, or none of it can.
        let since: Date
        // Whether the wait has run past the point where a task was still going to report.
        // Stored rather than worked out from `since` on demand: a row redraws when what it
        // reads changes, and a deadline passing on its own changes nothing it can see.
        var isStale = false
    }

    enum SummaryMode: Equatable, Sendable {
        case claudeRecap
        case promptRecap
        case title(SessionTitleRequest)

        var isTitle: Bool {
            if case .title = self { return true }
            return false
        }
    }

    enum SummaryRestingState: Equatable, Sendable {
        case idle
        case failed(String)

        var sessionState: SessionState {
            switch self {
            case .idle: .idle
            case .failed(let message): .failed(message)
            }
        }
    }

    struct SummaryAttempt: Equatable, Sendable {
        let mode: SummaryMode
        let restingState: SummaryRestingState
        var recapAfterTitle = false
    }

    struct QueuedPrompt: Identifiable, Equatable, Sendable {
        let id = UUID()
        let text: String
        let attachments: [Attachment]
        let customInstructions: String?
        // The words behind a slash command, for the agents that do not know their own.
        // The line stays as it was typed in the transcript, since that is what was meant
        // and a whole command file read back would bury the conversation.
        var expansion: String? = nil
        // A command the app sends on the person's behalf rather than something they
        // typed at the agent. It travels down the same pipe but is not a line of the
        // conversation, so it does not appear as one.
        var isAppCommand = false
        var summary: SummaryAttempt? = nil
        var dictated = false

        var prompt: String {
            let text = expansion ?? text
            guard let customInstructions else { return text }
            guard !text.isEmpty else { return customInstructions }
            return "\(text)\n\n\(customInstructions)"
        }

        var transcriptMessages: [ChatMessage] {
            // The note explaining what the app is doing is already in the transcript.
            guard !isAppCommand else { return [] }
            var userMessage = ChatMessage(role: .user, text: text)
            if dictated { userMessage.dictated = true }
            if !attachments.isEmpty {
                userMessage.attachments = attachments.map(\.url.path)
            }
            guard let customInstructions else { return [userMessage] }
            return [
                userMessage,
                ChatMessage(role: .instructions, text: customInstructions),
            ]
        }
    }

    // The canvas reports its own width as it is resized. Sub-pixel changes would rewrite
    // the system prompt for no visible difference, so only whole pixels are kept.
    func recordCanvasWidth(_ width: Double, for sessionID: UUID) {
        let pixels = width.rounded()
        guard pixels > 0 else { return }
        canvasWidths[sessionID] = pixels
    }

    func forgetCanvasWidth(_ sessionID: UUID) { canvasWidths[sessionID] = nil }

    func queued(_ sessionID: UUID) -> [QueuedPrompt] { records[sessionID]?.queue ?? [] }

    func unqueue(_ id: UUID, sessionID: UUID) {
        records[sessionID]?.queue.removeAll { $0.id == id }
    }

    // Sends a waiting prompt into the turn that is running, instead of after it. When the
    // turn cannot take it the prompt keeps its place in the queue.
    @discardableResult
    func steer(_ id: UUID, sessionID: UUID, store: ProjectStore) -> Bool {
        guard let item = queued(sessionID).first(where: { $0.id == id }),
              steer(item, sessionID: sessionID, store: store) else { return false }
        records[sessionID]?.queue.removeAll { $0.id == id }
        return true
    }

    // Takes a waiting prompt back into the composer so it can be reworked before it runs.
    // A half-written draft is not thrown away: it takes the recalled prompt's place in
    // the queue, so nothing typed is ever lost.
    func recall(_ id: UUID, sessionID: UUID) {
        guard let queue = records[sessionID]?.queue,
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue[index]
        records[sessionID]?.queue.remove(at: index)
        preserveDraft(at: index, sessionID: sessionID)
        composer.restore(SessionComposerStore.Draft(text: item.text, attachments: item.attachments,
                                                     customInstructions: item.customInstructions,
                                                     dictated: item.dictated), in: sessionID)
    }

    // Moves what is in the composer into the queue at this position, so the prompt about
    // to take its place in the composer does not throw away what was typed.
    private func preserveDraft(at index: Int, sessionID: UUID) {
        let current = composer.draft(sessionID)
        guard !current.isEmpty else { return }
        recordAddingIfMissing(sessionID).queue.insert(
            QueuedPrompt(text: current.text.trimmed,
                         attachments: current.attachments,
                         customInstructions: current.customInstructions,
                         dictated: current.dictated),
            at: index)
    }

    @discardableResult
    func recallEarlier(_ sessionID: UUID, store: ProjectStore) -> Bool {
        if !composer.isWalking(sessionID), composer.draft(sessionID).text.isEmpty,
           let waiting = queued(sessionID).last {
            recall(waiting.id, sessionID: sessionID)
            return true
        }
        return composer.recallEarlier(sessionID, history: PromptHistory.entries(in: store.transcript(of: sessionID)))
    }

    @discardableResult
    func recallLater(_ sessionID: UUID, store: ProjectStore) -> Bool {
        composer.recallLater(sessionID, history: PromptHistory.entries(in: store.transcript(of: sessionID)))
    }

    // MARK: - Clearing the context

    // Why a clear did not happen, so the typed command can say so in the transcript.
    enum ClearOutcome: Equatable { case cleared, busy, nothingToClear }

    // A turn only remembers anything because it is handed a resume id, so dropping that
    // id is the whole of clearing the context: the next turn starts a conversation from
    // nothing in the same folder, on the same branch, with the same settings. Neither CLI
    // has a command for this, and neither needs one - it works the same for both.
    //
    // The transcript is left alone. It belongs to the person reading it, not to the agent.
    @discardableResult
    func clearContext(_ sessionID: UUID, store: ProjectStore) -> ClearOutcome {
        guard let session = store.session(sessionID), !isBeingRemoved(sessionID) else {
            return .nothingToClear
        }
        // The running process still holds the conversation, so clearing now would only be
        // undone the moment it reports its id back.
        guard !state(sessionID).isBusy else { return .busy }
        guard session.hasAgentConversation else { return .nothingToClear }

        for agent in AgentKind.allCases {
            store.clearAgentSessionID(agent: agent, for: sessionID)
        }
        store.markSessionSeen(sessionID)
        store.clearContextUsage(for: sessionID)
        records[sessionID]?.nudgeDismissed = false
        store.append(
            ChatMessage(role: .system,
                        text: "Context cleared. The next turn starts a fresh conversation."),
            to: sessionID)
        SessionLog.note("context cleared", session: sessionID)
        return .cleared
    }

    // Whether there is a conversation to drop and nothing running that still holds it.
    func canClearContext(_ sessionID: UUID, store: ProjectStore) -> Bool {
        guard let session = store.session(sessionID), !state(sessionID).isBusy else { return false }
        return session.hasAgentConversation
    }

    func isBeingRemoved(_ sessionID: UUID) -> Bool {
        records[sessionID]?.isBeingRemoved ?? false
    }

    // MARK: - Picking a conversation up again

    // Why a conversation that stopped short is being picked up. A failed process is gone,
    // but its conversation can still be resumed. A turn ended by hand stopped wherever it
    // had got to, which can be half way through a job worth finishing; nothing went
    // wrong, so the work is left unfinished rather than failed and is picked up on the
    // same terms. A stalled turn is retried by the app itself rather than offered.
    fileprivate enum ResumeReason {
        case failedTurn, stoppedTurn, stalledTurn

        // A failed turn is offered from the failure it shows; a stopped one from any
        // settled state.
        func isOffered(in state: SessionState) -> Bool {
            switch self {
            case .failedTurn:
                if case .failed = state { return true }
                return false
            case .stoppedTurn, .stalledTurn:
                return !state.isBusy
            }
        }

        // Says in the transcript why a turn nobody typed is about to run.
        var note: String {
            let opening = switch self {
            case .failedTurn: "Continuing after the failed turn."
            case .stoppedTurn: "Continuing after the stopped turn."
            case .stalledTurn: "Retrying the stalled turn."
            }
            return "\(opening) The agent will inspect the current state before it resumes unfinished work."
        }

        var log: String {
            switch self {
            case .failedTurn: "continuing after failed turn"
            case .stoppedTurn: "continuing after stopped turn"
            case .stalledTurn: "resuming after stalled turn"
            }
        }
    }

    func canContinueAfterFailure(_ sessionID: UUID, store: ProjectStore) -> Bool {
        canResume(sessionID, after: .failedTurn, store: store)
    }

    @discardableResult
    func continueAfterFailure(_ sessionID: UUID, store: ProjectStore) -> Bool {
        resumeIfOffered(sessionID, after: .failedTurn, store: store)
    }

    func canContinueAfterStop(_ sessionID: UUID, store: ProjectStore) -> Bool {
        canResume(sessionID, after: .stoppedTurn, store: store)
    }

    @discardableResult
    func continueAfterStop(_ sessionID: UUID, store: ProjectStore) -> Bool {
        resumeIfOffered(sessionID, after: .stoppedTurn, store: store)
    }

    private func canResume(_ sessionID: UUID, after reason: ResumeReason,
                           store: ProjectStore) -> Bool {
        guard let record = records[sessionID], record.continuable == reason,
              reason.isOffered(in: record.state), !record.isBeingRemoved,
              let session = store.session(sessionID) else { return false }
        return session.hasAgentConversation
    }

    private func resumeIfOffered(_ sessionID: UUID, after reason: ResumeReason,
                                 store: ProjectStore) -> Bool {
        guard canResume(sessionID, after: reason, store: store) else { return false }
        resume(sessionID, after: reason, store: store)
        return true
    }

    // Recovery goes through the normal queue so it gets the same ownership and process
    // checks as a prompt typed by hand.
    private func resume(_ sessionID: UUID, after reason: ResumeReason, store: ProjectStore) {
        recordAddingIfMissing(sessionID).continuable = nil
        store.markSessionSeen(sessionID)
        store.append(ChatMessage(role: .system, text: reason.note), to: sessionID)
        records[sessionID]?.queue.insert(
            QueuedPrompt(text: Self.recoveryPrompt, attachments: [], customInstructions: nil,
                         isAppCommand: true),
            at: 0)
        SessionLog.note(reason.log, session: sessionID)
        runQueue(sessionID, store: store)
    }

    // A retry stops the unresponsive process first, then resumes its saved conversation
    // through the normal queue. The original prompt is not replayed because it may have
    // already caused changes before the stream stopped moving.
    func canRetryStalled(_ sessionID: UUID, store: ProjectStore) -> Bool {
        guard let record = records[sessionID], case .stalled = record.state,
              !record.isBeingRemoved,
              let turn = record.turn, !turn.agent.asksPermissions, !turn.stopRequested,
              !record.expectsSilence(from: turn),
              let session = store.session(sessionID) else { return false }
        return session.hasAgentConversation
    }

    @discardableResult
    func retryStalled(_ sessionID: UUID, store: ProjectStore) -> Bool {
        guard canRetryStalled(sessionID, store: store),
              let turn = records[sessionID]?.turn else { return false }
        turn.restartAfterStop = true
        SessionLog.note("retry requested for stalled turn", session: sessionID)
        requestStop(sessionID)
        return true
    }

    func dismissFailure(_ sessionID: UUID) {
        guard case .failed = state(sessionID) else { return }
        records[sessionID]?.continuable = nil
        setState(.idle, for: sessionID)
    }

    // Only the exact word, and only on its own. Both CLIs have real slash commands -
    // skills, built-ins - that belong to the agent and have to travel to it untouched.
    nonisolated static func isClearCommand(_ text: String) -> Bool {
        text.trimmed.lowercased() == "/clear"
    }

    nonisolated static func isCompactCommand(_ text: String) -> Bool {
        text.trimmed.lowercased() == "/compact"
    }

    // The words typed after /plan, which may be none, or nil when the text is not the
    // command. Unlike the other two it can carry a prompt, since "plan this" is the
    // natural way to say it.
    nonisolated static func planCommandPrompt(_ text: String) -> String? {
        let line = text.trimmed
        guard line.lowercased().hasPrefix("/plan") else { return nil }
        let rest = line.dropFirst("/plan".count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return String(rest).trimmed
    }

    // The words behind a typed slash command, for an agent that would not recognise one.
    // Nil for everything else, which is nearly every prompt: only a line starting with a
    // slash is ever looked up, so the folders are read on the rare turn that needs them.
    private func expansion(of text: String, sessionID: UUID, store: ProjectStore) -> String? {
        guard text.hasPrefix("/"), let session = store.session(sessionID),
              !session.agent.expandsCommands else { return nil }
        let commands = AgentCommands.all(for: session.agent,
                                         workingDirectories: store.workingDirectories(for: session))
        return AgentCommands.expansion(of: text, in: commands)
    }

    // Runs a typed window command, saying in the transcript why if it could not. True
    // when the text was a command, whether or not anything came of it. Typing one is as
    // deliberate as any other prompt that costs a turn, so unlike the menu it does not
    // stop to ask first.
    private func handleWindowCommand(_ text: String, sessionID: UUID,
                                     store: ProjectStore) -> Bool {
        if Self.isClearCommand(text) {
            switch clearContext(sessionID, store: store) {
            case .cleared:
                break
            case .busy:
                note("The context cannot be cleared while a turn is running. Stop it first.",
                     sessionID: sessionID, store: store)
            case .nothingToClear:
                note("There is no conversation to clear yet.", sessionID: sessionID, store: store)
            }
            return true
        }
        guard Self.isCompactCommand(text) else { return false }
        guard let agent = store.session(sessionID)?.agent, agent == .claudeCode else {
            let title = store.session(sessionID)?.agent.title ?? "This agent"
            note("\(title) compacts context automatically. Manual compaction is not available.",
                 sessionID: sessionID, store: store)
            return true
        }
        if !compact(sessionID, store: store) {
            note(state(sessionID).isBusy
                 ? "The context cannot be compacted while a turn is running. Stop it first."
                 : "There is no conversation to compact yet.",
                 sessionID: sessionID, store: store)
        }
        return true
    }

    // The mode is read when a turn starts, so this takes effect from the next one. A turn
    // already running goes on in the mode it was started in.
    private func enterPlanMode(_ sessionID: UUID, store: ProjectStore) {
        guard let session = store.session(sessionID) else { return }
        var settings = session.settings ?? SessionSettings()
        settings.permissionMode = .plan
        store.setSettings(settings, for: sessionID)
        note("Plan mode is on. Claude Code will plan without changing anything, and the session goes back to its usual mode once you approve the plan.",
             sessionID: sessionID, store: store)
    }

    private func note(_ text: String, sessionID: UUID, store: ProjectStore) {
        store.append(ChatMessage(role: .system, text: text), to: sessionID)
    }

    // MARK: - Rewinding the conversation

    // Whether the conversation can go back to just before this prompt. Only prompts
    // that recorded a checkpoint qualify, and only while nothing is running - a live
    // turn still owns the conversation it would rewind.
    func canRewind(to messageID: UUID, sessionID: UUID, store: ProjectStore) -> Bool {
        guard !state(sessionID).isBusy, !isBeingRemoved(sessionID),
              store.session(sessionID) != nil else { return false }
        return store.rewindableMessageIDs(in: sessionID).contains(messageID)
    }

    // Takes the conversation back to just before this prompt: everything from it onward
    // leaves the transcript, the next turn resumes the conversation as it stood then,
    // and the prompt itself returns to the composer for another go. Only the words are
    // wound back - files the discarded turns edited keep their current state.
    func rewind(to messageID: UUID, sessionID: UUID, store: ProjectStore) {
        guard canRewind(to: messageID, sessionID: sessionID, store: store) else { return }
        let transcript = store.transcript(of: sessionID)
        guard let index = transcript.firstIndex(where: { $0.id == messageID }),
              let checkpoint = transcript[index].checkpoint else { return }
        let message = transcript[index]

        // A half-written draft is not thrown away for the returning prompt: it moves to
        // the front of the queue, the way recalling a queued prompt keeps one.
        preserveDraft(at: 0, sessionID: sessionID)
        // Instructions travel as a message of their own right after the prompt they
        // belong to, so they come back to the composer with it.
        let instructions = transcript.indices.contains(index + 1)
            && transcript[index + 1].role == .instructions ? transcript[index + 1].text : nil
        composer.restore(SessionComposerStore.Draft(
            text: message.text,
            attachments: (message.attachments ?? []).map { Attachment(url: URL(fileURLWithPath: $0)) },
            customInstructions: instructions), in: sessionID)

        store.truncateTranscript(from: messageID, in: sessionID)
        store.markSessionSeen(sessionID)
        store.restoreAgentSessionIDs(claudeSessionID: checkpoint.claudeSessionID,
                                     codexSessionID: checkpoint.codexSessionID,
                                     copilotSessionID: checkpoint.copilotSessionID,
                                     for: sessionID)
        // How full the window was described the discarded turns; the next turn
        // measures the conversation as it stands now.
        store.clearContextUsage(for: sessionID)
        records[sessionID]?.nudgeDismissed = false
        // A failure that belonged to a discarded turn has nothing to explain any more.
        setState(.idle, for: sessionID)
        store.append(
            ChatMessage(role: .system,
                        text: "Conversation rewound. The turns from this point on were discarded, and the prompt is back in the composer. Files keep their current state."),
            to: sessionID)
        SessionLog.note("conversation rewound", session: sessionID)
    }

    // MARK: - Compacting the context

    // Unlike clearing, this is the agent's own command and it costs a turn: Claude Code
    // reads the conversation, writes a summary, and carries on from that instead. The
    // resume id survives it, so nothing here has to be put back together afterwards.
    //
    // Codex compacts automatically, but `codex exec` has no equivalent manual command,
    // which is why this action is Claude Code only.
    @discardableResult
    func compact(_ sessionID: UUID, store: ProjectStore) -> Bool {
        guard canCompactContext(sessionID, store: store) else { return false }
        store.markSessionSeen(sessionID)
        // A turn that says nothing for the best part of a minute needs to say why.
        let notice = ChatMessage(role: .system, text: "Compacting the context…")
        store.append(notice, to: sessionID)
        recordAddingIfMissing(sessionID).compactNoticeID = notice.id
        records[sessionID]?.nudgeDismissed = false
        records[sessionID]?.queue.append(
            QueuedPrompt(text: "/compact", attachments: [], customInstructions: nil,
                         isAppCommand: true))
        SessionLog.note("compacting the context", session: sessionID)
        runQueue(sessionID, store: store)
        return true
    }

    func canCompactContext(_ sessionID: UUID, store: ProjectStore) -> Bool {
        guard let session = store.session(sessionID), session.agent == .claudeCode,
              !state(sessionID).isBusy, !isBeingRemoved(sessionID) else { return false }
        return session.hasAgentConversation
    }

    // The sizes either side are the point of it, so they are what the note says.
    nonisolated static func compactedNotice(preTokens: Int?, postTokens: Int?) -> String {
        switch (preTokens, postTokens) {
        case (let before?, let after?):
            "Context compacted, from \(formattedTokens(before)) tokens down to \(formattedTokens(after))."
        case (let before?, nil):
            "Context compacted. \(formattedTokens(before)) tokens were summarised. How full the window is now shows after the next turn."
        default:
            "Context compacted. The conversation so far was replaced by a summary."
        }
    }

    // MARK: - Suggesting the next prompt

    func suggestion(_ sessionID: UUID) -> String? { records[sessionID]?.suggestion }

    func dismissSuggestion(_ sessionID: UUID) {
        records[sessionID]?.suggestion = nil
    }

    // Sending the suggestion as it stands, as its own turn. The draft is left exactly as
    // it was, and a draft with words in it stops this outright: a prediction may join
    // what was typed, but it may never send over it, replace it, or throw it away.
    func sendSuggestion(_ sessionID: UUID, store: ProjectStore) {
        guard let suggestion = records[sessionID]?.suggestion,
              composer.draft(sessionID).text.isBlank else { return }
        records[sessionID]?.suggestion = nil
        send(suggestion, sessionID: sessionID, store: store)
    }

    // Taking a suggestion puts it in the composer rather than sending it, so it can be
    // read, changed or thrown away like anything else typed there.
    func takeSuggestion(_ sessionID: UUID) {
        guard let suggestion = records[sessionID]?.suggestion else { return }
        records[sessionID]?.suggestion = nil
        composer.editDraft(sessionID) { draft in
            draft.text = draft.text.isBlank ? suggestion : draft.text + " " + suggestion
        }
    }

    private func requestPromptSuggestion(_ sessionID: UUID, store: ProjectStore) {
        followUps.requestPromptSuggestion(sessionID, store: store, runner: self)
    }

    nonisolated static let recapPrompt = SessionFollowUps.recapPrompt

    func isRecapping(_ sessionID: UUID) -> Bool { hasSummary(sessionID, title: false) }
    func canRecap(_ sessionID: UUID, store: ProjectStore) -> Bool {
        followUps.canRecap(sessionID, store: store, runner: self)
    }
    @discardableResult
    func recap(_ sessionID: UUID, store: ProjectStore) -> Bool {
        followUps.requestRecap(sessionID, store: store, runner: self)
    }
    private func requestAutomaticRecap(_ sessionID: UUID, unseen: Bool, store: ProjectStore) {
        followUps.requestAutomaticRecap(sessionID, unseen: unseen, store: store, runner: self)
    }
    func isGeneratingTitle(_ sessionID: UUID, store: ProjectStore) -> Bool {
        hasSummary(followUps.titleConversationID(sessionID, store: store), title: true)
    }
    func canRegenerateTitle(_ sessionID: UUID, store: ProjectStore) -> Bool {
        followUps.canRegenerateTitle(sessionID, store: store, runner: self)
    }
    @discardableResult
    func regenerateTitle(_ sessionID: UUID, store: ProjectStore) -> Bool {
        followUps.regenerateTitle(sessionID, store: store, runner: self)
    }
    private func queueAutomaticTitle(after turn: Turn, sessionID: UUID, store: ProjectStore) -> Bool {
        followUps.queueAutomaticTitle(isFirstTurn: turn.isFirstTurn, sessionID: sessionID,
                                      store: store, runner: self)
    }

    func hasSummary(_ sessionID: UUID, title: Bool) -> Bool {
        guard let record = records[sessionID] else { return false }
        return record.turn?.summary?.mode.isTitle == title
            || record.queue.contains { $0.summary?.mode.isTitle == title }
    }

    func enqueueSummary(_ prompt: QueuedPrompt, sessionID: UUID, atFront: Bool = false,
                        start: Bool = true, store: ProjectStore) {
        if atFront { recordAddingIfMissing(sessionID).queue.insert(prompt, at: 0) }
        else { recordAddingIfMissing(sessionID).queue.append(prompt) }
        if start { runQueue(sessionID, store: store) }
    }

    func acceptSuggestion(_ suggestion: String, for sessionID: UUID) {
        records[sessionID]?.suggestion = suggestion
    }

    // MARK: - The nearly-full nudge

    // Above this the session is close enough to the end of its window to be worth
    // interrupting for. It is the same point at which the meter turns red.
    static let nearlyFullContext = 0.85

    // Where an agent's CLI was found, for the runs that ask one something outside any
    // session, such as a second opinion on a review. Nil when it is not installed.
    func executable(for agent: AgentKind) -> String? { catalog.executable(for: agent) }

    func isNudgeDismissed(_ sessionID: UUID) -> Bool {
        records[sessionID]?.nudgeDismissed ?? false
    }

    // Only until the window is dealt with. Clearing and compacting both take the nudge
    // away on their own, so a dismissal that outlived them would hide the next one too.
    func dismissNudge(_ sessionID: UUID) {
        recordAddingIfMissing(sessionID).nudgeDismissed = true
    }

    // When a prompt sent during a turn reaches the agent. Now means inside the turn that is
    // running, if the agent can take it there; otherwise, and after the turn, the prompt
    // waits its turn in the queue.
    enum PromptDelivery: String { case now, afterTurn }

    // A prompt joins the queue and the queue is what runs, unless a turn is running and can
    // take the prompt now. Typing during a turn therefore costs nothing, and the ones
    // already waiting keep their order. Without a delivery the one chosen in settings is used.
    func send(_ prompt: String, attachments: [Attachment] = [],
              customInstructions: String? = nil, dictated: Bool = false,
              delivery: PromptDelivery? = nil,
              sessionID: UUID, store: ProjectStore) {
        guard !isBeingRemoved(sessionID), store.session(sessionID) != nil else { return }
        var text = prompt.trimmed
        let instructions = customInstructions?.trimmed
        guard !text.isEmpty || !attachments.isEmpty || instructions?.isEmpty == false else { return }
        store.markSessionSeen(sessionID)
        store.setMarkedUnread(false, for: sessionID)

        // The window commands are answered by the app rather than sent on as prompts, so
        // that typing one and picking it off the meter do the same thing. Anything hanging
        // off a command would be thrown away with it, so a prompt that carries files or
        // instructions is left to run as one.
        if attachments.isEmpty, instructions?.isEmpty != false,
           handleWindowCommand(text, sessionID: sessionID, store: store) {
            return
        }
        // The CLI refuses /plan in a headless run, so the app turns it into the setting it
        // stands for. The words after it, if any, are the prompt the plan is about.
        if store.session(sessionID)?.agent == .claudeCode,
           let planPrompt = Self.planCommandPrompt(text) {
            enterPlanMode(sessionID, store: store)
            guard !planPrompt.isEmpty || !attachments.isEmpty
                    || instructions?.isEmpty == false else { return }
            text = planPrompt
        }
        let queued = QueuedPrompt(
            text: text,
            attachments: attachments,
            customInstructions: instructions?.isEmpty == false ? instructions : nil,
            expansion: expansion(of: text, sessionID: sessionID, store: store),
            dictated: dictated)
        if (delivery ?? midTurnPromptDelivery()) == .now,
           steer(queued, sessionID: sessionID, store: store) { return }
        recordAddingIfMissing(sessionID).queue.append(queued)
        runQueue(sessionID, store: store)
    }

    // Whether a prompt sent now would reach the agent inside the turn that is running.
    // Only a turn that is under way and still reading its input can take one; a turn
    // starting up, stopping, or parked on a background task cannot, and neither can a
    // summary run or a compaction.
    func canSteer(_ sessionID: UUID) -> Bool {
        guard let record = records[sessionID], let turn = record.turn, !record.isBeingRemoved,
              turn.summary == nil, turn.agent.canSteer, !turn.stopRequested,
              record.compactNoticeID == nil else { return false }
        switch record.state {
        case .streaming, .stalled: break
        default: return false
        }
        return turn.connection?.hasActiveTurn ?? turn.acceptsInput
    }

    // Hands a prompt to the turn that is running, so the agent takes it at its next step
    // instead of after everything it had planned. Claude Code reads it off its open input
    // and Codex has a request for it. False when the turn cannot take it, and the prompt
    // then waits in the queue like any other.
    private func steer(_ prompt: QueuedPrompt, sessionID: UUID, store: ProjectStore) -> Bool {
        guard canSteer(sessionID), let turn = records[sessionID]?.turn else { return false }
        let text = Self.prompt(prompt.prompt, with: prompt.attachments)
        let requestID: Int
        if let connection = turn.connection {
            guard let id = connection.steer(text) else { return false }
            requestID = id
        } else {
            guard Self.userMessageLine(text).map(turn.write) ?? false else { return false }
            // Claude Code sends no reply to a steer, so the prompt is tracked under a
            // number of the turn's own until the agent is seen to move again.
            requestID = turn.nextLocalSteerID
            turn.nextLocalSteerID -= 1
        }
        SessionLog.note("prompt steered into the running turn", session: sessionID)
        var messageIDs: [UUID] = []
        for var message in prompt.transcriptMessages {
            if message.role == .user { message.steered = true }
            store.append(message, to: sessionID)
            messageIDs.append(message.id)
        }
        // The reply so far stays above the new prompt and what the agent says next goes
        // under it, so the transcript reads in the order things happened.
        let previousReplyID = turn.messageID
        removeReplyIfEmpty(turn, sessionID: sessionID, store: store)
        openFreshReply(turn, sessionID: sessionID, store: store)
        turn.steersInFlight[requestID] = SteerInFlight(
            prompt: prompt, messageIDs: messageIDs, replyID: turn.messageID,
            previousReplyID: previousReplyID)
        return true
    }

    // Undoes what a steer put in the transcript and queues its prompt to run as a turn of
    // its own instead.
    private func takeBack(_ steer: SteerInFlight, turn: Turn, sessionID: UUID,
                          store: ProjectStore) {
        for id in steer.messageIDs { store.removeMessage(id, from: sessionID) }
        if turn.messageID == steer.replyID,
           store.transcript(of: sessionID).first(where: { $0.id == steer.replyID })?.isEmpty ?? false {
            store.removeMessage(steer.replyID, from: sessionID)
            turn.messageID = steer.previousReplyID
        }
        records[sessionID]?.queue.insert(steer.prompt, at: 0)
    }

    func sendAppCommand(_ prompt: String, attachments: [Attachment] = [],
                        sessionID: UUID, store: ProjectStore) {
        guard !isBeingRemoved(sessionID), store.session(sessionID) != nil else { return }
        store.markSessionSeen(sessionID)
        store.setMarkedUnread(false, for: sessionID)
        recordAddingIfMissing(sessionID).queue.append(QueuedPrompt(
            text: prompt,
            attachments: attachments,
            customInstructions: nil,
            isAppCommand: true))
        runQueue(sessionID, store: store)
    }

    // Starts the oldest waiting prompt, if the session is free to take it. A prompt that
    // cannot start yet stays at the head of the queue rather than being lost.
    func runQueue(_ sessionID: UUID, store: ProjectStore) {
        guard let record = records[sessionID], !record.isBeingRemoved else { return }
        // A turn that is only waiting on a background task has a live process with an
        // open pipe, so the next prompt goes straight down it instead of sitting behind
        // a timer that could run for a long while.
        if record.turn?.waitingOnTasks == true {
            injectQueued(sessionID, store: store)
            return
        }
        guard !record.state.isBusy,
              let next = record.queue.first,
              let session = store.session(sessionID) else { return }
        if next.summary == nil { records[sessionID]?.continuable = nil }

        // Two agents sharing any direct project folder would edit the same files under
        // each other. Workspace sessions therefore conflict when any root overlaps.
        if let conflict = busySession(sharingDirectoryWith: session, store: store) {
            if store.sessionsShareDesignWorkflow(sessionID, conflict.session.id) {
                records[sessionID]?.waitsForDesignWorkflowDirectory = true
                setState(.idle, for: sessionID)
                return
            }
            setState(.failed(
                "\"\(conflict.session.title)\" is already running in \(conflict.directory.abbreviatedPath). Sessions that share a folder cannot run at the same time - stop that one first, or use worktrees to run in parallel."),
                for: sessionID)
            return
        }
        records[sessionID]?.waitsForDesignWorkflowDirectory = false

        records[sessionID]?.queue.removeFirst()
        // The prediction belonged to the turn that has just ended, so starting another
        // one takes it away whether or not it was used. Forgetting the run it was asked
        // for is what stops a slow answer arriving afterwards and putting it back.
        if next.summary == nil {
            records[sessionID]?.suggestion = nil
            followUps.invalidateSuggestion(sessionID)
        }
        // Where the conversation stands right now, stamped on the prompt so it marks a
        // point that can be come back to.
        let checkpoint = ConversationCheckpoint(agent: session.agent,
                                                claudeSessionID: session.claudeSessionID,
                                                codexSessionID: session.codexSessionID,
                                                copilotSessionID: session.copilotSessionID)
        let titleSession = store.session(store.userFacingSessionID(for: sessionID)) ?? session
        let isFirstTurn = !next.isAppCommand && !session.hasStarted && !titleSession.hasStarted
            && titleSession.title == "New session"
        let ambition = next.isAppCommand || next.summary != nil
            ? nil : designAmbitionStep(sessionID, store: store)
        if let ambition { noteDesignAmbition(ambition, sessionID: sessionID, store: store) }
        for var message in next.transcriptMessages {
            if message.role == .user { message.checkpoint = checkpoint }
            store.append(message, to: sessionID)
        }
        let prompt = ambition?.changePrompt.map { "\($0)\n\n\(next.prompt)" } ?? next.prompt
        let avatarSequence = nextAvatarSequence(for: sessionID)
        launch(Self.prompt(prompt, with: next.attachments), attachments: next.attachments,
               sessionID: sessionID, store: store, avatarSequence: avatarSequence,
               canRetryWithoutResume: true, summary: next.summary,
               isFirstTurn: isFirstTurn)
    }

    // The level a Design turn is about to run with, next to the one the last Design turn
    // ran with, so a change made between turns can be marked and told to the agent.
    private struct DesignAmbitionStep {
        let current: DesignAmbition
        let previous: DesignAmbition?

        var changePrompt: String? {
            guard let previous, previous != current else { return nil }
            return current.changePrompt(from: previous)
        }
    }

    private func designAmbitionStep(_ sessionID: UUID, store: ProjectStore) -> DesignAmbitionStep? {
        guard let session = store.session(sessionID), session.isActivelyDesigning else { return nil }
        return DesignAmbitionStep(current: (session.settings?.designAmbition ?? catalog.designAmbition),
                                  previous: .valid(session.designAmbitionRan))
    }

    // The note goes in ahead of the prompt, so it sits above the turn it applies to.
    private func noteDesignAmbition(_ step: DesignAmbitionStep, sessionID: UUID, store: ProjectStore) {
        store.setDesignAmbitionRan(step.current, for: sessionID)
        if let previous = step.previous, previous != step.current {
            store.append(ChatMessage(role: .system, text: step.current.changeNote(from: previous)),
                         to: sessionID)
        }
    }

    private func nextAvatarSequence(for sessionID: UUID) -> Int {
        let next = records[sessionID]?.nextAvatarSequence ?? 0
        recordAddingIfMissing(sessionID).nextAvatarSequence = next + 1
        return next
    }

    // Claude Code takes one block of text, so a file goes over as its path and the agent
    // reads it itself. That is also how images work: the Read tool takes a picture back.
    nonisolated static func prompt(_ text: String, with attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let list = attachments.map { "- \($0.url.path)" }.joined(separator: "\n")
        guard !text.isEmpty else { return "Look at these files:\n\(list)" }
        return "\(text)\n\nAttached files:\n\(list)"
    }

    // The folders holding attachments that the agent could not otherwise reach, each one
    // named once. Paths are resolved first so a symlinked home does not make a folder
    // that is inside the project look like it is outside it.
    nonisolated static func directoriesOutside(_ workingDirectory: String,
                                               for attachments: [Attachment]) -> [String] {
        directoriesOutside([workingDirectory], for: attachments)
    }

    nonisolated static func directoriesOutside(_ workingDirectories: [String],
                                               for attachments: [Attachment]) -> [String] {
        let roots = workingDirectories.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        var directories: [String] = []
        for attachment in attachments {
            let parent = attachment.url.deletingLastPathComponent()
                .resolvingSymlinksInPath().path
            let alreadyReachable = roots.contains { parent.pathRelative(to: $0) != nil }
            guard !alreadyReachable, !directories.contains(parent) else {
                continue
            }
            directories.append(parent)
        }
        return directories
    }

    // The folder handed back is this session's own root as the person knows it, not the
    // symlink-resolved path the comparison ran on, so the message can name what they see.
    private func busySession(sharingDirectoryWith session: ChatSession, store: ProjectStore)
        -> (session: ChatSession, directory: String)? {
        let directories = store.workingDirectories(for: session)
        guard !directories.isEmpty else { return nil }
        for other in records.filter({ $0.key != session.id && $0.value.turn != nil })
            .compactMap({ store.session($0.key) }) {
            let otherDirectories = resolvedWorkingDirectories(of: other, store: store)
            let shared = directories.first { directory in
                let resolved = Self.resolved(directory)
                return otherDirectories.contains { Self.overlaps(resolved, $0) }
            }
            if let shared { return (other, shared) }
        }
        return nil
    }

    private func resolvedWorkingDirectories(of session: ChatSession,
                                            store: ProjectStore) -> [String] {
        store.workingDirectories(for: session).map(Self.resolved)
    }

    private nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // Two roots are the same working tree to an agent whenever either sits inside the
    // other, not only when they name the same folder. A repository added as one project
    // and a package inside it added as another are still two agents editing one tree.
    nonisolated static func overlaps(_ first: String, _ second: String) -> Bool {
        first.pathRelative(to: second) != nil || second.pathRelative(to: first) != nil
    }

    // Leaves whatever has streamed in so far in place.
    func stop(_ sessionID: UUID) {
        requestStop(sessionID)
    }

    // Only for the app going away. The transcripts are not given back because there is
    // nothing left to give them back to; the store writes out what is still pending as
    // part of the same shutdown.
    func stopAll() {
        for (sessionID, record) in records where record.turn != nil { requestStop(sessionID) }
        // Over a copy of the keys: stopping a session's groups writes back to `records`,
        // which the live key view is a window onto.
        for sessionID in Array(records.keys) {
            stopStartedGroups(sessionID, reason: "app quitting")
        }
    }

    func beginRemoval(_ sessionID: UUID) -> Bool {
        guard !state(sessionID).isBusy, !isBeingRemoved(sessionID) else { return false }
        recordAddingIfMissing(sessionID).isBeingRemoved = true
        return true
    }

    func cancelRemoval(_ sessionID: UUID) {
        records[sessionID]?.isBeingRemoved = false
    }

    func finishRemoval(_ sessionID: UUID) {
        stopStartedGroups(sessionID, reason: "session removed")
        codexContextRefreshes.removeValue(forKey: sessionID)?.task.cancel()
        records[sessionID] = nil
        composer.remove(sessionID)
        reviews.remove(sessionID)
        opinions.remove(sessionID)
        designOpinions.dismiss(sessionID)
        canvasWidths[sessionID] = nil
    }

    // A stop kills the process wherever it had got to, so the transcript ends mid-sentence
    // or mid-command with nothing to say why. Left unmarked that reads as a crash, and the
    // session sitting idle underneath it reads as a broken one.
    private func noteStop(_ sessionID: UUID, store: ProjectStore) {
        store.append(
            ChatMessage(role: .system, text: "Stopped. The turn ended before it finished."),
            to: sessionID)
        if store.session(sessionID)?.hasAgentConversation == true {
            recordAddingIfMissing(sessionID).continuable = .stoppedTurn
        }
    }

    private func requestStop(_ sessionID: UUID, failure: String? = nil) {
        guard let turn = records[sessionID]?.turn, !turn.stopRequested else { return }
        let reason = if turn.restartAfterStop {
            "stopping stalled turn for retry"
        } else if failure != nil {
            "stopping turn after runner failure"
        } else {
            "stopped by hand"
        }
        SessionLog.note(reason, session: sessionID)
        turn.stopRequested = true
        turn.stopFailure = failure
        records[sessionID]?.asked = []
        setState(.stopping, for: sessionID)
        turn.closeInput()
        CommandRunner.signalProcessGroup(turn.processGroup, signal: SIGTERM)
        let token = turn.token
        let processGroup = turn.processGroup
        let runner = self
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in
                guard runner.turn(sessionID, token)?.stopRequested == true else { return }
                CommandRunner.signalProcessGroup(processGroup, signal: SIGKILL)
            }
        }
    }

    // MARK: - Running one turn

    // Three steps: work out what the process is run with, start it and listen to it, then
    // hand it the prompt. Anything that stops the turn before its process exists is undone
    // here, so a turn that never ran leaves nothing behind.
    private func launch(_ prompt: String, attachments: [Attachment], sessionID: UUID,
                        store: ProjectStore, avatarSequence: Int,
                        canRetryWithoutResume: Bool,
                        summary: SummaryAttempt? = nil, isFirstTurn: Bool = false) {
        // Read the session again rather than passing it in: a retry runs after the stored
        // claudeSessionID has been cleared, and must not try to resume anything.
        guard let session = store.session(sessionID) else { return }
        guard store.project(session.projectID) != nil else {
            setState(.failed("This session's project is no longer in the app."), for: sessionID)
            return
        }
        let agent = session.agent
        guard let agentPath = catalog.executable(for: agent) else {
            setState(.failed(
                "Could not find \"\(agent.command)\" on PATH. Install the \(agent.title) CLI (\(agent.installHint)) and reopen the app."),
                for: sessionID)
            return
        }
        let workingDirectories = store.workingDirectories(for: session)
        guard let workingDirectory = workingDirectories.first else {
            setState(.failed("This session has no working directory."), for: sessionID)
            return
        }
        if let missing = workingDirectories.first(where: { path in
            var isDirectory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                || !isDirectory.boolValue
        }) {
            setState(.failed("\(missing) no longer exists."), for: sessionID)
            return
        }

        let mcpConfigURL: URL?
        do {
            mcpConfigURL = try temporaryMCPConfig(for: session, agent: agent)
        } catch {
            setState(.failed(error.localizedDescription), for: sessionID)
            return
        }

        // A turn writes into the conversation for as long as it runs, whether or not
        // anyone has it open, so the transcript is held until this turn is done with it.
        store.hold(sessionID, for: .running)

        // Where the tree stands before the turn touches it. Without this the turn's first
        // call would be credited with everything that changed since the last one ended,
        // which is whatever was edited by hand in between.
        if let git = GitInspector.tool() {
            TreeSnapshots.shared.baseline(at: workingDirectory, using: git)
        }
        // Read before the agent starts, which is long before it could make a commit.
        let startHeads = Task {
            var heads: [String: String] = [:]
            for directory in workingDirectories {
                heads[directory] = await GitInspector.head(at: directory)
            }
            return heads
        }

        // Summaries belong to the session title or recap card, so their replies stay
        // private to the turn.
        let reply = ChatMessage(role: .assistant)
        if summary == nil { store.append(reply, to: sessionID) }

        // Takes back everything above: the config file, the empty reply and the hold on
        // the transcript, then says why the turn did not run.
        func fail(_ message: String) {
            if let mcpConfigURL { try? FileManager.default.removeItem(at: mcpConfigURL) }
            if summary == nil { store.removeMessage(reply.id, from: sessionID) }
            store.release(sessionID, for: .running)
            setState(.failed(message), for: sessionID)
        }

        let plan: TurnPlan
        do {
            plan = try turnPlan(for: session, prompt: prompt, attachments: attachments,
                                workingDirectories: workingDirectories,
                                mcpConfigURL: mcpConfigURL,
                                // A recap or a title is the app talking to itself, so
                                // there is no next prompt for it to predict.
                                suggestsPrompts: summary == nil && agent.predictsPrompts
                                    && followUps.promptSuggestionsEnabled(),
                                store: store)
        } catch {
            fail(error.localizedDescription)
            return
        }

        let turn: Turn
        do {
            turn = try spawn(plan, agentPath: agentPath, workingDirectory: workingDirectory,
                             messageID: reply.id, attachments: attachments,
                             avatarSequence: avatarSequence,
                             canRetryWithoutResume: canRetryWithoutResume,
                             mcpConfigURL: mcpConfigURL, summary: summary,
                             sessionID: sessionID, store: store)
        } catch {
            SessionLog.note("could not start: \(error.localizedDescription)", session: sessionID)
            fail("Could not start \(agent.title): \(error.localizedDescription)")
            return
        }

        turn.isFirstTurn = isFirstTurn
        recordAddingIfMissing(sessionID).turn = turn
        Task { [weak turn] in
            let heads = await startHeads.value
            turn?.startHeads = heads
        }
        if let presetSessionID = plan.presetSessionID {
            turn.agentSessionID = presetSessionID
            store.setAgentSessionID(presetSessionID, agent: agent, for: sessionID)
        }
        setState(.starting, for: sessionID)
        startStallWatchdog(turn, sessionID: sessionID)
        SessionLog.note("starting \(agent.command) arguments=\(plan.arguments.count)",
                        session: sessionID)
        handOver(plan.prompt, to: turn, sessionID: sessionID)
    }

    // What one turn's process is started with, worked out before anything is spawned.
    private struct TurnPlan {
        let agent: AgentKind
        let arguments: [String]
        // The prompt as the agent receives it, which on a first turn carries the
        // workspace's other roots as well.
        let prompt: String
        // The conversation the turn was told to pick up, if there was one.
        let resumeSessionID: String?
        var resumed: Bool { resumeSessionID != nil }
        // The id a new conversation was told to use, for agents given one up front. Saved
        // as soon as the process starts: the stream only confirms it at the very end.
        var presetSessionID: String? = nil
        // Whether the CLI was asked to predict the next prompt, which it also needs
        // saying in its environment.
        var suggestsPrompts = false
        var serverLaunch: AgentServerLaunch?
        var historyDirectory: String?
    }

    private func turnPlan(for session: ChatSession, prompt: String, attachments: [Attachment],
                          workingDirectories: [String], mcpConfigURL: URL?,
                          suggestsPrompts: Bool, store: ProjectStore) throws -> TurnPlan {
        let agent = session.agent
        let resume = session.agentSessionID(for: agent).flatMap { $0.isEmpty ? nil : $0 }
        let promptForAgent = resume == nil ? workspacePrompt(prompt, session: session, store: store)
                                           : prompt
        let presetSessionID = agent == .copilot && resume == nil
            ? UUID().uuidString.lowercased() : nil
        let projectDirectories = Array(workingDirectories.dropFirst())
        let attachmentDirectories = Self.directoriesOutside(workingDirectories, for: attachments)
        let designArtifact = session.isActivelyDesigning
            ? store.designArtifactURL(for: session) : nil
        let implementationReference = session.isImplementingDesign
            ? store.implementationDesignDirectory(for: session) : nil
        if let directory = designArtifact?.deletingLastPathComponent() {
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
            } catch {
                throw Failure("Could not prepare the design canvas: \(error.localizedDescription)")
            }
        }
        let designDirectories = designArtifact.map { [$0.deletingLastPathComponent().path] } ?? []
        let referenceDirectories = implementationReference.map { [$0.path] } ?? []
        let additionalDirectories = unique(
            projectDirectories + attachmentDirectories + designDirectories
                + referenceDirectories + session.grantedDirectories)
        let writableRoots = unique(additionalDirectories + store.gitMetadataDirectories(for: session))
        let configuration = AgentLaunchConfiguration(
            agent: agent,
            settings: session.settings ?? SessionSettings(),
            defaults: defaults(for: agent),
            // A pasted screenshot or a file picked from anywhere on disk sits outside the
            // folder the agent runs in, and reading outside it needs saying so up front.
            addDirectories: additionalDirectories,
            writableRoots: writableRoots,
            resume: resume,
            newSessionID: presetSessionID,
            prompt: promptForAgent,
            mcpConfigPath: mcpConfigURL?.path,
            additionalSystemPrompt: designArtifact.map {
                AgentInstructions.designSystemPrompt(artifactURL: $0,
                                        canvasWidth: canvasWidths[session.id],
                                        ambition: (session.settings?.designAmbition ?? catalog.designAmbition))
            } ?? implementationReference.map(AgentInstructions.implementationSystemPrompt),
            suggestsPrompts: suggestsPrompts,
            discovered: discoveredModels[agent])
        let serverLaunch = persistentAgentSessions && agent != .claudeCode
            ? try AgentServerLaunch(configuration: configuration, directory: workingDirectories[0]) : nil
        return TurnPlan(agent: agent, arguments: serverLaunch?.arguments ?? configuration.arguments, prompt: promptForAgent,
                        resumeSessionID: resume, presetSessionID: presetSessionID,
                        suggestsPrompts: suggestsPrompts, serverLaunch: serverLaunch,
                        historyDirectory: session.importedOrigin.flatMap {
                            $0.agent == agent ? $0.historyOverride() : nil
                        })
    }

    // Starts the process and wires up everything that listens to it: the two output
    // pipes, batched onto the main actor, and the watch for its exit.
    private func spawn(_ plan: TurnPlan, agentPath: String, workingDirectory: String,
                       messageID: UUID, attachments: [Attachment], avatarSequence: Int,
                       canRetryWithoutResume: Bool, mcpConfigURL: URL?,
                       summary: SummaryAttempt?,
                       sessionID: UUID, store: ProjectStore) throws -> Turn {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessManager.searchPath
        if let directory = plan.historyDirectory {
            env[plan.agent.historyEnvironmentVariable] = directory
        }
        if plan.suggestsPrompts { env["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "1" }

        let out = try ProcessPipe()
        let errors = try ProcessPipe()

        // The prompt goes in as a JSON line on stdin rather than as an argument, and the
        // pipe stays open for the rest of the turn: it is the way back for the answers to
        // whatever the agent asks. Prompts are not read as flags there either, which an
        // argument starting with a dash would be.
        let input = try ProcessPipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // A turn ends when this input pipe closes, so these are the descriptors a stray
        // copy in some other process strands: the CLI would wait on a stream that still
        // has a writer and the turn would never come back.
        CommandRunner.closeOnExec(out, errors, input)

        let processGroup: pid_t
        do {
            processGroup = try CommandRunner.spawnIsolatedProcess(
                executable: agentPath,
                arguments: plan.arguments,
                currentDirectory: URL(fileURLWithPath: workingDirectory),
                environment: env,
                standardInput: input.fileHandleForReading.fileDescriptor,
                standardOutput: out.fileHandleForWriting.fileDescriptor,
                standardError: errors.fileHandleForWriting.fileDescriptor,
                descriptorsToClose: [
                    input.fileHandleForWriting.fileDescriptor,
                    out.fileHandleForReading.fileDescriptor,
                    errors.fileHandleForReading.fileDescriptor,
                ])
        } catch {
            for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                           out.fileHandleForReading, out.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting] {
                try? handle.close()
            }
            throw error
        }
        try? input.fileHandleForReading.close()
        try? out.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let agent = plan.agent
        let turn = Turn(processGroup: processGroup, agent: agent, messageID: messageID,
                        input: input, output: out, errorOutput: errors,
                        prompt: plan.prompt, workingDirectory: workingDirectory,
                        attachments: attachments, resumedFrom: plan.resumeSessionID,
                        avatarSequence: avatarSequence,
                        canRetryWithoutResume: canRetryWithoutResume,
                        mcpConfigURL: mcpConfigURL, summary: summary)
        let token = turn.token
        let runner = self
        let buffer = LineBuffer()
        let stream = StreamBatcher()

        let connection = plan.serverLaunch.map { launch in
            AgentSessionConnection(launch: launch) { data in
                do {
                    try input.fileHandleForWriting.write(contentsOf: data)
                    return true
                } catch { return false }
            }
        }
        turn.connection = connection
        let copilotStream = CopilotStream()
        let parseLine: @Sendable (String) -> [StreamEvent] = { line in
            let events = switch agent {
            case .claudeCode: StreamEvent.parse(line, projectPath: workingDirectory)
            case .codex: StreamEvent.parseCodex(line)
            case .copilot: copilotStream.parse(line)
            }
            let detail = events.isEmpty
                ? "stream event ignored bytes=\(line.utf8.count)"
                : events.map(\.logSummary).joined(separator: ", ")
            SessionLog.note("< \(detail)", session: sessionID)
            return events
        }

        // Stream reads arrive far faster than the UI needs them, so a read that changed
        // something asks for one flush a beat later rather than redrawing on every chunk.
        let scheduleFlush: @Sendable () -> Void = {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                runner.flush(stream, sessionID: sessionID, token: token, store: store)
            }
        }

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                SessionLog.note("stdout closed", session: sessionID)
                let tail = buffer.flush().flatMap(parseLine)
                if stream.append(events: tail, stdoutClosed: true) {
                    scheduleFlush()
                }
                return
            }
            let events = connection?.receive(data) ?? buffer.lines(from: data).flatMap(parseLine)
            if connection != nil, !events.isEmpty {
                SessionLog.note("< " + events.map(\.logSummary).joined(separator: ", "), session: sessionID)
            }
            // Even a line that means nothing to the app proves the CLI is alive, so the
            // clock moves on the read rather than on the events it turned into.
            if stream.append(events: events, stdoutActivity: true) {
                scheduleFlush()
            }
        }

        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                SessionLog.note("stderr closed", session: sessionID)
                if stream.append(stderrClosed: true) {
                    scheduleFlush()
                }
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            SessionLog.note("stderr bytes=\(data.count)", session: sessionID)
            if stream.append(stderr: chunk) {
                scheduleFlush()
            }
        }

        turn.memoryGuard = SessionMemoryGuard(processGroup: processGroup,
                                              limit: memoryLimit(),
                                              registry: .tasks) {
            violation in
            SessionLog.note(
                "memory limit exceeded bytes=\(violation.bytes) limit=\(violation.limit) "
                    + "largestPID=\(violation.largestPID) largestBytes=\(violation.largestBytes) "
                    + "largestName=\(violation.largestProcessName?.debugDescription ?? "unknown")",
                session: sessionID)
            Task { @MainActor in
                runner.memoryLimitExceeded(sessionID, token: token, violation: violation)
            }
        }
        if turn.memoryGuard == nil {
            SessionLog.note("memory guard could not attach to process \(processGroup)",
                            session: sessionID)
        }

        let exitMonitor = DispatchSource.makeProcessSource(
            identifier: processGroup, eventMask: .exit,
            queue: DispatchQueue.global(qos: .userInitiated))
        turn.exitMonitor = exitMonitor
        // Runs on the source's queue, so it must not inherit this method's main-actor
        // isolation: a closure that did would trap the moment the process exits.
        exitMonitor.setEventHandler { @Sendable in
            let status = CommandRunner.waitForExit(of: processGroup)
            let stopped = CommandRunner.ensureProcessGroupStopped(processGroup)
            SessionLog.note(
                stopped ? "exited with status \(status)"
                        : "process group \(processGroup) survived SIGKILL",
                session: sessionID)
            Task { @MainActor in
                if stopped {
                    runner.processExited(sessionID, token: token, status: status, store: store)
                } else {
                    runner.processGroupDidNotStop(sessionID, token: token)
                }
            }
        }
        exitMonitor.activate()
        if let connection {
            turn.taskRefresh = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    if !connection.refreshTasks() {
                        self?.requestStop(sessionID, failure: "Could not refresh the agent's background tasks.")
                        return
                    }
                }
            }
        }
        return turn
    }

    // The prompt is the first thing down the process's stdin. A prompt that cannot be
    // handed over leaves a process with nothing to do, so the turn is stopped there.
    private func handOver(_ prompt: String, to turn: Turn, sessionID: UUID) {
        let sent: Bool
        if let connection = turn.connection {
            sent = connection.start(prompt)
        } else {
            switch turn.agent {
            case .claudeCode:
                sent = Self.userMessageLine(prompt).map(turn.write) ?? false
            case .codex:
                // Codex reads the prompt off stdin until the pipe closes, and nothing
                // ever goes back down it: there are no questions to answer mid-turn.
                sent = turn.write(Data((prompt + "\n").utf8))
                if sent { turn.closeInput() }
            case .copilot:
                // Copilot was given the prompt as an argument, and it waits for stdin to
                // close before it starts, so the pipe is shut straight away.
                sent = true
                turn.closeInput()
            }
        }
        guard sent else {
            requestStop(sessionID, failure:
                "Could not start \(turn.agent.title): the prompt could not be handed over.")
            return
        }
    }

    private func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private func temporaryMCPConfig(for session: ChatSession, agent: AgentKind) throws -> URL? {
        guard agent == .claudeCode,
              let allowedNames = session.settings?.allowedMCPServerNames else { return nil }
        let claudeConfig = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json"))
        guard let configs,
              let managed = ConfigStore.mcpConfigurationData(
                from: configs.servers, allowing: allowedNames,
                taggingEnvironments: false),
              let data = ClaudeCodeManager.addingOwnServers(
                to: managed, from: claudeConfig,
                managedNames: Set(configs.servers.map(\.name))) else {
            throw Failure("Could not prepare the filtered MCP server configuration.")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-mcp-\(UUID().uuidString).json")
        guard FileManager.default.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Could not prepare the filtered MCP server configuration.")
        }
        return url
    }

    // Additional roots grant access but do not make their repository instructions part
    // of the lead project's discovery chain. The first turn names every root and asks
    // the agent to load local guidance before it edits an attached project.
    private func workspacePrompt(_ prompt: String, session: ChatSession,
                                 store: ProjectStore) -> String {
        let rows = store.checkoutProjects(for: session).enumerated().compactMap { pair -> String? in
            let (index, checkout) = pair
            guard let project = store.project(checkout.projectID) else { return nil }
            let path = checkout.worktreePath ?? project.path
            return "- \(index == 0 ? "Lead" : "Attached") \(project.name): \(path)"
        }
        guard rows.count > 1 else { return prompt }
        let context = """
        This is a multi-project workspace. The lead project is your working directory.
        The other project roots are available to the same session:
        \(rows.joined(separator: "\n"))

        Before editing an attached project, read the AGENTS.md or CLAUDE.md files that apply inside it.
        """
        return context + "\n\n" + prompt
    }

    private struct Failure: LocalizedError {
        let what: String
        init(_ what: String) { self.what = what }
        var errorDescription: String? { what }
    }

    // What the CLI expects on stdin in streaming mode: one JSON line holding a whole user
    // message.
    private static func userMessageLine(_ text: String) -> Data? {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        line.append(0x0A)
        return line
    }

    // The answer to a control request the app has no way to serve. An error response is
    // the honest one: the CLI treats it as "the host cannot do this" and carries on, which
    // is the whole point of sending anything at all.
    nonisolated static func refusalLine(requestID: String, subtype: String) -> Data? {
        let envelope: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "error", "request_id": requestID,
                         "error": "This app does not handle \"\(subtype)\" requests."],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        line.append(0x0A)
        return line
    }

    // What an agent said, cut down to the one line its row can hold. The whole of it is
    // written back to the transcript on every update, so only what can be read is kept.
    private static let statusLimit = 200

    private static func statusLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > statusLimit ? String(line.prefix(statusLimit)) + "…" : line
    }

    // MARK: - Applying the stream
    //
    // Every callback is matched against the live turn's token. A handler already in
    // flight on a background queue when a turn is stopped would otherwise land on the
    // next turn for the same session and pollute it.

    private func turn(_ sessionID: UUID, _ token: UUID) -> Turn? {
        guard let turn = records[sessionID]?.turn, turn.token == token else { return nil }
        return turn
    }

    // What a call left on disk, for the calls that do not say. Claude Code reports the
    // strings an edit swapped and nothing whatsoever about a file written through the
    // shell, so the only witness to that is the working tree, and the only moment it can
    // be read is now: the next call will write over it.
    //
    // The answer lands a beat later, after the row is already on screen. An edit that
    // carries its own diff is measured too, and its answer thrown away - without that,
    // the next call would inherit the edit's changes as its own. Codex can report several
    // paths without diffs in one finished item. They share one snapshot, then each row
    // selects its own file from that measured patch.
    //
    // Nothing here asks whether the turn is still running. A turn's last act is very often
    // to write, and it ends the moment the writing call reports in, so a change that had to
    // wait for the turn would be the one change most worth having. What the answer belongs
    // to is a call inside a message, and both of those outlive the turn that made them.
    private func noteWhatWasWritten(by toolID: String, named name: String,
                                    describesOwnChange: Bool,
                                    fallbackEditIDs: [String] = [], turn: Turn,
                                    sessionID: UUID, store: ProjectStore) {
        guard TreeSnapshots.measures(name), let git = GitInspector.tool() else { return }
        let messageID = turn.messageID
        TreeSnapshots.shared.change(at: turn.workingDirectory, using: git) { change in
            guard let change else { return }
            store.updateMessage(messageID, in: sessionID) { message in
                if !fallbackEditIDs.isEmpty {
                    // Without a patch there is no way to divide the total between rows.
                    // Keep the group total on its first row rather than repeat it on all
                    // of them as though each file made the whole change.
                    let recipients = change.patch == nil
                        ? Array(fallbackEditIDs.prefix(1)) : fallbackEditIDs
                    let ids = Set(recipients)
                    for i in message.tools.indices where ids.contains(message.tools[i].id) {
                        message.tools[i].written = change
                    }
                } else if !describesOwnChange,
                          let i = message.tools.firstIndex(where: { $0.id == toolID }) {
                    message.tools[i].written = change
                }
            }
        }
    }

    private func apply(_ events: [StreamEvent], sessionID: UUID, token: UUID, store: ProjectStore) {
        guard let turn = turn(sessionID, token) else { return }
        let completedToolIDs = Set(events.compactMap { event -> String? in
            guard case .toolResult(let id, _, _, _) = event else { return nil }
            return id
        })
        let instantEdits = events.compactMap { event -> ToolUse? in
            guard case .toolUse(let tool) = event, completedToolIDs.contains(tool.id),
                  ToolUse.editTools.contains(tool.name)
            else { return nil }
            return tool
        }
        let instantEditIDs = Set(instantEdits.map(\.id))
        let firstInstantEditID = instantEdits.first?.id
        let fallbackEditIDs = instantEdits.filter { !$0.describesOwnChange }.map(\.id)
        turn.lastActivity = Date()
        if case .stalled = state(sessionID) {
            setState(.streaming, for: sessionID)
        }
        for event in events {
            if event.isAnswering {
                turn.answered = true
                // The agent moving on after a steer is the only word Claude Code gives
                // that the prompt reached it.
                for key in turn.steersInFlight.keys { turn.steersInFlight[key]?.answered = true }
            }
            switch event {
            case .initialized(let claudeSessionID):
                // Saved right away, before the turn can fail: this id is what resuming
                // needs, so losing it would strand the conversation. A stop already on its
                // way is the exception. The process is about to be killed, so the
                // conversation it just opened will stay empty, and taking its id would
                // throw away the one that still works.
                if !turn.stopRequested {
                    turn.agentSessionID = claudeSessionID
                    store.setAgentSessionID(claudeSessionID, agent: turn.agent, for: sessionID)
                }
                // Every turn the CLI runs opens like this, the one a wakeup starts included.
                // Once that one has begun there is nothing left to hold the process for.
                if let wakeup = turn.wakeup, wakeup.due.timeIntervalSinceNow < 5 {
                    turn.wakeup = nil
                }

            case .wakeup(let due):
                turn.wakeup = due.map { (task: BackgroundTask.wakeup(at: $0), due: $0) }

            case .turnStarted:
                freshReply(turn, sessionID: sessionID, store: store)
                setState(.streaming, for: sessionID)

            case .text(let text):
                setState(.streaming, for: sessionID)
                refreshCodexContextAfterModelActivity(turn, sessionID: sessionID, store: store)
                if turn.summary != nil {
                    if !turn.summaryText.isEmpty { turn.summaryText += "\n\n" }
                    turn.summaryText += text
                    continue
                }
                freshReply(turn, sessionID: sessionID, store: store)
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    // Each event carries a complete block, and blocks are split around
                    // tool calls, so they need a gap between them.
                    if !message.text.isEmpty { message.text += "\n\n" }
                    message.text += text
                }

            case .thinking(let text):
                setState(.streaming, for: sessionID)
                refreshCodexContextAfterModelActivity(turn, sessionID: sessionID, store: store)
                freshReply(turn, sessionID: sessionID, store: store)
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    // Stamped the same way a tool call is: only the message being built
                    // knows how far the turn had come when the thought arrived.
                    var thought = ThinkingSegment(text: text)
                    thought.textOffset = message.text.count
                    thought.toolOffset = message.tools.count
                    message.thinking = (message.thinking ?? []) + [thought]
                }

            case .agentText(let parentID, let text):
                setState(.streaming, for: sessionID)
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    guard let i = message.tools.firstIndex(where: { $0.id == parentID }) else { return }
                    message.tools[i].status = Self.statusLine(text)
                }

            case .toolUse(let tool):
                setState(.streaming, for: sessionID)
                refreshCodexContextAfterModelActivity(turn, sessionID: sessionID, store: store)
                freshReply(turn, sessionID: sessionID, store: store)
                records[sessionID]?.runningTools.append(tool)
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    // Stamped here rather than in the parser: only the message being
                    // built knows how much has been said so far, and that is what puts
                    // the call back in place when the turn is drawn.
                    var placed = tool
                    placed.textOffset = message.text.count
                    placed.startedAt = Date()
                    message.tools.append(placed)
                    if let record = turn.agentTasks.values.first(where: { $0.task.toolUseID == tool.id }) {
                        message.recordAgentTask(record)
                    }
                }

            case .toolResult(let id, let output, let isError, let exitCode):
                records[sessionID]?.runningTools.removeAll { $0.id == id }
                var command = ""
                var toolName = ""
                var describesOwnChange = false
                var completedAgent: AgentTaskRecord?
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    guard let i = message.tools.firstIndex(where: { $0.id == id }) else { return }
                    toolName = message.tools[i].name
                    describesOwnChange = message.tools[i].describesOwnChange
                    message.tools[i].result = output
                    message.tools[i].isError = isError
                    message.tools[i].exitCode = exitCode
                    message.tools[i].finishedAt = Date()
                    // An agent that has reported back is no longer partway through
                    // anything, and its last words are in the result.
                    message.tools[i].status = nil
                    command = message.tools[i].input
                    // This is the only moment the file holds what the edit wrote and
                    // nothing later, so it is the only moment the diff can be placed.
                    if !isError {
                        message.tools[i].editStartLine = EditLocation.startLine(
                            name: message.tools[i].name, input: command)
                    }
                    if let taskID = message.tools[i].backgroundAgentID,
                       var record = turn.agentTasks[taskID] {
                        let fields = (try? JSONSerialization.jsonObject(with: Data(command.utf8))) as? [String: Any]
                        let background = fields?["run_in_background"] as? Bool == true
                            || turn.pendingTasks.contains { $0.id == taskID }
                        if record.state == .running, isError || !background {
                            record.state = isError ? .failed : .completed
                            record.report = output
                            record.finishedAt = Date()
                            completedAgent = record
                        }
                        message.recordAgentTask(record)
                    }
                }
                if let completedAgent {
                    recordAgentTask(completedAgent, turn: turn, sessionID: sessionID, store: store)
                    turn.pendingTasks.removeAll { $0.id == completedAgent.task.id }
                    records[sessionID]?.agentsAtWork.remove(completedAgent.task.id)
                    if turn.waitingOnTasks { records[sessionID]?.wait?.tasks = turn.holdsFor }
                }
                if !instantEditIDs.contains(id) || id == firstInstantEditID {
                    noteWhatWasWritten(
                        by: id, named: toolName, describesOwnChange: describesOwnChange,
                        fallbackEditIDs: instantEditIDs.contains(id) ? fallbackEditIDs : [],
                        turn: turn, sessionID: sessionID, store: store)
                }
                // The only moment a pull request announces itself is in the output of the
                // command that opened it.
                if let opened = PullRequestScanner.opened(command: command, output: output) {
                    store.notePullRequest(opened, for: sessionID)
                }

            case .permissionRequest(let request):
                setState(.streaming, for: sessionID)
                records[sessionID]?.asked.append(request)
                // A question wants an answer whatever the person asked for earlier.
                store.wake(sessionID)
                if let session = store.session(sessionID) {
                    AppNotifier.shared.needsInput(
                        sessionID: store.userFacingSessionID(for: sessionID),
                        sessionTitle: session.title,
                        request: request)
                }

            case .permissionWithdrawn(let id):
                records[sessionID]?.asked.removeAll { $0.id == id }

            case .unanswerable(let requestID, let subtype):
                // Refusing is what keeps the turn moving. The CLI holds it on this request
                // id until a response comes back, so silence here is a turn that thinks
                // forever, which is the one failure the app cannot show or recover from.
                SessionLog.note("refusing control request \(subtype) \(requestID)", session: sessionID)
                if let line = Self.refusalLine(requestID: requestID, subtype: subtype) {
                    _ = turn.write(line)
                }

            case .rateLimit(let limit):
                rateLimits[turn.agent, default: [:]][limit.kind] = limit
                latestRateLimit[turn.agent] = limit
                rateLimitsUpdatedAt[turn.agent] = Date()

            case .usage(let totals):
                // A process reports running totals for its whole run, and a turn held
                // open for background tasks sees several of them, so only what has grown
                // since the last one is new spend.
                store.recordUsage(Self.grown(totals, since: turn.recordedUsage),
                                  from: turn.agent, for: sessionID)
                turn.recordedUsage = totals
                if turn.agent == .codex,
                   let threadID = turn.agentSessionID
                    ?? store.session(sessionID)?.agentSessionID(for: .codex) {
                    refreshCodexContext(threadID: threadID, sessionID: sessionID, store: store)
                }

            case .context(let tokens):
                store.recordContext(tokens, contextWindow: nil, model: nil,
                                    from: turn.agent, for: sessionID)

            case .compacted(let preTokens, let postTokens):
                records[sessionID]?.nudgeDismissed = false
                if let postTokens {
                    // The summary is the whole of the conversation now, so its size is
                    // how full the window is - no need to wait for a turn to measure it.
                    store.recordContext(postTokens, contextWindow: nil, model: nil,
                                        from: turn.agent, for: sessionID)
                } else {
                    // An older CLI reports only the size before. Nothing left on the row
                    // describes the conversation any more, so it is retired at the end of
                    // the turn, after the result event has stopped reporting sizes.
                    turn.compacted = true
                }
                if let noticeID = records[sessionID]?.compactNoticeID {
                    records[sessionID]?.compactNoticeID = nil
                    store.updateMessage(noticeID, in: sessionID) { message in
                        message.text = Self.compactedNotice(preTokens: preTokens,
                                                            postTokens: postTokens)
                    }
                }

            case .agentTaskStarted(let task):
                var record = turn.agentTasks[task.id] ?? AgentTaskRecord(task: task)
                let startedAt = record.task.startedAt
                record.task = task
                record.task.startedAt = startedAt
                recordAgentTask(record, turn: turn, sessionID: sessionID, store: store)
                if let index = turn.pendingTasks.firstIndex(where: { $0.id == task.id }) {
                    turn.pendingTasks[index] = record.task
                }
                if record.state == .running { records[sessionID]?.agentsAtWork.insert(task.id) }
                if turn.waitingOnTasks { records[sessionID]?.wait?.tasks = turn.holdsFor }

            case .agentTaskFinished(let id, let state, let report):
                guard var record = turn.agentTasks[id] else { continue }
                record.state = state
                record.report = report
                record.finishedAt = Date()
                recordAgentTask(record, turn: turn, sessionID: sessionID, store: store)
                turn.pendingTasks.removeAll { $0.id == id }
                records[sessionID]?.agentsAtWork.remove(id)
                if turn.waitingOnTasks { records[sessionID]?.wait?.tasks = turn.holdsFor }

            case .backgroundTasks(let tasks):
                let started = Dictionary(turn.pendingTasks.map { ($0.id, $0.startedAt) },
                                         uniquingKeysWith: { first, _ in first })
                let named = tasks.map { task in
                    var task = task
                    let known = turn.agentTasks[task.id]?.task
                    task.agentName = known?.agentName ?? task.agentName
                    task.toolUseID = known?.toolUseID ?? task.toolUseID
                    // The CLI resends the whole list every time any of it changes, so a
                    // task keeps the moment it was first seen rather than restarting the
                    // clock beside it on every report.
                    task.startedAt = started[task.id] ?? known?.startedAt ?? task.startedAt
                    return task
                }
                let liveIDs = Set(named.map(\.id))
                for var record in Array(turn.agentTasks.values)
                    where record.state == .running && started[record.task.id] != nil
                        && !liveIDs.contains(record.task.id) {
                    // Leaving the live list says the work ended, but only its report
                    // can tell us whether it succeeded.
                    record.state = .finished
                    record.finishedAt = Date()
                    recordAgentTask(record, turn: turn, sessionID: sessionID, store: store)
                }
                for task in named where task.isAgent {
                    var record = turn.agentTasks[task.id] ?? AgentTaskRecord(task: task)
                    record.task = task
                    recordAgentTask(record, turn: turn, sessionID: sessionID, store: store)
                }
                turn.pendingTasks = named
                records[sessionID]?.agentsAtWork = Set(named.map(\.id)).union(
                    turn.agentTasks.values.filter { $0.state == .running }.map { $0.task.id })
                // A wait can outlast the task that started it: one of several ending is
                // not the end of the wait, and the row has to say what is left.
                if turn.waitingOnTasks { records[sessionID]?.wait?.tasks = turn.holdsFor }

            case .streamError(let message):
                turn.lastStreamError = message
                setState(.reconnecting(message), for: sessionID)

            // Sent after the result, since the turn has to be over before there is
            // anything to predict. The preference is read again here because it can be
            // turned off while the turn that asked for one is still running.
            case .steerAccepted(let requestID):
                turn.steersInFlight[requestID] = nil

            case .steerRejected(let requestID, let message):
                // The turn moved on before the prompt reached it, so the prompt goes back to
                // the front of the queue and runs when this turn is over.
                guard let steer = turn.steersInFlight.removeValue(forKey: requestID) else { continue }
                SessionLog.note("steer rejected: \(message)", session: sessionID)
                takeBack(steer, turn: turn, sessionID: sessionID, store: store)

            case .promptSuggestion(let suggestion):
                guard turn.summary == nil, followUps.promptSuggestionsEnabled() else { continue }
                records[sessionID]?.suggestion = suggestion

            case .finished(let isError, let message):
                // A resumed process hands over whatever the one before it left queued -
                // the wake-up for a background task it never got to report - and that
                // handover is a turn of its own, ending in an empty result before this
                // turn has said a word. Reading it as the answer closes the input on a
                // turn that has not started, and an input already closed cannot be held
                // open later: the CLI reaches the end of the real turn and tears down,
                // killing the very tasks the turn was to be held open for.
                // Only Claude Code hands over this way, and only it says something in
                // every result it means: Codex ends a turn with no message at all.
                if turn.agent == .claudeCode, !isError, !turn.answered,
                   message?.isEmpty ?? true {
                    SessionLog.note("ignored a result that arrived before the turn answered",
                                    session: sessionID)
                    continue
                }
                turn.receivedCompletion = true
                turn.resultMessage = message
                if isError {
                    turn.failure = message ?? "\(turn.agent.title) reported an error."
                } else {
                    turn.lastStreamError = nil
                    setState(.streaming, for: sessionID)
                }
                // A result with background tasks still running is not the end of the
                // turn: the CLI runs a follow-up turn when a task finishes, but only
                // while its process is alive, so the input pipe is held open until the
                // last task is done and the turn after it has answered.
                if !isError, turn.summary == nil, !turn.holdsFor.isEmpty {
                    SessionLog.note("holding turn open for background tasks \(turn.holdsFor.map(\.id).sorted())",
                                    session: sessionID)
                    let alreadyWaiting = turn.waitingOnTasks
                    turn.waitingOnTasks = true
                    if alreadyWaiting {
                        records[sessionID]?.wait?.tasks = turn.holdsFor
                    } else {
                        records[sessionID]?.wait = Wait(tasks: turn.holdsFor, since: Date())
                    }
                    setState(.waiting, for: sessionID)
                    if !alreadyWaiting { startWaitWatchdog(sessionID, token: turn.token, store: store) }
                    // A prompt typed while the agent was working can go down the open
                    // pipe now instead of sitting behind the task.
                    injectQueued(sessionID, store: store)
                    continue
                }
                // Nothing more is coming, and the CLI keeps its input stream open waiting
                // for another message, so this is where the turn is let go.
                if turn.endingWait { stopStartedGroups(sessionID, reason: "wait ended by hand") }
                endHold(turn, sessionID: sessionID)
                turn.closeInput()
            }
        }
        if turn.stopRequested {
            records[sessionID]?.asked = []
            setState(.stopping, for: sessionID)
        }
    }

    private func startStallWatchdog(_ turn: Turn, sessionID: UUID) {
        guard !turn.agent.asksPermissions else { return }
        let token = turn.token
        let interval = stallCheckInterval
        turn.stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                self.markStalledIfNeeded(sessionID, token: token)
            }
        }
    }

    private func recordAgentTask(_ record: AgentTaskRecord, turn: Turn,
                                 sessionID: UUID, store: ProjectStore) {
        guard turn.summary == nil else { return }
        let messageID = turn.agentTaskMessages[record.task.id] ?? turn.messageID
        turn.agentTasks[record.task.id] = record
        turn.agentTaskMessages[record.task.id] = messageID
        store.updateMessage(messageID, in: sessionID) { $0.recordAgentTask(record) }
    }

    private func markStalledIfNeeded(_ sessionID: UUID, token: UUID) {
        guard let record = records[sessionID], let turn = turn(sessionID, token),
              !turn.stopRequested, !turn.receivedCompletion,
              !record.expectsSilence(from: turn),
              Date().timeIntervalSince(turn.lastActivity) >= stalledAfter else { return }
        if case .stalled = record.state { return }
        let silence = Int(Date().timeIntervalSince(turn.lastActivity))
        let category = turn.lastStreamError.map(StreamEvent.streamErrorCategory) ?? "none"
        SessionLog.note("turn stalled silentSeconds=\(silence) streamError=\(category)",
                        session: sessionID)
        setState(.stalled, for: sessionID)
    }

    private func flush(_ stream: StreamBatcher, sessionID: UUID, token: UUID,
                       store: ProjectStore) {
        let batch = stream.drain()
        if batch.stdoutActivity || !batch.events.isEmpty {
            apply(batch.events, sessionID: sessionID, token: token, store: store)
        }
        if !batch.stderr.isEmpty {
            appendStderr(sessionID, token: token, batch.stderr)
        }
        if batch.stdoutClosed {
            pipeClosed(sessionID, token: token, stdout: true, store: store)
        }
        if batch.stderrClosed {
            pipeClosed(sessionID, token: token, stdout: false, store: store)
        }
    }

    private func refreshCodexContextAfterModelActivity(_ turn: Turn, sessionID: UUID,
                                                       store: ProjectStore) {
        guard turn.agent == .codex,
              let threadID = turn.agentSessionID
                ?? store.session(sessionID)?.agentSessionID(for: .codex) else { return }
        refreshCodexContext(threadID: threadID, sessionID: sessionID, store: store,
                            after: .milliseconds(200))
    }

    private func refreshCodexContext(threadID: String, sessionID: UUID, store: ProjectStore,
                                     after delay: Duration? = nil) {
        codexContextRefreshes.removeValue(forKey: sessionID)?.task.cancel()
        let refreshID = UUID()
        let task = Task { [weak self, codexContextReader] in
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  let reading = await codexContextReader.read(threadID: threadID),
                  !Task.isCancelled,
                  let self,
                  self.codexContextRefreshes[sessionID]?.id == refreshID,
                  store.session(sessionID)?.codexSessionID == threadID else { return }
            self.codexContextRefreshes[sessionID] = nil
            switch reading {
            case .measured(let snapshot):
                store.recordContext(snapshot.contextTokens,
                                    contextWindow: snapshot.contextWindow,
                                    model: snapshot.model,
                                    from: .codex, for: sessionID)
            case .compacted:
                store.recordCompaction(for: sessionID)
            }
        }
        codexContextRefreshes[sessionID] = (refreshID, task)
    }

    // MARK: - Holding a turn open

    // Lets go of the hold that kept a turn's process alive for its background tasks,
    // whether because the CLI moved again, a prompt went down the open pipe, or the wait
    // was ended by hand.
    private func endHold(_ turn: Turn, sessionID: UUID) {
        turn.waitingOnTasks = false
        records[sessionID]?.wait = nil
        waitWatchdogs.removeValue(forKey: sessionID)?.cancel()
    }

    // A wait that ends on its own always ends through `endHold`, so anything still armed
    // when the deadline passes is a wait nothing is going to come back to. The turn is
    // left running: its tasks are the CLI's children and may yet finish, and throwing away
    // work nobody asked to stop would be worse than a row that says it needs someone.
    private func startWaitWatchdog(_ sessionID: UUID, token: UUID, store: ProjectStore) {
        waitWatchdogs.removeValue(forKey: sessionID)?.cancel()
        // A wakeup is known to stay quiet until it is due, so the wait is only judged
        // from that moment on.
        let quietUntilWakeup = records[sessionID]?.turn?.wakeup.map { max(0, $0.due.timeIntervalSinceNow) } ?? 0
        let deadline = waitingStaleAfter + quietUntilWakeup
        waitWatchdogs[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled else { return }
            self?.markWaitStale(sessionID, token: token, store: store)
        }
    }

    private func markWaitStale(_ sessionID: UUID, token: UUID, store: ProjectStore) {
        waitWatchdogs.removeValue(forKey: sessionID)
        // The turn is checked by token because a session can be on its next turn by now,
        // and that one's wait is its own.
        guard let record = records[sessionID], let wait = record.wait,
              record.turn?.token == token, !wait.isStale else { return }
        records[sessionID]?.wait?.isStale = true
        SessionLog.note("wait went stale after \(Int(Date().timeIntervalSince(wait.since)))s "
                        + "with \(wait.tasks.count) tasks still running", session: sessionID)
        // Named after the session the person can actually open: a Design companion has no
        // row of its own, so its own title would point at nothing.
        let userFacing = store.userFacingSessionID(for: sessionID)
        guard let session = store.session(userFacing) else { return }
        AppNotifier.shared.waitWentStale(sessionID: userFacing,
                                         sessionTitle: session.title,
                                         tasks: wait.tasks)
    }

    // A reply bubble is normally full by the time it is left behind, but a turn that said
    // nothing would leave an empty one sitting in the transcript for good.
    private func removeReplyIfEmpty(_ turn: Turn, sessionID: UUID, store: ProjectStore) {
        if store.transcript(of: sessionID).first(where: { $0.id == turn.messageID })?.isEmpty ?? false {
            store.removeMessage(turn.messageID, from: sessionID)
        }
    }

    // The bubble everything the turn streams from here on is written into.
    private func openFreshReply(_ turn: Turn, sessionID: UUID, store: ProjectStore) {
        let reply = ChatMessage(role: .assistant)
        store.append(reply, to: sessionID)
        turn.messageID = reply.id
    }

    // Opens a new reply bubble for a turn the CLI started on its own - the one it runs
    // when a background task finishes. Without this the follow-up would keep writing
    // into the bubble of the turn that already answered.
    private func freshReply(_ turn: Turn, sessionID: UUID, store: ProjectStore) {
        guard turn.summary == nil, turn.waitingOnTasks else { return }
        endHold(turn, sessionID: sessionID)
        removeReplyIfEmpty(turn, sessionID: sessionID, store: store)
        openFreshReply(turn, sessionID: sessionID, store: store)
    }

    // Hands the next queued prompt to the process a waiting turn is holding open. The
    // CLI accepts further user messages for as long as the pipe is open, so the person
    // is not stuck behind a task that could run for many minutes. One prompt at a time:
    // the ones behind it go when this one's result comes back.
    private func injectQueued(_ sessionID: UUID, store: ProjectStore) {
        guard let record = records[sessionID], let turn = record.turn, turn.waitingOnTasks,
              let next = record.queue.first, turn.summary == nil, next.summary == nil else { return }
        // The process was started with the old level in its system prompt, so a change
        // made while it waited can only reach the agent through the prompt.
        let ambition = next.isAppCommand ? nil : designAmbitionStep(sessionID, store: store)
        let text = ambition?.changePrompt.map { "\($0)\n\n\(next.prompt)" } ?? next.prompt
        let prompt = Self.prompt(text, with: next.attachments)
        // A failed write means the pipe is gone; the prompt stays queued and starts a
        // fresh process once this turn winds down.
        let sent = turn.connection.map { $0.send(prompt) }
            ?? Self.userMessageLine(prompt).map(turn.write) ?? false
        guard sent else { return }
        records[sessionID]?.queue.removeFirst()
        SessionLog.note("prompt sent into waiting turn", session: sessionID)

        if let ambition { noteDesignAmbition(ambition, sessionID: sessionID, store: store) }
        for message in next.transcriptMessages {
            store.append(message, to: sessionID)
        }
        openFreshReply(turn, sessionID: sessionID, store: store)
        turn.avatarSequence = nextAvatarSequence(for: sessionID)
        endHold(turn, sessionID: sessionID)
        setState(.streaming, for: sessionID)
    }

    // What a new usage report adds over the one before it. Clamped at zero so a report
    // that is not cumulative after all can only under-count, never charge twice.
    nonisolated static func grown(_ totals: TurnUsage, since recorded: TurnUsage?) -> TurnUsage {
        guard let recorded else { return totals }
        var grown = totals
        grown.costUSD = max(0, totals.costUSD - recorded.costUSD)
        grown.inputTokens = max(0, totals.inputTokens - recorded.inputTokens)
        grown.outputTokens = max(0, totals.outputTokens - recorded.outputTokens)
        grown.cacheReadTokens = max(0, totals.cacheReadTokens - recorded.cacheReadTokens)
        grown.cacheWriteTokens = max(0, totals.cacheWriteTokens - recorded.cacheWriteTokens)
        return grown
    }

    // MARK: - Ending a turn

    private func appendStderr(_ sessionID: UUID, token: UUID, _ chunk: String) {
        guard let turn = turn(sessionID, token) else { return }
        turn.stderr += chunk
        if turn.stderr.count > 4000 { turn.stderr = String(turn.stderr.suffix(4000)) }
    }

    private func pipeClosed(_ sessionID: UUID, token: UUID, stdout: Bool, store: ProjectStore) {
        guard let turn = turn(sessionID, token) else { return }
        if stdout { turn.stdoutOpen = false } else { turn.stderrOpen = false }
        finishIfDone(sessionID, store: store)
    }

    private func processExited(_ sessionID: UUID, token: UUID, status: Int32, store: ProjectStore) {
        guard let turn = turn(sessionID, token) else { return }
        if let violation = turn.memoryGuard?.violation {
            memoryLimitExceeded(sessionID, token: token, violation: violation)
        }
        turn.exitStatus = status
        if turn.stopRequested {
            // A stopped turn does not need to wait for delayed pipe EOF callbacks once
            // the agent process itself has exited.
            turn.stdoutOpen = false
            turn.stderrOpen = false
        }
        finishIfDone(sessionID, store: store)
    }

    private func memoryLimitExceeded(_ sessionID: UUID, token: UUID,
                                     violation: SessionMemoryGuard.Violation) {
        guard let turn = turn(sessionID, token) else { return }
        turn.stopRequested = true
        turn.stopFailure = violation.message
        turn.restartAfterStop = false
        records[sessionID]?.asked = []
        setState(.stopping, for: sessionID)
        turn.closeInput()
    }

    private func processGroupDidNotStop(_ sessionID: UUID, token: UUID) {
        guard let turn = turn(sessionID, token) else { return }
        turn.stopRequested = true
        if turn.stopFailure == nil {
            turn.stopFailure = "The agent process group could not be stopped."
        }
        records[sessionID]?.asked = []
        setState(.stopping, for: sessionID)
        turn.closeInput()
    }

    // Puts back the conversation a turn was resuming when the fork it opened instead was
    // left empty. Claude Code answers every resume by starting a new conversation and
    // copying the old one into it, and that copy is only written once the turn speaks. A
    // turn stopped or broken before its first word therefore leaves an id that nothing can
    // be resumed from, while the id it replaced is still whole. Keeping the new one costs
    // the session its entire history on the next prompt.
    private func restorePreviousConversation(_ turn: Turn, status: Int32, sessionID: UUID,
                                             store: ProjectStore) {
        guard let previous = turn.resumedFrom, !turn.answered,
              let opened = turn.agentSessionID, opened != previous,
              turn.stopRequested || turn.failure != nil || status != 0
        else { return }
        turn.agentSessionID = previous
        store.setAgentSessionID(previous, agent: turn.agent, for: sessionID)
        SessionLog.note("kept the conversation the turn resumed, its own was never written",
                        session: sessionID)
    }

    // The exit status and the last bytes of output arrive on different queues, so a turn
    // only ends once both pipes are at EOF and the process is gone. Otherwise the tail of
    // a reply, or the stderr that explains a failure, can be dropped. Dropping the turn
    // before doing anything else means the events the CLI still writes after its result
    // cannot end the same turn twice.
    private func finishIfDone(_ sessionID: UUID, store: ProjectStore) {
        guard let turn = records[sessionID]?.turn, !turn.stdoutOpen, !turn.stderrOpen,
              let status = turn.exitStatus else { return }
        for var record in Array(turn.agentTasks.values) where record.state == .running {
            record.state = .interrupted
            record.finishedAt = Date()
            recordAgentTask(record, turn: turn, sessionID: sessionID, store: store)
        }
        // A steer the agent never got to has nowhere to go once the turn is over, so its
        // prompt waits as the next turn instead of being lost with the one that died.
        for steer in turn.steersInFlight.values where !steer.answered {
            takeBack(steer, turn: turn, sessionID: sessionID, store: store)
        }
        turn.steersInFlight = [:]
        records[sessionID]?.turn = nil
        records[sessionID]?.runningTools = []
        records[sessionID]?.agentsAtWork = []
        records[sessionID]?.wait = nil
        // The process that parked them is gone, so nothing is listening for an answer.
        records[sessionID]?.asked = []
        // Read out before the assignment: both sides reach for `records`, and writing
        // through the subscript holds it exclusively for as long as the right side runs.
        let carried = startedGroups(sessionID)
        records[sessionID]?.startedGroups = carried
        cleanUp(turn)
        restorePreviousConversation(turn, status: status, sessionID: sessionID, store: store)
        onTurnEnded(sessionID)
        // A review sent to the session is judged against the files as this turn left them,
        // and what the agent wrote is split into answers to its comments.
        if turn.summary == nil {
            let prompt = turn.prompt
            let reply = ReviewAnswers.reply(to: prompt, in: store.session(sessionID)?.messages ?? [])
            Task { await reviews.turnEnded(sessionID, prompt: prompt, reply: reply) }
        }

        // Even a recap must stay stopped after exceeding the limit. Starting queued
        // work or a fallback summary here can immediately repeat the memory spike.
        if let violation = turn.memoryGuard?.violation {
            removeReplyIfEmpty(turn, sessionID: sessionID, store: store)
            if let noticeID = records[sessionID]?.compactNoticeID {
                records[sessionID]?.compactNoticeID = nil
                store.removeMessage(noticeID, from: sessionID)
            }
            if turn.compacted { store.recordCompaction(for: sessionID) }
            store.append(ChatMessage(role: .system, text: violation.message), to: sessionID)
            setState(.failed(violation.message), for: sessionID)
            if store.session(sessionID)?.hasAgentConversation == true {
                records[sessionID]?.continuable = .failedTurn
            }
            _ = store.noteTurnEnded(for: sessionID)
            store.release(sessionID, for: .running)
            if let session = store.session(sessionID) {
                AppNotifier.shared.turnEnded(
                    sessionID: store.userFacingSessionID(for: sessionID),
                    sessionTitle: session.title, failure: violation.message)
            }
            return
        }

        if let summary = turn.summary {
            finishSummary(turn, attempt: summary, status: status,
                          sessionID: sessionID, store: store)
            return
        }

        // A turn that produced nothing at all would otherwise leave a blank assistant
        // bubble sitting under the failure.
        removeReplyIfEmpty(turn, sessionID: sessionID, store: store)

        // A compaction that ended without saying it had happened did not happen: the
        // conversation was too short for one, or the turn failed. Either way the agent's
        // own words are the explanation, and "Compacting…" would sit there for good.
        if let noticeID = records[sessionID]?.compactNoticeID {
            records[sessionID]?.compactNoticeID = nil
            store.removeMessage(noticeID, from: sessionID)
        }
        // Last, so that nothing the turn reported on its way out can put the retired
        // reading back on the row.
        if turn.compacted { store.recordCompaction(for: sessionID) }

        if turn.stopRequested {
            if turn.restartAfterStop, turn.stopFailure == nil {
                setState(.idle, for: sessionID)
                store.release(sessionID, for: .running)
                resume(sessionID, after: .stalledTurn, store: store)
                return
            }
            let unseen: Bool
            records[sessionID]?.lastEnding = TurnEnding(
                started: turn.startedAt, ended: Date(),
                outcome: turn.stopFailure == nil ? .stopped : .failed, startHeads: turn.startHeads)
            if let failure = turn.stopFailure {
                setState(.failed(failure), for: sessionID)
                unseen = store.noteTurnEnded(for: sessionID)
            } else {
                setState(.idle, for: sessionID)
                noteStop(sessionID, store: store)
                unseen = store.noteTurnEnded(for: sessionID)
            }
            store.release(sessionID, for: .running)
            resumeDesignWorkflowQueues(after: sessionID, store: store)
            requestAutomaticRecap(sessionID, unseen: unseen, store: store)
            return
        }

        // Warnings on stderr are common and harmless. Codex and Copilot must also report
        // their terminal event, since an exit code of zero after a broken stream does not
        // prove the turn reached completion.
        let missingCompletion = turn.agent != .claudeCode && !turn.receivedCompletion
        guard turn.failure != nil || status != 0 || missingCompletion else {
            SessionLog.note("turn finished", session: sessionID)
            records[sessionID]?.lastEnding = TurnEnding(started: turn.startedAt, ended: Date(),
                                                        outcome: .finished, startHeads: turn.startHeads)
            setState(.idle, for: sessionID)
            let titleQueued = queueAutomaticTitle(after: turn, sessionID: sessionID,
                                                  store: store)
            // Given back before the queue runs: the next turn takes the transcript for
            // itself, and releasing after it started would take that hold away.
            store.release(sessionID, for: .running)
            // Only a turn that ended on its own pulls the next one in. After a failure or a
            // stop the queue waits to be sent by hand, so the reason it stopped stays on
            // screen long enough to read.
            runQueue(sessionID, store: store)
            resumeDesignWorkflowQueues(after: sessionID, store: store)
            // A queued prompt starting straight away means the session has not stopped
            // working, and there is nothing to come back to yet.
            if !state(sessionID).isBusy, !titleQueued {
                let unseen = store.noteTurnEnded(for: sessionID)
                if let session = store.session(sessionID) {
                    AppNotifier.shared.turnEnded(
                        sessionID: store.userFacingSessionID(for: sessionID),
                        sessionTitle: session.title, failure: nil)
                }
                // Before the recap, which would otherwise hold the session busy and
                // leave the turn with nothing to offer.
                requestPromptSuggestion(sessionID, store: store)
                requestAutomaticRecap(sessionID, unseen: unseen, store: store)
            }
            return
        }
        var parts: [String] = []
        if let failure = turn.failure { parts.append(failure) }
        if turn.failure == nil, missingCompletion, let streamError = turn.lastStreamError {
            parts.append(streamError)
        }
        let stderr = turn.stderr.trimmed
        if !stderr.isEmpty { parts.append(stderr) }
        if parts.isEmpty {
            parts.append(missingCompletion
                ? "\(turn.agent.title) ended before completing the turn."
                : "\(turn.agent.title) exited with code \(status).")
        }
        if Self.rejectedArguments(parts.joined(separator: "\n")) {
            parts.append("\(turn.agent.title) did not accept what the app passed to it. The app needs version \(turn.agent.minimumVersion) or newer, so updating the CLI may fix this.")
        }
        let message = parts.joined(separator: "\n\n")
        SessionLog.note(
            "turn failed status=\(status) failure=\(turn.failure != nil) stderrBytes=\(turn.stderr.utf8.count)",
            session: sessionID)

        // The CLI no longer holds the conversation we asked it to resume, usually
        // because its own history was pruned. The prompt is still good, so run it once
        // more as a new conversation instead of leaving the session stuck for good.
        if turn.canRetryWithoutResume, turn.resumed,
           let lost = Self.lostConversation(turn.agent), message.contains(lost) {
            store.clearAgentSessionID(agent: turn.agent, for: sessionID)
            store.append(
                ChatMessage(role: .system,
                            text: "The earlier conversation could not be resumed, so this reply starts a fresh one without the previous context."),
                to: sessionID)
            launch(turn.prompt, attachments: turn.attachments, sessionID: sessionID,
                   store: store, avatarSequence: turn.avatarSequence,
                   canRetryWithoutResume: false, isFirstTurn: turn.isFirstTurn)
            return
        }

        if store.session(sessionID)?.hasAgentConversation == true {
            records[sessionID]?.continuable = .failedTurn
        }
        records[sessionID]?.lastEnding = TurnEnding(started: turn.startedAt, ended: Date(),
                                                    outcome: .failed, startHeads: turn.startHeads)
        setState(.failed(message), for: sessionID)
        store.release(sessionID, for: .running)
        resumeDesignWorkflowQueues(after: sessionID, store: store)
        let unseen = store.noteTurnEnded(for: sessionID)
        if let session = store.session(sessionID) {
            AppNotifier.shared.turnEnded(
                sessionID: store.userFacingSessionID(for: sessionID),
                sessionTitle: session.title, failure: message)
        }
        requestAutomaticRecap(sessionID, unseen: unseen, store: store)
    }

    private func finishSummary(_ turn: Turn, attempt: SummaryAttempt, status: Int32,
                               sessionID: UUID, store: ProjectStore) {
        // A title runs before the turn that earned a suggestion has settled, so the ask
        // is made here instead. It stands down on its own if one has already been made,
        // or if another summary is still to run.
        defer { requestPromptSuggestion(sessionID, store: store) }
        let streamed = turn.summaryText
        store.release(sessionID, for: .running)

        let completedNormally = !turn.stopRequested && turn.failure == nil && status == 0
            && (turn.agent == .claudeCode || turn.receivedCompletion)
        let text: String? = if completedNormally {
            switch attempt.mode {
            case .claudeRecap:
                SessionRecap.nativeText(from: streamed)
                    ?? SessionRecap.nativeText(from: turn.resultMessage)
            case .promptRecap:
                SessionRecap.cleaned(streamed) ?? SessionRecap.cleaned(turn.resultMessage)
            case .title:
                SessionTitle.cleaned(streamed) ?? SessionTitle.cleaned(turn.resultMessage)
            }
        } else {
            nil
        }

        if case .title(let request) = attempt.mode {
            if let text { store.setGeneratedTitle(text, for: request) }
            setState(attempt.restingState.sessionState, for: sessionID)
            SessionLog.note(text != nil ? "session title finished" : "session title unchanged",
                            session: sessionID)
            if !turn.stopRequested { runQueue(sessionID, store: store) }
            resumeDesignWorkflowQueues(after: sessionID, store: store)
            if attempt.recapAfterTitle, !turn.stopRequested,
               store.hasFinished(request.sessionID) {
                requestAutomaticRecap(sessionID, unseen: true, store: store)
            }
            return
        }

        if let text {
            let source: SessionRecap.Source = attempt.mode == .claudeRecap
                ? .claudeCode : .prompt
            store.setRecap(SessionRecap(text: text, generatedAt: Date(), source: source),
                           for: sessionID)
            setState(attempt.restingState.sessionState, for: sessionID)
            SessionLog.note("session recap finished", session: sessionID)
            runQueue(sessionID, store: store)
            resumeDesignWorkflowQueues(after: sessionID, store: store)
            return
        }

        if attempt.mode == .claudeRecap, !turn.stopRequested {
            recordAddingIfMissing(sessionID).queue.insert(QueuedPrompt(
                text: Self.recapPrompt,
                attachments: [],
                customInstructions: nil,
                isAppCommand: true,
                summary: SummaryAttempt(mode: .promptRecap, restingState: attempt.restingState)),
                at: 0)
            setState(attempt.restingState.sessionState, for: sessionID)
            SessionLog.note("native recap unavailable; using summary prompt", session: sessionID)
            runQueue(sessionID, store: store)
            resumeDesignWorkflowQueues(after: sessionID, store: store)
            return
        }

        setState(attempt.restingState.sessionState, for: sessionID)
        SessionLog.note(turn.stopRequested ? "session recap stopped" : "session recap failed",
                        session: sessionID)
        runQueue(sessionID, store: store)
        resumeDesignWorkflowQueues(after: sessionID, store: store)
    }

    private func resumeDesignWorkflowQueues(after sessionID: UUID, store: ProjectStore) {
        let waiting = records.filter {
            $0.value.waitsForDesignWorkflowDirectory
                && store.sessionsShareDesignWorkflow(sessionID, $0.key)
        }
        for waitingSessionID in waiting.keys {
            runQueue(waitingSessionID, store: store)
        }
    }

    private func cleanUp(_ turn: Turn) {
        turn.memoryGuard?.stop()
        turn.taskRefresh?.cancel()
        turn.taskRefresh = nil
        turn.stallWatchdog?.cancel()
        turn.stallWatchdog = nil
        turn.output.fileHandleForReading.readabilityHandler = nil
        turn.errorOutput.fileHandleForReading.readabilityHandler = nil
        turn.exitMonitor?.cancel()
        turn.exitMonitor = nil
        turn.closeInput()
        if let url = turn.mcpConfigURL { try? FileManager.default.removeItem(at: url) }
    }

    // One live turn. Only ever touched on the main actor.
    // What a steer added to the transcript, kept until the agent says the turn took it so
    // a refused one can be taken back out.
    fileprivate struct SteerInFlight {
        let prompt: QueuedPrompt
        let messageIDs: [UUID]
        let replyID: UUID
        let previousReplyID: UUID
        // Whether the agent has done anything since, which is taken as it having read the
        // prompt. A turn that dies before that gives the prompt back to the queue.
        var answered = false
    }

    fileprivate final class Turn {
        let token = UUID()
        let processGroup: pid_t
        // The agent this turn started on. The app-wide choice can move mid-turn, and
        // the stream already in flight still has to be read in its own dialect.
        let agent: AgentKind
        // Where the reply is being written. A question answered mid-turn closes the
        // message the turn opened with and moves this on to the one after the answer.
        var messageID: UUID
        let input: ProcessPipe
        let output: ProcessPipe
        let errorOutput: ProcessPipe
        var exitMonitor: DispatchSourceProcess?
        var memoryGuard: SessionMemoryGuard?
        var connection: AgentSessionConnection?
        var taskRefresh: Task<Void, Never>?
        private var inputOpen = true
        let prompt: String
        // The folder the agent was started in, which is the checkout a call's writes land
        // in and so the one the snapshots behind those writes are taken of.
        let workingDirectory: String
        let attachments: [Attachment]
        var avatarSequence: Int
        // The conversation this turn was told to pick up. Claude Code answers a resume by
        // forking a new conversation, and it only writes the copied history once the turn
        // says something, so a turn killed before that leaves an id behind that nothing
        // can be resumed from. Kept so the working one can be put back.
        let resumedFrom: String?
        var resumed: Bool { resumedFrom != nil }
        let canRetryWithoutResume: Bool
        let mcpConfigURL: URL?
        let summary: SummaryAttempt?
        var isFirstTurn = false
        var agentSessionID: String?
        var stderr = ""
        var failure: String?
        var lastStreamError: String?
        var resultMessage: String?
        // A summary never becomes a transcript message.
        var summaryText = ""
        var receivedCompletion = false
        // Whether anything the turn said has come through yet. A result before that
        // belongs to a turn the app never asked for, so it is not this turn ending.
        var answered = false
        var stopRequested = false
        var stopFailure: String?
        var restartAfterStop = false
        var stallWatchdog: Task<Void, Never>?
        var stdoutOpen = true
        var stderrOpen = true
        var exitStatus: Int32?
        // The background tasks the CLI says are still running, in the order it sent them.
        var pendingTasks: [BackgroundTask] = []
        // The wakeup the agent has scheduled, kept until the turn it starts begins.
        var wakeup: (task: BackgroundTask, due: Date)?
        // What a turn that has answered stays open for: the CLI's own tasks and any wakeup.
        var holdsFor: [BackgroundTask] { pendingTasks + (wakeup.map { [$0.task] } ?? []) }
        var agentTasks: [String: AgentTaskRecord] = [:]
        var agentTaskMessages: [String: UUID] = [:]
        // True from a result that left tasks running until the CLI moves again or a
        // prompt is sent into the open pipe. This is what holds the input open.
        var waitingOnTasks = false
        // Prompts steered into the turn that the agent has not yet been seen to take, by
        // the request that carried them. Codex answers a steer with a reply; Claude Code's
        // are numbered below zero here and judged by whether the agent moved afterwards.
        var steersInFlight: [Int: SteerInFlight] = [:]
        var nextLocalSteerID = -1
        var endingWait = false
        // Whether this turn replaced the conversation with a summary, which is what makes
        // the last reading of the window no longer describe anything.
        var compacted = false
        // The totals from the last usage report, so the next one is recorded as a delta.
        var recordedUsage: TurnUsage?
        // Moved on every read off the CLI's stdout, so it measures silence rather than
        // progress: a turn deep in a long build still counts as alive.
        var lastActivity = Date()
        // Fixed at the moment the turn began, which is what the status strip counts from
        // while it runs. `lastActivity` cannot answer that: it moves all turn.
        let startedAt = Date()
        var startHeads: [String: String] = [:]

        // Whether the CLI is still reading this turn's input.
        var acceptsInput: Bool { inputOpen }

        // One line down the pipe the CLI is reading. False when it could not be sent: the
        // process is gone, or its end of the pipe is shut.
        func write(_ line: Data) -> Bool {
            guard inputOpen else { return false }
            do {
                try input.fileHandleForWriting.write(contentsOf: line)
                return true
            } catch {
                inputOpen = false
                return false
            }
        }

        // Closing is what tells the CLI no more messages are coming, so it is the end of
        // the turn rather than something to do early.
        func closeInput() {
            guard inputOpen else { return }
            inputOpen = false
            connection?.close()
            try? input.fileHandleForWriting.close()
        }

        init(processGroup: pid_t, agent: AgentKind, messageID: UUID, input: ProcessPipe,
             output: ProcessPipe, errorOutput: ProcessPipe, prompt: String, workingDirectory: String,
             attachments: [Attachment], resumedFrom: String?, avatarSequence: Int,
             canRetryWithoutResume: Bool, mcpConfigURL: URL?, summary: SummaryAttempt?) {
            self.processGroup = processGroup
            self.agent = agent
            self.messageID = messageID
            self.input = input
            self.output = output
            self.errorOutput = errorOutput
            self.prompt = prompt
            self.workingDirectory = workingDirectory
            self.attachments = attachments
            self.avatarSequence = avatarSequence
            self.resumedFrom = resumedFrom
            self.canRetryWithoutResume = canRetryWithoutResume
            self.mcpConfigURL = mcpConfigURL
            self.summary = summary
        }
    }
}
