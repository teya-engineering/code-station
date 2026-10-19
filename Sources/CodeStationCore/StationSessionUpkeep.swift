import Foundation

// Looking after one session from a client, as the GUI does from a session card's menu and
// from under its transcript: rename, regenerate the title, pin, mark read or unread and
// delete; rewind or fork from a prompt; continue after a failure or a stop, retry a
// stalled turn and dismiss a failure; take back a queued prompt; ask for a recap; and
// send, take or dismiss the suggested next prompt.
//
// Each is one `RemoteSessionAction` sent with `sessionAction`, refused in words when it
// cannot run now. What a client needs to offer them (which prompts can be rewound or
// forked from, whether Continue applies, the recap and the suggestion) travels on the
// open session's header as `RemoteSessionUpkeep`.

public enum RemoteSessionAction: Codable, Equatable, Sendable {
    case rename(title: String)
    case regenerateTitle
    case pin
    case unpin
    case markRead
    case markUnread
    // Ask for `sessionRemovalImpact` first, as the GUI's dialog does.
    case delete
    // `draft` is what the client's composer holds, which moves to the front of the queue
    // as the GUI's draft does, so the returning prompt never writes over it.
    case rewind(messageID: String, draft: String)
    case fork(messageID: String)
    // After a failed turn, or a stopped one.
    case `continue`
    // A stalled turn: stop it and resume its conversation.
    case retry
    case dismissFailure
    case unqueue(promptID: String)
    case recap
    // Sends the suggestion as its own turn. The client sends it only with nothing typed.
    case sendSuggestion
    // Takes the suggestion off the session and answers with it, for the client's composer.
    case takeSuggestion
    case dismissSuggestion
}

// What an action leaves for the client to do on its side: a session to open (a fork) and
// text for that session's composer (the prompt a rewind or fork returns, a suggestion).
public struct RemoteSessionActionResult: Codable, Equatable, Sendable {
    public var openSession: String?
    public var draft: String?

    public init(openSession: String? = nil, draft: String? = nil) {
        self.openSession = openSession
        self.draft = draft
    }
}

// What the open session offers besides sending a prompt, on its header.
public struct RemoteSessionUpkeep: Codable, Equatable, Sendable {
    public var isPinned: Bool
    public var isUnread: Bool
    public var canRegenerateTitle: Bool
    public var isGeneratingTitle: Bool
    // Continue after a failed or stopped turn.
    public var canContinue: Bool
    // Retry a stalled turn.
    public var canRetry: Bool
    public var canRecap: Bool
    public var isRecapping: Bool
    // The last recap, until the session is next worked in.
    public var recap: String?
    // What the agent expects to be asked next, while the session is free.
    public var suggestion: String?
    // The prompts the conversation can go back to, and those a new session can be forked
    // from, by message id. Rewinding also needs the session free.
    public var rewindable: [String]
    public var forkable: [String]

    public init(isPinned: Bool = false, isUnread: Bool = false, canRegenerateTitle: Bool = false,
                isGeneratingTitle: Bool = false, canContinue: Bool = false, canRetry: Bool = false,
                canRecap: Bool = false, isRecapping: Bool = false, recap: String? = nil,
                suggestion: String? = nil, rewindable: [String] = [], forkable: [String] = []) {
        self.isPinned = isPinned
        self.isUnread = isUnread
        self.canRegenerateTitle = canRegenerateTitle
        self.isGeneratingTitle = isGeneratingTitle
        self.canContinue = canContinue
        self.canRetry = canRetry
        self.canRecap = canRecap
        self.isRecapping = isRecapping
        self.recap = recap
        self.suggestion = suggestion
        self.rewindable = rewindable
        self.forkable = forkable
    }

