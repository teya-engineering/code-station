import Foundation
import Observation

// The station's engine as its host serves it to clients. Every command answers with
// plain Codable values in the phone remote's vocabulary, and nothing here hands out a
// store, a runner or any other reference into the engine, so all of it can be carried
// over a local socket.
//
// A front end does not hold this: it holds a client through the station interface (see
// `StationInterface`), `connect()` for one in this process. What a client opens and
// shows is kept per client; what is here is shared by them all.
@MainActor
public final class StationCommands {
    let store: ProjectStore
    let runner: SessionRunner
    // A live list is rebuilt whenever something it read changes. Some of what a row says
    // moves with time alone (a wait going stale), so it is also looked at once a second.
    let refreshInterval: Duration
    // Git's numbers for a session's tree. Reading a session's changes fills it; until
    // then a header counts the transcript's own running total, as the phone does before
    // git has answered.
    private let gitStats = GitStatsCache()
    // Which session folders hold uncommitted work, for the mark on a sidebar card, and
    // when every folder was last looked at. The inspector is spelt out: built from the
    // initializer's default closure in a stored property, the call crashed the task
    // allocator on its first run.
    let workingTrees = WorkingTreeWatch(inspect: { path in
        await GitInspector.uncommittedFileCount(at: path)
    })
    private var lastWorkingTreeLook: ContinuousClock.Instant?
    // How often a live changes subscription asks git again, and every subscription open
    // now, so a commit or discard made here is sent at once (see `StationCommit`).
    public var changesRefreshInterval: Duration = .seconds(2)
    // Where a trashed file or a discarded untracked one goes: the Trash, or what a test
    // hands over instead.
    public var trash = FileTrash.system
    var changesWatches: [ObjectIdentifier: ChangesWatch] = [:]
    // When each tree an open session works in was last asked of git, and the ones being
    // asked now, so an open session's branch and changes stay current without git being
    // asked again on every tick (see `refreshWorkingTree`). Its answers also feed the
    // sidebar's watch, and the watch's own sweep leaves these trees alone, so git is
    // asked about a tree by one path at a time.
    private var treeAskedAt: [String: ContinuousClock.Instant] = [:]
    private var treesBeingRead: Set<String> = []
    static let workingTreeRefresh: Duration = .seconds(10)
    // Every client connected, so quitting can let go of what each had open.
    private var connections: [StationClientID: WeakConnection] = [:]
    // How many times a live list or open session was rebuilt because something it read
    // changed, as against the tick. Tests read it to see watchers do not pile up.
    var changeRebuilds = 0
    // How worktrees for new sessions are made. Tests point it at a scratch folder.
    var worktrees: WorktreeOperations = .live
    // Where the shared preferences are read, such as how the sidebar tree is arranged.
    let preferences: UserDefaults
    // Where each agent's sign-in is read, for its readiness. Tests point it at a scratch
    // home folder.
    public var signIn = AgentSignIn.live
    let copilotSignIn = CopilotSignInCheck()
    // The app's version, which a newer release the GUI found is compared with. Nil (a
    // development build) never has an update waiting.
    public var installedVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    // What the runner tells the person, passed on to every client that listens.
    private let hostEventRelay: HostEventRelay
    // The host's background work, whose orphaned worktrees and sweep countdown the
    // cleanup strips show. Set by the upkeep built on this station.
    public weak var upkeep: StationUpkeep?
    // The saved command shortcuts and their runs, which every client lists and runs
    // (`StationShortcuts`). The GUI hands over its own, so a run started from a terminal
    // shows in the app and the other way round.
    public let shortcuts: ShortcutStore
    // Where the person's own slash command files are looked for (see `AgentCommands`).
    // Tests point it at a scratch home folder.
    public var agentCommandsHome = FileManager.default.homeDirectoryForCurrentUser
    public var agentCommandsEnvironment = ProcessInfo.processInfo.environment
    // Where a new task's own folder is made. Tests point it at a scratch folder.
    public var taskFolder = AppPaths.support.appendingPathComponent("ad-hoc-tasks", isDirectory: true)
    // Where a diagnosis finds its environments, MCP servers and skills (`StationDiagnosis`).
    // Tests hand over their own.
    public lazy var diagnosis = DiagnosisSupport.live(
        siteFiles: TroubleshootEnvironment.siteSearchPaths(preferences: preferences))

