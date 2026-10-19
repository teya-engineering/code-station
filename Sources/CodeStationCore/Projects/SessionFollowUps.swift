import Foundation

@MainActor
public final class SessionFollowUps {
    public typealias SummaryAttempt = SessionRunner.SummaryAttempt
    public typealias SummaryMode = SessionRunner.SummaryMode
    public typealias SummaryRestingState = SessionRunner.SummaryRestingState

    private var suggestionRequests: [UUID: UUID] = [:]
    private let automaticRecapsEnabled: () -> Bool
    private let automaticTitlesEnabled: () -> Bool
    public let promptSuggestionsEnabled: () -> Bool

    public init(automaticRecapsEnabled: @escaping () -> Bool,
         automaticTitlesEnabled: @escaping () -> Bool,
         promptSuggestionsEnabled: @escaping () -> Bool) {
        self.automaticRecapsEnabled = automaticRecapsEnabled
        self.automaticTitlesEnabled = automaticTitlesEnabled
        self.promptSuggestionsEnabled = promptSuggestionsEnabled
    }

    public func invalidateSuggestion(_ sessionID: UUID) {
        suggestionRequests[sessionID] = nil
    }

    // Claude Code predicts the next prompt as part of the turn and says so on its stream,
    // which costs nothing on top. The others have to be asked, so they are asked in a run
    // of their own that never touches the session's conversation.
    public func requestPromptSuggestion(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner) {
        // One ask per turn. The record is cleared when the next turn starts, so this is
        // also what stops a recap finishing afterwards from asking all over again.
        guard promptSuggestionsEnabled(), !runner.isBeingRemoved(sessionID),
              suggestionRequests[sessionID] == nil,
              let session = store.session(sessionID), !session.agent.predictsPrompts,
              let path = runner.catalog.executable(for: session.agent), !runner.state(sessionID).isBusy else { return }

        let transcript = store.transcript(of: sessionID)
        guard let reply = transcript.last(where: { $0.role == .assistant && !$0.text.isBlank }),
              let asked = transcript.last(where: { $0.role == .user && !$0.text.isBlank })
        else { return }
        guard let directory = store.workingDirectories(for: session).first else { return }

        let token = UUID()
        suggestionRequests[sessionID] = token
        let agent = session.agent
        let model = ModelChoice.valid(session.settings?.model, for: agent,
                                      discovered: runner.discoveredModels[agent])
        let searchPath = ExecutableSearch.searchPath
        let prompt = PromptSuggestion.conversationTail(lastPrompt: asked.text,
                                                       lastReply: reply.text)
        SessionLog.note("asking \(agent.command) for a prompt suggestion", session: sessionID)
        Task { [weak self, weak runner] in
            let suggestion = await PromptSuggestion.read(
                agent: agent, at: path, searchPath: searchPath,
                workingDirectory: directory, prompt: prompt, model: model)
            await MainActor.run {
                SessionLog.note(suggestion == nil ? "no prompt suggestion returned"
                                : "prompt suggestion received", session: sessionID)
                guard let self, self.suggestionRequests[sessionID] == token,
                      let suggestion, self.promptSuggestionsEnabled() else { return }
                runner?.acceptSuggestion(suggestion, for: sessionID)
            }
        }
    }

    // MARK: - Recapping the conversation

    // Claude Code has a local recap command. Codex compaction is opaque and cannot be
    // shown to a person, so it receives the same focused summary request used when the
    // Claude Code command is missing or unavailable.
    public nonisolated static let recapPrompt = """
    Do not use tools or change files. Write a short, easy-to-read recap of this conversation. Use simple English and at most 35 words. Include only the main goal, the result or blocker, and the next step when one is needed. Leave out background, minor details, and commentary. Use no markdown. Return only the recap.
    """

    public func canRecap(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner) -> Bool {
        guard let session = store.session(sessionID), session.hasAgentConversation,
              !runner.state(sessionID).isBusy, !runner.isBeingRemoved(sessionID) else { return false }
        return !runner.isRecapping(sessionID)
    }

