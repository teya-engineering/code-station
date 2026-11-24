import Foundation

// What the runner does once a turn has ended: suggest the next prompt, recap the
// conversation and name the session.
extension SessionRunner {
    // Claude Code predicts the next prompt as part of the turn and says so on its stream,
    // which costs nothing on top. The others have to be asked, so they are asked in a run
    // of their own that never touches the session's conversation.
    func requestPromptSuggestion(_ sessionID: UUID) {
        // One ask per turn. The record is cleared when the next turn starts, so this is
        // also what stops a recap finishing afterwards from asking all over again.
        guard promptSuggestionsEnabled(), !isBeingRemoved(sessionID),
              suggestionRequests[sessionID] == nil,
              let session = store.session(sessionID), !session.agent.predictsPrompts,
              let path = catalog.executable(for: session.agent), !state(sessionID).isBusy else { return }

        let transcript = store.transcript(of: sessionID)
        guard let reply = transcript.last(where: { $0.role == .assistant && !$0.text.isBlank }),
              let asked = transcript.last(where: { $0.role == .user && !$0.text.isBlank })
        else { return }
        guard let directory = store.workingDirectories(for: session).first else { return }

        let token = UUID()
        suggestionRequests[sessionID] = token
        let agent = session.agent
        let model = ModelChoice.valid(session.settings?.model, for: agent,
                                      discovered: catalog.discoveredModels[agent])
        let searchPath = ProcessManager.searchPath
        let prompt = PromptSuggestion.conversationTail(lastPrompt: asked.text,
                                                       lastReply: reply.text)
        SessionLog.note("asking \(agent.command) for a prompt suggestion", session: sessionID)
        Task { [weak self] in
            let suggestion = await PromptSuggestion.read(
                agent: agent, at: path, searchPath: searchPath,
                workingDirectory: directory, prompt: prompt, model: model)
            SessionLog.note(suggestion == nil ? "no prompt suggestion returned"
                            : "prompt suggestion received", session: sessionID)
            guard let self, self.suggestionRequests[sessionID] == token,
                  let suggestion, self.promptSuggestionsEnabled() else { return }
            self.acceptSuggestion(suggestion, for: sessionID)
        }
    }

    // MARK: - Recapping the conversation

    // Claude Code has a local recap command. Codex compaction is opaque and cannot be
    // shown to a person, so it receives the same focused summary request used when the
    // Claude Code command is missing or unavailable.
    nonisolated static let recapPrompt = """
    Do not use tools or change files. Write a short, easy-to-read recap of this conversation. Use simple English and at most 35 words. Include only the main goal, the result or blocker, and the next step when one is needed. Leave out background, minor details, and commentary. Use no markdown. Return only the recap.
    """

    func isRecapping(_ sessionID: UUID) -> Bool { hasSummary(sessionID, title: false) }

    func canRecap(_ sessionID: UUID) -> Bool {
        guard let session = store.session(sessionID), session.hasAgentConversation,
              !state(sessionID).isBusy, !isBeingRemoved(sessionID) else { return false }
        return !isRecapping(sessionID)
    }

    @discardableResult
    func recap(_ sessionID: UUID) -> Bool {
        guard canRecap(sessionID), let session = store.session(sessionID) else {
            return false
        }
        let restingState: SummaryRestingState = if case .failed(let message) = state(sessionID) {
            .failed(message)
        } else {
            .idle
        }
        let mode: SummaryMode = session.agent == .claudeCode ? .claudeRecap : .promptRecap
        let prompt = mode == .claudeRecap ? "/recap" : Self.recapPrompt
        enqueueSummary(QueuedPrompt(
            text: prompt,
            attachments: [],
            customInstructions: nil,
            isAppCommand: true,
            summary: SummaryAttempt(mode: mode, restingState: restingState)),
                              sessionID: sessionID)
        SessionLog.note("generating session recap", session: sessionID)
        return true
    }

    func requestAutomaticRecap(_ sessionID: UUID, unseen: Bool) {
        guard unseen, automaticRecapsEnabled() else { return }
        _ = recap(sessionID)
    }

    // MARK: - Session titles

    func titleConversationID(_ sessionID: UUID) -> UUID {
        guard store.session(sessionID)?.isImplementingDesign != true else { return sessionID }
        return store.designConversation(for: sessionID)?.id ?? sessionID
    }

    func isGeneratingTitle(_ sessionID: UUID) -> Bool {
        hasSummary(titleConversationID(sessionID), title: true)
    }

    func canRegenerateTitle(_ sessionID: UUID) -> Bool {
        let conversationID = titleConversationID(sessionID)
        guard let session = store.session(conversationID),
              session.agentSessionID(for: session.agent)?.isEmpty == false,
              !state(sessionID).isBusy, !state(conversationID).isBusy,
              !isBeingRemoved(sessionID), !isBeingRemoved(conversationID) else { return false }
        return !isGeneratingTitle(sessionID)
    }

    @discardableResult
    func regenerateTitle(_ sessionID: UUID) -> Bool {
        guard canRegenerateTitle(sessionID),
              let session = store.session(store.userFacingSessionID(for: sessionID)) else {
            return false
        }
        let conversationID = titleConversationID(sessionID)
        let restingState: SummaryRestingState = if case .failed(let message) = state(conversationID) {
            .failed(message)
        } else {
            .idle
        }
        enqueueSummary(QueuedPrompt(
            text: SessionTitle.prompt, attachments: [], customInstructions: nil,
            isAppCommand: true,
            summary: SummaryAttempt(mode: .title(SessionTitleRequest(session)),
                                    restingState: restingState, askedFor: true)),
                              sessionID: conversationID)
        SessionLog.note("generating session title", session: conversationID)
        return true
    }

    func queueAutomaticTitle(isFirstTurn: Bool, sessionID: UUID) -> Bool {
        guard isFirstTurn, automaticTitlesEnabled(),
              let session = store.session(store.userFacingSessionID(for: sessionID)),
              session.titleRevision == nil,
              let conversation = store.session(sessionID),
              conversation.agentSessionID(for: conversation.agent)?.isEmpty == false,
              !isBeingRemoved(session.id), !isBeingRemoved(sessionID) else { return false }

        // A title gets the first turn's context before any queued follow-up runs. If
        // no work is queued, the completed task can already be marked ready to review.
        let noQueuedWork = queued(sessionID).isEmpty
        var unseen = false
        if noQueuedWork {
            unseen = store.noteTurnEnded(for: sessionID)
            AppNotifier.shared.turnEnded(sessionID: session.id,
                                         sessionTitle: session.title, failure: nil)
        }
        enqueueSummary(QueuedPrompt(
            text: SessionTitle.prompt, attachments: [], customInstructions: nil,
            isAppCommand: true,
            summary: SummaryAttempt(mode: .title(SessionTitleRequest(session)),
                                    restingState: .idle, recapAfterTitle: unseen)),
                              sessionID: sessionID, atFront: true, start: false)
        return true
    }
}