    // `showsSelection` says the host has a screen of its own, as the GUI does: its
    // selection, while the app is active, is read like a session a client shows. A host
    // with no window (the default) has nothing on screen but what its clients show, and
    // the selection the GUI left behind in the store is on nobody's screen.
    public init(store: ProjectStore, runner: SessionRunner,
                refreshInterval: Duration = .seconds(1), showsSelection: Bool = false,
                preferences: UserDefaults = Preferences.defaults, shortcuts: ShortcutStore? = nil) {
        self.store = store
        self.runner = runner
        // Beside the station's index, which is where the GUI keeps them for the real one,
        // and in a scratch folder for a test's.
        self.shortcuts = shortcuts ?? ShortcutStore(
            storageURL: store.storeURL.deletingLastPathComponent().appendingPathComponent("shortcuts.json"),
            startingShortcuts: [])
        self.refreshInterval = refreshInterval
        self.preferences = preferences
        // One relay per runner, however many engines are built on it.
        if let relay = runner.host as? HostEventRelay {
            hostEventRelay = relay
        } else {
            hostEventRelay = HostEventRelay(forwardingTo: runner.host)
            runner.host = hostEventRelay
        }
        if !showsSelection { store.detachFromScreen() }
    }

    // Starts the core for a host with no window of its own: the station's store (or the
    // index named, for a test or a scratch copy) and a session runner that reports to
    // `host`.
    public static func start(host: any HostServices, storeURL: URL? = nil,
                             mcpConfigURL: URL = MCPConfigFile.standardURL,
                             preferences: UserDefaults = Preferences.defaults) -> StationCommands {
        let store = ProjectStore(storeURL: storeURL)
        let runner = SessionRunner(mcpConfiguration: mcpConfiguration(at: mcpConfigURL), host: host)
        return StationCommands(store: store, runner: runner, preferences: preferences)
    }

    // A new client of this host, in the same process.
    public func connect() -> StationConnection {
        let connection = StationConnection(host: self)
        connections[connection.client] = WeakConnection(connection)
        return connection
    }

    func forget(_ client: StationClientID) {
        connections[client] = nil
        if client == handoverClient { abandonHandover() }
    }

    // How a session limited to some MCP servers gets them: read from the shared MCP
    // config the GUI's settings write, so it runs from the terminal as it does there.
    public static func mcpConfiguration(at url: URL) -> @MainActor ([String]) -> Data? {
        { names in MCPConfigFile.filtered(at: url, allowing: names) }
    }

    // MARK: - List directory

    // The phone's project list, and the sidebar tree as the shared preferences arrange
    // it. Preferences are not observed, so a new arrangement goes out on the next tick.
    public func listDirectory() -> RemoteDirectory {
        var directory = RemoteDirectoryListing.directory(store: store, runner: runner,
                                                         title: "All projects", scope: "All projects",
                                                         canCreate: true)
        let arrangement = RemoteArrangement(
            sort: Preferences.projectSort(in: preferences),
            grouping: Preferences.projectGrouping(in: preferences),
            sessionLimit: Preferences.sidebarSessionLimit(in: preferences),
            collapsedSections: Preferences.collapsedSidebarGroups(in: preferences),
            expansion: Dictionary(uniqueKeysWithValues: Preferences.sidebarExpansion(in: preferences)
                .map { ($0.key.uuidString, $0.value) }))
        directory.arrangement = arrangement
        lookAtWorkingTrees()
        directory.containers = RemoteDirectoryListing.tree(
            store: store, runner: runner, arrangement: arrangement,
            uncommitted: { [store, workingTrees] session in
                store.workingDirectories(for: session).contains(where: workingTrees.isDirty)
            })
        directory.cleanup = cleanup()
        directory.handingOverTo = successor
        return directory
    }