    @discardableResult
    public func requestRecap(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner) -> Bool {
        guard canRecap(sessionID, store: store, runner: runner), let session = store.session(sessionID) else {
            return false
        }
        let restingState: SummaryRestingState = if case .failed(let message) = runner.state(sessionID) {
            .failed(message)
        } else {
            .idle
        }
        let mode: SummaryMode = session.agent == .claudeCode ? .claudeRecap : .promptRecap
        let prompt = mode == .claudeRecap ? "/recap" : Self.recapPrompt
        runner.enqueueSummary(SessionRunner.QueuedPrompt(
            text: prompt,
            attachments: [],
            customInstructions: nil,
            isAppCommand: true,
            summary: SummaryAttempt(mode: mode, restingState: restingState)),
                              sessionID: sessionID, store: store)
        SessionLog.note("generating session recap", session: sessionID)
        return true
    }

    public func requestAutomaticRecap(_ sessionID: UUID, unseen: Bool,
                                       store: ProjectStore, runner: SessionRunner) {
        guard unseen, automaticRecapsEnabled() else { return }
        _ = requestRecap(sessionID, store: store, runner: runner)
    }

    // MARK: - Session titles

    public func titleConversationID(_ sessionID: UUID, store: ProjectStore) -> UUID {
        guard store.session(sessionID)?.isImplementingDesign != true else { return sessionID }
        return store.designConversation(for: sessionID)?.id ?? sessionID
    }

    public func canRegenerateTitle(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner) -> Bool {
        let conversationID = titleConversationID(sessionID, store: store)
        guard let session = store.session(conversationID),
              session.agentSessionID(for: session.agent)?.isEmpty == false,
              !runner.state(sessionID).isBusy, !runner.state(conversationID).isBusy,
              !runner.isBeingRemoved(sessionID), !runner.isBeingRemoved(conversationID) else { return false }
        return !runner.isGeneratingTitle(sessionID, store: store)
    }

    @discardableResult
    public func regenerateTitle(_ sessionID: UUID, store: ProjectStore, runner: SessionRunner) -> Bool {
        guard canRegenerateTitle(sessionID, store: store, runner: runner),
              let session = store.session(store.userFacingSessionID(for: sessionID)) else {
            return false
        }
        let conversationID = titleConversationID(sessionID, store: store)
        let restingState: SummaryRestingState = if case .failed(let message) = runner.state(conversationID) {
            .failed(message)
        } else {
            .idle
        }
        runner.enqueueSummary(SessionRunner.QueuedPrompt(
            text: SessionTitle.prompt, attachments: [], customInstructions: nil,
            isAppCommand: true,
            summary: SummaryAttempt(mode: .title(SessionTitleRequest(session)),
                                    restingState: restingState)),
                              sessionID: conversationID, store: store)
        SessionLog.note("generating session title", session: conversationID)
        return true
    }

    public func queueAutomaticTitle(isFirstTurn: Bool, sessionID: UUID,
                                     store: ProjectStore, runner: SessionRunner) -> Bool {
        guard isFirstTurn, automaticTitlesEnabled(),
              let session = store.session(store.userFacingSessionID(for: sessionID)),
              session.titleRevision == nil,
              let conversation = store.session(sessionID),
              conversation.agentSessionID(for: conversation.agent)?.isEmpty == false,
              !runner.isBeingRemoved(session.id), !runner.isBeingRemoved(sessionID) else { return false }

        // A title gets the first turn's context before any queued follow-up runs. If
        // no work is queued, the completed task can already be marked ready to review.
        let noQueuedWork = runner.queued(sessionID).isEmpty
        var unseen = false
        if noQueuedWork {
            unseen = store.noteTurnEnded(for: sessionID)
            runner.announceTurnEnded(sessionID: session.id, sessionTitle: session.title, failure: nil)
        }
        runner.enqueueSummary(SessionRunner.QueuedPrompt(
            text: SessionTitle.prompt, attachments: [], customInstructions: nil,
            isAppCommand: true,
            summary: SummaryAttempt(mode: .title(SessionTitleRequest(session)),
                                    restingState: .idle, recapAfterTitle: unseen)),
                              sessionID: sessionID, atFront: true, start: false, store: store)
        return true
    }

}
