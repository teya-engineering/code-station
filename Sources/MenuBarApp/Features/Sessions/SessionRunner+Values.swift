import Foundation

// The values the runner hands out and the rules it applies to plain text. Nothing here
// reads or changes a session.
extension SessionRunner {
    // How a CLI says it no longer holds the conversation we asked to resume. Codex has
    // no such message: a thread it cannot find is a failed turn like any other.
    nonisolated static func lostConversation(_ agent: AgentKind) -> String? {
        switch agent {
        case .claudeCode: "No conversation found with session ID"
        case .codex: nil
        case .copilot: "No session, task, or name matched"
        // Loading an id Kiro does not know quietly opens an empty session under it, so
        // there is no message to watch for.
        case .kiro: nil
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
        case .kiro: ["authentication required", "kiro-cli login", "not logged in",
                     "token has expired", "session has expired"]
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
        var askedFor = false
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

    // When a prompt sent during a turn reaches the agent. Now means inside the turn that is
    // running, if the agent can take it there; otherwise, and after the turn, the prompt
    // waits its turn in the queue.
    enum PromptDelivery: String { case now, afterTurn }

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

    // Two roots are the same working tree to an agent whenever either sits inside the
    // other, not only when they name the same folder. A repository added as one project
    // and a package inside it added as another are still two agents editing one tree.
    nonisolated static func overlaps(_ first: String, _ second: String) -> Bool {
        first.pathRelative(to: second) != nil || second.pathRelative(to: first) != nil
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

    // What a new usage report adds over the one before it. Clamped at zero so a report
    // that is not cumulative after all can only under-count, never charge twice.
    nonisolated static func grown(_ totals: TurnUsage, since recorded: TurnUsage?) -> TurnUsage {
        guard let recorded else { return totals }
        var grown = totals
        grown.costUSD = max(0, totals.costUSD - recorded.costUSD)
        grown.credits = max(0, totals.credits - recorded.credits)
        grown.inputTokens = max(0, totals.inputTokens - recorded.inputTokens)
        grown.outputTokens = max(0, totals.outputTokens - recorded.outputTokens)
        grown.cacheReadTokens = max(0, totals.cacheReadTokens - recorded.cacheReadTokens)
        grown.cacheWriteTokens = max(0, totals.cacheWriteTokens - recorded.cacheWriteTokens)
        return grown
    }

    // A dialog grows to fit its message, so a CLI that dumps a stack trace would push the
    // buttons off screen. The opening lines usually name the problem.
    nonisolated static func dialogExcerpt(_ text: String, lines: Int = 4, characters: Int = 400) -> String {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lines).joined(separator: "\n")
        let clipped = kept.count > characters ? String(kept.prefix(characters)) : kept
        return clipped.count < text.count ? clipped.trimmed + "…" : clipped
    }
}