    // How the conversation stands for these actions. `messages` is the transcript, for
    // the prompts it can go back to; without it (the cheap marker) those stay empty and
    // the transcript's revision speaks for them.
    @MainActor
    static func make(_ id: UUID, store: ProjectStore, runner: SessionRunner,
                     messages: [ChatMessage]?) -> RemoteSessionUpkeep {
        let visible = store.userFacingSessionID(for: id)
        let free = !runner.state(id).isBusy && runner.question(id) == nil
        var upkeep = RemoteSessionUpkeep(
            isPinned: store.session(visible)?.isPinned ?? false,
            isUnread: store.isUnread(visible),
            canRegenerateTitle: runner.canRegenerateTitle(id, store: store),
            isGeneratingTitle: runner.isGeneratingTitle(id, store: store),
            canContinue: runner.canContinueAfterFailure(id, store: store)
                || runner.canContinueAfterStop(id, store: store),
            canRetry: runner.canRetryStalled(id, store: store),
            canRecap: runner.canRecap(id, store: store),
            isRecapping: runner.isRecapping(id),
            recap: store.recap(for: id)?.text,
            suggestion: free ? runner.suggestion(id) : nil)
        if let messages {
            let rewindable = store.rewindableMessageIDs(in: id)
            upkeep.rewindable = messages.filter { rewindable.contains($0.id) }.map(\.id.uuidString)
            upkeep.forkable = store.forkableMessageIDs(in: id, messages: messages).map(\.uuidString)
        }
        return upkeep
    }
}

extension StationRefusal {
    static let unnamedSession = StationRefusal("Give the session a name.")
}

extension StationCommands {
    // MARK: - Session upkeep

    // Does one action to a session, or a conversation in it, as the GUI does it.
    public func sessionAction(_ sessionID: String,
                              _ action: RemoteSessionAction) async throws(StationRefusal) -> RemoteSessionActionResult {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
        switch action {
        case .rename(let title):
            guard !title.isBlank else { throw .unnamedSession }
            store.renameSession(id, to: title)
        case .regenerateTitle:
            guard runner.regenerateTitle(id, store: store) else {
                throw StationRefusal(runner.isGeneratingTitle(id, store: store)
                    ? "The title is already being generated."
                    : "The title can be regenerated once the agent has answered and the session is free.")
            }
        case .pin, .unpin:
            store.setPinned(action == .pin, forSession: id)
        case .markRead:
            store.markRead(id)
        case .markUnread:
            store.setMarkedUnread(true, for: id)
        case .delete:
            let result = await SessionLifecycle.remove(session, from: store, runner: runner, worktrees: worktrees)
            if case .failure(let failure) = result { throw StationRefusal("\(failure.title). \(failure.message)") }
        case .rewind(let messageID, let draft):
            guard let message = UUID(uuidString: messageID),
                  runner.canRewind(to: message, sessionID: id, store: store) else {
                throw StationRefusal("The conversation can't go back to that prompt.")
            }
            // The client's half-written prompt goes where the GUI's would: to the front of
            // the queue, out of the returning prompt's way.
            runner.composer.editDraft(id) { $0.text = draft }
            runner.rewind(to: message, sessionID: id, store: store)
            let returned = runner.composer.draft(id).text
            return RemoteSessionActionResult(draft: returned)
        case .fork(let messageID):
            guard let message = UUID(uuidString: messageID),
                  let prompt = store.transcript(of: id).first(where: { $0.id == message }),
                  let fork = store.forkSession(id, before: message, selecting: false) else {
                throw StationRefusal("A new session can't be forked from that prompt.")
            }
            runner.composer.editDraft(fork.id) { $0.text = prompt.text }
            return RemoteSessionActionResult(openSession: fork.id.uuidString, draft: prompt.text)
        case .continue:
            try admitTurn()
            guard runner.continueAfterFailure(id, store: store) || runner.continueAfterStop(id, store: store) else {
                throw StationRefusal("There is nothing to continue.")
            }
        case .retry:
            try admitTurn()
            guard runner.retryStalled(id, store: store) else {
                throw StationRefusal("There is no stalled turn to retry.")
            }
        case .dismissFailure:
            runner.dismissFailure(id)
        case .unqueue(let promptID):
            guard let prompt = UUID(uuidString: promptID),
                  runner.queued(id).contains(where: { $0.id == prompt }) else {
                throw StationRefusal("That prompt is no longer queued.")
            }
            runner.unqueue(prompt, sessionID: id)
        case .recap:
            try admitTurn()
            guard runner.recap(id, store: store) else {
                throw StationRefusal(runner.isRecapping(id)
                    ? "A recap is already being written."
                    : "A recap can be written once the agent has answered and the session is free.")
            }
        case .sendSuggestion:
            try admitTurn()
            guard runner.suggestion(id) != nil else { throw StationRefusal("There is no suggestion to take.") }
            // The client sends it only with nothing typed, so a draft left from walking
            // earlier prompts does not stand in its way.
            runner.composer.editDraft(id) { $0.text = "" }
            runner.sendSuggestion(id, store: store)
        case .takeSuggestion:
            guard let suggestion = runner.suggestion(id) else { throw StationRefusal("There is no suggestion to take.") }
            runner.dismissSuggestion(id)
            return RemoteSessionActionResult(draft: suggestion)
        case .dismissSuggestion:
            runner.dismissSuggestion(id)
        }
        return RemoteSessionActionResult()
    }

