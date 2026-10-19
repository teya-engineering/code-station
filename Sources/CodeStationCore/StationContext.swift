import Foundation

// The top bar's context actions, as the GUI's facts chip offers them under CONTEXT:
// Compact and Clear. Whether each is on offer travels on the session header
// (`canCompact`, `canClear`); asking for one that is not is refused with the reason.
extension StationCommands {
    // Hands Claude Code its own `/compact` as a turn: the agent reads the conversation,
    // replaces it with a summary and carries on from that. Codex has no such command.
    public func compactContext(_ sessionID: String) throws(StationRefusal) {
        guard let id = UUID(uuidString: sessionID), let session = store.session(id) else {
            throw .noSession
        }
        guard session.agent == .claudeCode else {
            throw StationRefusal("\(session.agent.title) makes room in its context by itself.")
        }
        guard !runner.state(id).isBusy else { throw .turnRunning }
        guard session.hasAgentConversation else { throw .noConversation }
        try admitTurn()
        guard runner.compact(id, store: store) else {
            throw StationRefusal("This session's context cannot be compacted now.")
        }
    }

    // Drops the conversation the agent resumes, so the next turn starts a fresh one in
    // the same folder. The transcript stays, with a note saying so.
    public func clearContext(_ sessionID: String) throws(StationRefusal) {
        guard let id = UUID(uuidString: sessionID), store.session(id) != nil else {
            throw .noSession
        }
        switch runner.clearContext(id, store: store) {
        case .cleared: return
        case .busy: throw .turnRunning
        case .nothingToClear: throw .noConversation
        }
    }
}

extension StationRefusal {
    static let turnRunning = StationRefusal("Wait for the running turn to end first.")
    static let noConversation = StationRefusal("There is no conversation to act on yet.")
}