    // What the cleanup strips say: old sessions as the shared age counts them, and what
    // the host's upkeep has found and settled on.
    private func cleanup() -> RemoteCleanup {
        let days = Preferences.oldSessionDays(in: preferences)
        let old = RemoteDirectoryListing.oldSessions(store: store, runner: runner, days: days)
        var cleanup = RemoteCleanup(oldSessions: old.sessions, oldSessionDays: days,
                                    snoozedProjects: old.snoozedProjects)
        if let upkeep {
            cleanup.oldSessionsDeleting = upkeep.oldSessionDeletion?.sessions
            cleanup.oldSessionsDeletingAt = upkeep.oldSessionDeletion?.at
            let orphans = upkeep.orphanedWorktrees.worktrees
            cleanup.orphanedWorktrees = orphans.count
            cleanup.orphanedBytes = orphans.reduce(0) { $0 + $1.allocatedBytes }
            if Preferences.autoPruneOrphanedWorktrees(in: preferences) {
                cleanup.orphansPruneAt = upkeep.orphanedWorktrees.automaticDeletionAt
            }
        }
        return cleanup
    }

    // Asks git about every folder a session works in: one never looked at straight away,
    // and all of them again once the watch's interval has passed. The answers land in the
    // watch, which the live list observes, so a mark that changes goes out by itself.
    // A tree an open session's header asked about lately is skipped: that answer has
    // already landed in the watch (see `refreshWorkingTree`).
    private func lookAtWorkingTrees(now: ContinuousClock.Instant = .now) {
        let folders = Set(store.sidebarSessions.flatMap(store.workingDirectories(for:))).filter { folder in
            !treesBeingRead.contains(folder)
                && treeAskedAt[folder].map { now - $0 >= WorkingTreeWatch.interval } ?? true
        }
        if let last = lastWorkingTreeLook, now - last < WorkingTreeWatch.interval {
            let unseen = folders.filter { !workingTrees.hasInspected($0) }
            if !unseen.isEmpty { workingTrees.refresh(unseen) }
        } else {
            lastWorkingTreeLook = now
            workingTrees.refresh(folders)
        }
    }