    // What deleting the session would take and leave, as the GUI's confirmation says it.
    // Which worktrees hold uncommitted work is asked of git now, since that is what
    // cannot be got back.
    public func sessionRemovalImpact(_ sessionID: String) async throws(StationRefusal) -> RemoteImpact {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else { throw .noSession }
        var dirty: Set<String> = []
        for path in store.checkoutProjects(for: session).compactMap(\.worktreePath)
            where await GitInspector.uncommittedFileCount(at: path) > 0 {
            dirty.insert(path)
        }
        return SessionRemoval.impact(of: session, in: store, isDirty: dirty.contains)
    }
}

extension SessionRemoval {
    // What goes with the session, named before it goes. The worktrees are counted rather
    // than listed because they are the part of this that touches disk, and the dirty ones
    // are called out separately because they are the part that cannot be got back. A run
    // of a task keeps the folder it wrote in, which is worth saying: the folder belongs to
    // the task rather than to the run.
    public static func impact(of session: ChatSession, in store: ProjectStore,
                              isDirty: (String) -> Bool) -> RemoteImpact {
        let checkouts = store.checkoutProjects(for: session)
        let worktrees = checkouts.compactMap(\.worktreePath)
        let dirty = worktrees.count(where: isDirty)
        let removesDesign = store.hasDesignArtifacts(for: session)
        let project = store.project(session.projectID)
        let isTaskRun = project?.kind == .adHoc

        var rows = [RemoteImpact.Row(title: "Conversation history", detail: "Removed from Code Station.")]
        if removesDesign {
            rows.append(.init(title: "Generated Design files", detail: "Permanently removed."))
        }
        if !worktrees.isEmpty {
            rows.append(.init(
                title: counted(worktrees.count, "worktree"),
                detail: "Removed from disk."
                    + (dirty > 0
                       ? " \(dirty) \(dirty == 1 ? "has" : "have") uncommitted changes that will be lost."
                       : " Branches are kept if they have unmerged commits.")))
        }
        if isTaskRun {
            rows.append(.init(title: "Task folder stays", detail: "Files this run wrote in it are kept.", kept: true))
        } else {
            // A checkout without a worktree is the project folder itself, which the session
            // only borrowed.
            let shared = checkouts.filter { $0.worktreePath == nil }
                .compactMap { store.project($0.projectID)?.collapsedPath }
            if !shared.isEmpty {
                rows.append(.init(title: shared.count == 1 ? "Project folder stays" : "Project folders stay",
                                  detail: shared.joined(separator: "\n"), kept: true))
            }
        }

        let subject: RemoteImpact.Subject? = if let workspace = session.workspaceID.flatMap(store.workspace) {
            .init(name: workspace.name, kind: .workspace)
        } else if let project {
            .init(name: project.name, kind: isTaskRun ? .task : .project)
        } else {
            nil
        }
        let action = if isTaskRun {
            "Delete run"
        } else if removesDesign {
            worktrees.isEmpty ? "Delete session and Design files" : "Delete session and files"
        } else {
            worktrees.isEmpty ? "Delete session" : "Delete session and worktrees"
        }
        return RemoteImpact(title: isTaskRun ? "Delete this run?" : "Delete this session?",
                            message: session.title, subject: subject, rows: rows,
                            warning: dirty > 0
                                ? "Uncommitted changes and conversation history cannot be restored."
                                : "Conversation history cannot be restored.",
                            action: action)
    }
}