    // The list now, then again each time it changes. An unchanged list is never sent
    // twice in a row. The stream ends when the reader stops iterating.
    public func directoryUpdates() -> AsyncStream<RemoteDirectory> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteDirectory.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let watch = DirectoryWatch(continuation: continuation)
        watch.timer = Task { @MainActor [weak self, weak watch] in
            while !Task.isCancelled {
                guard let self, let watch else { return }
                self.publish(to: watch)
                try? await Task.sleep(for: self.refreshInterval)
            }
        }
        continuation.onTermination = { _ in
            Task { @MainActor in watch.stop() }
        }
        return stream
    }

    // Reads the list under observation, so the next change to anything it read sends a
    // fresh one at once rather than on the next tick.
    // Only one tracker is ever pending: a tick while one is armed reads the list plainly,
    // and the tracker is armed again only once it has fired.
    private func publish(to watch: DirectoryWatch) {
        guard !watch.stopped else { return }
        guard !watch.tracking else {
            watch.send(listDirectory())
            return
        }
        watch.tracking = true
        let directory = withObservationTracking {
            listDirectory()
        } onChange: { [weak self, weak watch] in
            Task { @MainActor in
                guard let self, let watch else { return }
                watch.tracking = false
                self.changeRebuilds += 1
                self.publish(to: watch)
            }
        }
        watch.send(directory)
    }

    // MARK: - Host events

    // What the runner tells the person from now on (a turn that ended, a question
    // waiting, a wait gone stale, the session sound), for a client to tell its own. The
    // stream ends when the reader stops iterating.
    public func hostEvents() -> AsyncStream<StationHostEvent> {
        hostEventRelay.events()
    }

    // How many readers are listening, so a test can wait for a client to be ready.
    public var hostEventListeners: Int { hostEventRelay.listenerCount }

    // MARK: - Reading a session, for the clients that follow it

    func sessionState(_ id: UUID) -> RemoteSessionState? {
        RemoteSessionState.make(id, store: store, runner: runner, gitStats: gitStats,
                                preferences: preferences)
    }

    // Asks git about the trees an open session works in, as the GUI's session pane does
    // while it shows one, so the header has a branch, a file count and git's own line
    // counts. A tree asked about in the last few seconds is left alone, and each answer
    // lands in the cache as it comes, where the next tick of the session's watch sees it.
    func refreshWorkingTree(_ id: UUID) {
        guard let session = store.session(id) else { return }
        let now = ContinuousClock.now
        let roots = store.workingDirectories(for: session).filter { root in
            !treesBeingRead.contains(root)
                && treeAskedAt[root].map { now - $0 >= Self.workingTreeRefresh } ?? true
        }
        for root in roots {
            treesBeingRead.insert(root)
            treeAskedAt[root] = now
            Task { @MainActor [weak self] in
                let snapshot = await GitInspector.snapshot(at: root, lane: .interactive)
                guard let self else { return }
                self.treesBeingRead.remove(root)
                // The same answer marks the sidebar card, so the watch need not ask too.
                if snapshot.state == .ready { self.workingTrees.record(snapshot.files.count, at: root) }
                // Only an answer that changes what is known goes in, so a tree that
                // stands still, or a folder that is no repository, rebuilds nobody.
                let known = self.gitStats.snapshot(at: root)
                guard snapshot.state == .ready ? snapshot != known : known != nil else { return }
                self.gitStats.store(snapshot, at: root)
            }
        }
    }

    func marker(_ id: UUID) -> RemoteSessionMarker {
        RemoteSessionMarker.make(id, store: store, runner: runner, gitStats: gitStats, preferences: preferences)
    }

    func snapshot(_ id: UUID, _ state: RemoteSessionState,
                  conversation: RemoteCommand.Conversation) -> RemoteSnapshot {
        RemoteSnapshot(sessionID: id.uuidString, canBrowse: true, conversation: conversation,
                       scope: "All projects",
                       header: state.header, messages: state.messages,
                       queued: state.queued, permission: state.permission)
    }

    // MARK: - Send prompt and stop turn

    // Hands the prompt to the session's runner, as the GUI's composer and the phone do.
    // The runner queues it: it starts at once when the session is free, and after the
    // running turn otherwise. A queued prompt shows in the open session's `queued`.
    public func sendPrompt(_ sessionID: String, prompt: String) throws(StationRefusal) {
        guard let id = UUID(uuidString: sessionID), store.session(id) != nil else {
            throw .noSession
        }
        let text = prompt.trimmed
        guard !text.isEmpty else { throw .emptyPrompt }
        guard text.count <= 100_000 else { throw .longPrompt }
        try admitTurn()
        runner.send(text, sessionID: id, store: store)
        // A walk through earlier prompts ends with the prompt it led to being sent.
        runner.composer.clearDraft(id)
    }

    // MARK: - Recall a prompt

    // Steps through the prompts the session has sent, newest first, the way the GUI
    // composer's arrows do, with the same composer store keeping the walk. `draft` is
    // what the front end's composer holds now. The answer is what it should hold next,
    // or nil when the key belongs to the text being written, or the walk can go no
    // further. Prompts waiting in the queue stay there: only sent prompts are walked.
    public func recallPrompt(_ sessionID: String, _ direction: PromptRecall,
                             draft: String) -> String? {
        guard let id = UUID(uuidString: sessionID), store.session(id) != nil else { return nil }
        let composer = runner.composer
        // The store tells an edited prompt from the one a step put there by comparing
        // texts, so it is told what the front end's composer holds.
        composer.editDraft(id) { $0.text = draft }
        let history = PromptHistory.entries(in: store.transcript(of: id))
        let moved = switch direction {
        case .earlier: composer.recallEarlier(id, history: history)
        case .later: composer.recallLater(id, history: history)
        }
        return moved ? composer.draft(id).text : nil
    }

    // Stops the session's running turn, keeping what has streamed in so far. A session
    // with no turn running is left as it is.
    public func stopTurn(_ sessionID: String) throws(StationRefusal) {
        guard let id = UUID(uuidString: sessionID), store.session(id) != nil else {
            throw .noSession
        }
        runner.stop(id)
    }

    // MARK: - Create session

    // What a new-session form offers: every agent, whether it is installed, its models
    // and the model the app's settings start it on, and the agent a session starts on
    // unless another is picked. The same choices the GUI's sheet and settings read.
    public func sessionOptions() -> RemoteSessionOptions {
        followSharedDefaults()
        let agents = AgentKind.allCases.map { agent in
            RemoteAgentChoice(agent: agent, title: agent.title, installed: runner.isAvailable(agent),
                              models: runner.modelOptions(for: agent).map {
                                  RemoteModelChoice(id: $0.id, title: $0.title, detail: $0.detail)
                              },
                              defaultModel: runner.validModel(runner.defaults(for: agent).model, for: agent))
        }
        return RemoteSessionOptions(agents: agents, defaultAgent: runner.agentForNewSession(selected: nil))
    }

    // Asks an agent's CLI for its own list of models, the first time only, as the GUI
    // does when its model picker first shows that agent. Codex and Copilot publish one;
    // Claude Code's list is fixed. Answers with the options as they now stand.
    public func discoverModels(for agent: AgentKind) async -> RemoteSessionOptions {
        await runner.discoverModels(for: agent)
        return sessionOptions()
    }

    // Starts a session in a project on the agent and model asked for, in a worktree of its
    // own or in the project folder, through the core's session lifecycle, as the GUI's
    // sheet and the phone do. It is saved at once, so the GUI lists it next time. Answers
    // with the new session's id, ready to open.
    public func createSession(_ request: RemoteNewSession) async throws(StationRefusal) -> String {
        try admitTurn()
        followSharedDefaults()
        guard let projectID = UUID(uuidString: request.projectID),
              let project = store.project(projectID) else { throw .noProject }
        guard !store.isMissing(project) else {
            throw StationRefusal("\(project.name) is missing from disk.")
        }
        guard !request.worktree || project.isGitRepository else {
            throw StationRefusal("\(project.name) is not a git repository, so it cannot have a worktree.")
        }
        guard runner.isAvailable(request.agent) else {
            throw StationRefusal("\(request.agent.title) is not installed.")
        }
        guard request.model == nil || runner.validModel(request.model, for: request.agent) != nil else {
            throw StationRefusal("\(request.agent.title) does not offer that model.")
        }
        let result = await SessionLifecycle.createProjectSession(
            in: project, worktree: request.worktree, agent: request.agent, model: request.model,
            agentAvatarName: Preferences.defaultAgentAvatarName(), store: store,
            worktrees: worktrees)
        switch result {
        case .success(let session): return session.id.uuidString
        case .failure(let failure): throw StationRefusal("\(failure.title). \(failure.message)")
        }
    }

    // The agent and the defaults new sessions start on, read again from the shared
    // preferences, which the GUI's Settings may have changed since this host started.
    func followSharedDefaults() {
        runner.adoptDefaults(from: preferences)
    }

    // MARK: - Answer permission

    // Answers what the session's agent is waiting on, as the GUI's permission card and the
    // phone do: allow once, allow always (only when the agent offered it) or deny a tool
    // call, or the answers to a question, one for every question asked, keyed by its
    // text. A question can be denied too, which is the GUI's "Skip". A reason given with
    // a denial goes on as the next prompt, so the agent hears why and not only that it
    // was refused.
    public func answerPermission(_ sessionID: String, requestID: String, answer: RemoteCommand.Answer,
                                 answers: [String: String]? = nil,
                                 reason: String? = nil) throws(StationRefusal) {
        guard let id = UUID(uuidString: sessionID), store.session(id) != nil else {
            throw .noSession
        }
        // The request the open session shows, which is the session's own.
        guard let request = runner.question(id), request.id == requestID else {
            throw .noQuestion
        }
        let chosen: PermissionAnswer
        switch answer {
        case .allowOnce where !request.isQuestion:
            chosen = .allowOnce
        case .allowAlways where !request.isQuestion && request.alwaysTitle != nil:
            chosen = .allowAlways
        case .deny:
            chosen = .deny
        case .allowAddingDirectory where !request.isQuestion:
            guard let session = store.session(id),
                  let folder = request.directoryOutside(store.workingDirectories(for: session)) else {
                throw StationRefusal("This call reaches no folder outside the session's to add.")
            }
            chosen = .allowAddingDirectory(folder)
        case .answers where request.isQuestion:
            let given = (answers ?? [:]).mapValues(\.trimmed)
            guard request.questions.allSatisfy({ given[$0.text]?.isEmpty == false }) else {
                throw .unansweredQuestion
            }
            chosen = .answers(given.filter { key, _ in request.questions.contains { $0.text == key } })
        case .allowOnce, .allowAlways, .allowAddingDirectory, .answers:
            throw .invalidAnswer
        }
        let because = reason?.trimmed ?? ""
        let followUp = chosen == .deny && !because.isEmpty && because.count <= 100_000
        // A reason goes on as a new turn, which a host handing over no longer starts.
        if followUp { try admitTurn() }
        runner.answer(request, with: chosen, sessionID: id, store: store)

        if followUp {
            runner.send(because, sessionID: id, store: store)
        }
    }

    // MARK: - Read changes

    // What the session has changed in every checkout it works in, lead first: a worktree
    // of its own or the project folder itself. Each file comes with its unified diff
    // against the last commit. What git says is kept for the session's header too, so
    // an open session counts git's lines from then on. Nil when there is no such session.
    public func readChanges(_ sessionID: String) async -> RemoteChanges? {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { return nil }
        var read: [RemoteCheckout] = []
        for checkout in changesCheckouts(of: session) {
            let (remote, snapshot) = await StationChangesReader.read(checkout)
            gitStats.store(snapshot, at: checkout.path)
            read.append(remote)
        }
        return RemoteChanges(sessionID: id.uuidString, checkouts: read)
    }

    // MARK: - Confirm a scheduled run

    // Answers a task whose timer waits for confirmation, as the GUI's dialog does: run it
    // now, skip this occurrence, or turn the timer off. A run answers with the session it
    // started.
    public func confirmScheduledRun(_ taskID: String, _ choice: ScheduledRunChoice) throws(StationRefusal) -> String? {
        guard let id = UUID(uuidString: taskID), let task = store.project(id), task.kind == .adHoc else {
            throw StationRefusal("That task is no longer available.")
        }
        guard let schedule = task.task?.schedule, schedule.isActive,
              schedule.isWaitingForConfirmation else {
            throw StationRefusal("\(task.name) has no scheduled run waiting for confirmation.")
        }
        if choice == .run { try admitTurn() }
        let result = ScheduledTaskExecution.confirm(id, choice, store: store, runner: runner,
                                                    agentAvatarName: Preferences.defaultAgentAvatarName())
        switch result {
        case .success(let session): return session?.id.uuidString
        case .failure(let failure): throw StationRefusal(failure.message)
        }
    }

    // MARK: - Handing over

    // Set by a host that hands the station over when another asks (the daemon, or the GUI
    // as it quits): what it does to let go once no turn is left running. It stops serving,
    // saves, sweeps and releases the lock. Nil: asking this host to hand over is refused.
    public var letGo: (@MainActor () -> Void)?
    // Told once, when a handover starts, so the host stops what it starts on its own
    // (schedules, sweeps).
    public var onHandoverStarted: (@MainActor () -> Void)?
    // Told when a handover is given up because the side taking over went away before the
    // host let go, so the host starts again what it stopped.
    public var onHandoverAbandoned: (@MainActor () -> Void)?
    // Who the station is moving to, while a handover is under way.
    public private(set) var successor: String?
    // The client that asked for the handover under way. If it goes before the host has
    // let go, the handover is given up.
    private var handoverClient: StationClientID?
    private var lettingGo = false

    // Starts handing the station over to `successor`, or carries on with the handover
    // already under way. From now on no new turn starts here, and every client hears that
    // the station is moving. Answers with the turns still running, so the next host can
    // ask again until there are none.
    public func handOver(to successor: String,
                         by client: StationClientID? = nil) throws(StationRefusal) -> StationHandoverStatus {
        guard letGo != nil else { throw .doesNotHandOver }
        if handoverClient == nil { handoverClient = client }
        if self.successor == nil {
            self.successor = successor
            SessionLog.note("handing the station over to \(successor)")
            onHandoverStarted?()
            hostEventRelay.announce(.handoverStarting(successor: successor))
        }
        return StationHandoverStatus(running: runningTurns)
    }

    // Every conversation with a turn running: a session's own, and its Design
    // conversation's.
    var runningTurns: [RemoteRunningTurn] {
        store.sessions.flatMap { session -> [RemoteRunningTurn] in
            let project = store.project(session.projectID)?.name ?? ""
            var turns: [RemoteRunningTurn] = []
            if runner.state(session.id).isBusy {
                turns.append(RemoteRunningTurn(sessionID: session.id.uuidString, title: session.title,
                                               project: project))
            }
            if let companion = store.designCompanions[session.id], runner.state(companion.id).isBusy {
                turns.append(RemoteRunningTurn(sessionID: companion.id.uuidString,
                                               title: "\(session.title) (Design)", project: project))
            }
            return turns
        }
    }

    // Lets go of the station once the handover is through: answered first, then the host
    // stops serving, saves, sweeps and releases the lock. Refused while turns still run,
    // which the next host stops or waits for.
    public func releaseStation() throws(StationRefusal) {
        guard let letGo, successor != nil else {
            throw StationRefusal("No handover is under way.")
        }
        let running = runningTurns.count
        guard running == 0 else {
            throw StationRefusal(running == 1 ? "A turn is still running." : "\(running) turns are still running.")
        }
        guard !lettingGo else { return }
        lettingGo = true
        // After the answer has gone back to whoever asked.
        Task { @MainActor in letGo() }
    }

    // The side taking over went away before the host let go (its window closed, or it
    // crashed): nothing will take the station, so the host carries on. New turns run
    // again, the host starts its own work again, and the next list no longer says the
    // station is moving.
    private func abandonHandover() {
        handoverClient = nil
        guard let successor, !lettingGo else { return }
        SessionLog.note("\(successor) went away before taking the station; carrying on")
        self.successor = nil
        onHandoverAbandoned?()
    }

    func admitTurn() throws(StationRefusal) {
        if let successor { throw .handingOver(to: successor) }
    }

    // Whether anything is running in any session, its own turn or its Design companion's.
    public var isBusy: Bool {
        store.sessions.contains { runner.isBusy($0.id, store: store) }
    }

    // MARK: - Quitting

    // What the GUI does on quit: stop every turn, wait for the processes to go, and save.
    public func shutdown() {
        for connection in connections.values.compactMap(\.connection) { connection.letGo() }
        let leftovers = QuitSweep.snapshot()
        runner.stopAll()
        shortcuts.stopAll()
        let swept = leftovers.finish()
        if swept.killed > 0 {
            SessionLog.note("terminal quitting: killed \(swept.killed) processes that ignored the stop, "
                            + "\(swept.left) still running")
            SessionLog.flush()
        }
        _ = store.save()
    }
}

// One reader's live list: the last list it was sent, so an unchanged one is not sent
// again, and the tick that keeps time-based states fresh.
@MainActor
private final class DirectoryWatch {
    let continuation: AsyncStream<RemoteDirectory>.Continuation
    var timer: Task<Void, Never>?
    // Whether an observation tracker is armed and has yet to fire.
    var tracking = false
    private var last: RemoteDirectory?
    private(set) var stopped = false

    init(continuation: AsyncStream<RemoteDirectory>.Continuation) {
        self.continuation = continuation
    }

    func send(_ directory: RemoteDirectory) {
        guard !stopped, directory != last else { return }
        last = directory
        continuation.yield(directory)
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
    }
}

private struct WeakConnection {
    weak var connection: StationConnection?

    init(_ connection: StationConnection) {
        self.connection = connection
    }
}
