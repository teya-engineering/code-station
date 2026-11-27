import Foundation

// One move of a session from one agent to another. The model and effort are the ones the
// agent had when it left, so a switch back can start it where it stopped.
struct AgentSwitchRecord: Codable, Equatable, Sendable {
    var from: AgentKind
    var to: AgentKind
    var date: Date
    var model: String?
    var effort: String?
}

// What a marker line in the transcript records: the agent, model or effort changing
// between turns.
struct SettingsMarker: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case agent, model, effort }

    var kind: Kind
    // The agent in charge once the change is made.
    var agent: AgentKind
    // The agent that handed over, for an agent switch.
    var from: AgentKind?
    // The new value in words: the model's name, the effort level or the agent's name.
    var value: String
    // The model, effort and access the new agent runs with, as one line.
    var settings: String?
    // What the new agent was handed, kept so it can be read back from the marker.
    var handoff: AgentHandoff?
    var note: String?
}

// How much of the session the next agent is given when it takes over.
enum AgentHandoff: String, Codable, Sendable, CaseIterable, Identifiable {
    // A short note written from the transcript. Small, and it can be read and changed
    // before it goes.
    case note
    // Every message as plain text. The new agent cannot reuse another agent's memory, so
    // this is the most it can be given, at the cost of a large first prompt.
    case transcript
    // Nothing from the chat. The new agent starts cold on the files as they are.
    case worktree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note: "Handoff note"
        case .transcript: "Whole transcript"
        case .worktree: "Just the worktree"
        }
    }

    // What the new agent read, as the moving chip in the progress view names it.
    var carried: String {
        switch self {
        case .note: "Handoff note"
        case .transcript: "Transcript"
        case .worktree: "Worktree"
        }
    }
}

// How freely an agent may act, across the three agents' own access settings. Each agent
// names its levels differently, so a switch has to map one onto another.
enum AgentAccess: Equatable, Hashable, Sendable {
    case claudeCode(PermissionMode)
    case codex(CodexSandboxMode)
    case copilot(CopilotAccessMode)

    var title: String {
        switch self {
        case .claudeCode(let mode): mode.shortTitle
        case .codex(let mode): mode.summary
        case .copilot(let mode): mode.summary
        }
    }

    var detail: String {
        switch self {
        case .claudeCode(let mode): mode.detail
        case .codex(let mode): mode.detail
        case .copilot(let mode): mode.detail
        }
    }

    var tone: TrustTone {
        switch self {
        case .claudeCode(let mode): TrustTone(mode)
        case .codex(let mode): TrustTone(mode)
        case .copilot(let mode): TrustTone(mode)
        }
    }

    var isUnrestricted: Bool { tone == .unrestricted }

    static func choices(for agent: AgentKind) -> [AgentAccess] {
        switch agent {
        case .claudeCode: PermissionMode.allCases.map(AgentAccess.claudeCode)
        case .codex: CodexSandboxMode.allCases.map(AgentAccess.codex)
        case .copilot: CopilotAccessMode.allCases.map(AgentAccess.copilot)
        }
    }

    // The level a session runs with now: its own choice, or the app default for the agent.
    static func current(for agent: AgentKind, settings: SessionSettings?,
                        defaults: SessionSettings) -> AgentAccess {
        switch agent {
        case .claudeCode:
            .claudeCode(settings?.permissionMode ?? defaults.permissionMode ?? .fallback)
        case .codex:
            .codex(settings?.codexSandboxMode ?? defaults.codexSandboxMode ?? .workspaceWrite)
        case .copilot:
            .copilot(settings?.copilotAccessMode ?? defaults.copilotAccessMode ?? .workspace)
        }
    }

    // The level on another agent closest to this one without letting it do more. A level
    // only gets looser on a switch when the person picks it.
    func nearest(on agent: AgentKind) -> AgentAccess {
        switch (self, agent) {
        case (.claudeCode, .claudeCode), (.codex, .codex), (.copilot, .copilot):
            return self
        case (.claudeCode(let mode), .codex):
            // Codex cannot stop mid-turn to ask. Claude judging each step itself is closest
            // to Codex approving its own retries; anything that asks more keeps the sandbox.
            return .codex(mode == .auto ? .approveForMe : .workspaceWrite)
        case (.claudeCode, .copilot):
            return .copilot(.workspace)
        case (.codex(let mode), .claudeCode):
            return .claudeCode(mode == .workspaceWrite ? .acceptEdits : .auto)
        case (.copilot(let mode), .claudeCode):
            return .claudeCode(mode == .workspace ? .acceptEdits : .auto)
        case (.codex(let mode), .copilot):
            return .copilot(mode == .fullAccess ? .fullAccess : .workspace)
        case (.copilot(let mode), .codex):
            return .codex(mode == .fullAccess ? .fullAccess : .workspaceWrite)
        }
    }

    // Puts this level into the session's settings, on the field its agent reads.
    func apply(to settings: inout SessionSettings) {
        switch self {
        case .claudeCode(let mode): settings.permissionMode = mode
        case .codex(let mode): settings.codexSandboxMode = mode
        case .copilot(let mode): settings.copilotAccessMode = mode
        }
    }
}

// Something the person should know before an agent switch goes ahead. Only real
// differences in how the next agent behaves are listed.
struct AgentSwitchWarning: Equatable, Identifiable, Sendable {
    enum Tone: Equatable, Sendable { case info, caution, danger }

    let tone: Tone
    let title: String
    let detail: String

    var id: String { title }
}

enum AgentSwitch {
    // One line under an agent in the agent menu, on how it differs from the one in use.
    static func blurb(for agent: AgentKind, returning: Bool) -> String {
        if returning { return "Picks up its own conversation, plus what happened since." }
        switch agent {
        case .claudeCode: return "Asks before risky steps. Takes prompts mid-turn."
        case .codex: return "Runs in a sandbox. Takes prompts mid-turn."
        case .copilot: return "Prompts sent mid-turn wait for the turn to end."
        }
    }

    // The short name a sentence uses, as in "Unlocks when Claude finishes".
    static func shortName(of agent: AgentKind) -> String {
        agent == .claudeCode ? "Claude" : agent.title
    }

    static func warnings(from: AgentKind, to: AgentKind, currentAccess: AgentAccess,
                         newAccess: AgentAccess, returning: Bool) -> [AgentSwitchWarning] {
        var warnings: [AgentSwitchWarning] = []
        if newAccess.isUnrestricted {
            warnings.append(AgentSwitchWarning(
                tone: .danger,
                title: "Full access lets \(to.title) run anything on this Mac",
                detail: "No sandbox and no questions. It can reach your GPG agent, keychain prompts "
                    + "and the network. Pick this only if the next step needs it, such as a signed commit."))
        } else if newAccess.title != currentAccess.title {
            let detail: String = switch newAccess {
            case .codex(let mode):
                "Codex can't stop mid-turn to ask you. "
                    + (mode == .workspaceWrite ? "It will refuse anything outside the worktree. "
                                               : "It approves sandboxed steps on its own. ")
                    + "The sandbox also blocks the GPG agent, so signed commits will fail."
            case .copilot:
                "Copilot can't stop mid-turn to ask you. Tools run without asking inside this "
                    + "session's folders, and files elsewhere and web addresses stay blocked."
            case .claudeCode(let mode):
                mode.detail
            }
            warnings.append(AgentSwitchWarning(
                tone: .caution,
                title: "Access changes from \"\(currentAccess.title)\" to \"\(newAccess.title)\"",
                detail: detail))
        }
        if to == .copilot {
            warnings.append(AgentSwitchWarning(
                tone: .caution,
                title: "Prompts you send mid-turn will wait",
                detail: "Copilot cannot be steered while it works. A prompt sent during a turn "
                    + "waits until that turn ends."))
        }
        if returning {
            warnings.append(AgentSwitchWarning(
                tone: .info,
                title: "\(to.title) resumes its own conversation",
                detail: "It still remembers everything up to when it handed over. What it is "
                    + "given only covers what \(from.title) did after that."))
        }
        return warnings
    }

    // MARK: - What the next agent reads

    // The part of the transcript the next agent has not seen: everything, or only what
    // came after it last handed over when it is coming back.
    static func unseenMessages(_ messages: [ChatMessage], by agent: AgentKind) -> [ChatMessage] {
        guard let left = messages.lastIndex(where: {
            $0.marker?.kind == .agent && $0.marker?.from == agent
        }) else { return messages }
        return Array(messages[(left + 1)...])
    }

    // The conversation as plain text, one block per message, with each call the agent
    // made on a line of its own. Older messages go first when the text is too long, since
    // the latest work is what the next agent needs most.
    static func plainTranscript(_ messages: [ChatMessage], agent: AgentKind,
                                projectPath: String, limit: Int = 300_000) -> String {
        var blocks: [String] = []
        var speaker = agent
        for message in messages {
            if let marker = message.marker, marker.kind == .agent { speaker = marker.agent }
            switch message.role {
            case .user:
                let text = message.text.trimmed
                if !text.isEmpty { blocks.append("Person:\n\(text)") }
            case .assistant:
                var lines: [String] = []
                for tool in message.tools {
                    let presentation = ToolPresentationCache.presentation(for: tool, projectPath: projectPath)
                    let ending = tool.isError ? " (failed)" : ""
                    lines.append("- \(presentation.label)\(ending)")
                }
                let text = message.text.trimmed
                if !text.isEmpty { lines.append(text) }
                if !lines.isEmpty { blocks.append("\(speaker.title):\n" + lines.joined(separator: "\n")) }
            case .system:
                let text = message.text.trimmed
                if !text.isEmpty { blocks.append("[\(text)]") }
            case .instructions:
                break
            }
        }
        let text = blocks.joined(separator: "\n\n")
        guard text.count > limit else { return text }
        return "[Older messages were cut to fit.]\n\n" + String(text.suffix(limit))
    }

    // A rough count, used only to say how big a handoff is.
    static func estimatedTokens(_ text: String) -> Int { (text.utf8.count + 3) / 4 }

    // Asked of the agent that is handing over, in a throwaway run that never touches its
    // conversation.
    static func notePrompt(transcript: String, from: AgentKind, to: AgentKind) -> String {
        """
        Do not use tools and do not change any files. Below is a conversation between a person and \(from.title), a coding agent, working in a code repository. \(to.title) takes over the work next and has not seen any of it. Write a short handoff note for \(to.title) in Markdown with three sections: "## Goal" with one or two sentences, "## Done so far" with bullets on what changed, which files, and which commands ran and how they ended, and "## Open questions" with bullets, or "- None". Use plain, short sentences. Name files and commands exactly. Only say what the conversation shows. Return only the note.

        <conversation>
        \(transcript)
        </conversation>
        """
    }

    // The note the dialog falls back to when the agent cannot write one: the first ask as
    // the goal, and the latest asks and calls as what was done.
    static func plainNote(_ messages: [ChatMessage], projectPath: String) -> String {
        let prompts = messages.filter { $0.role == .user }.map(\.text.trimmed).filter { !$0.isEmpty }
        let goal = prompts.first.map { firstLine($0) } ?? "Carry on with the work in this folder."
        var done: [String] = []
        for tool in messages.flatMap(\.tools) where !tool.isRunning {
            let presentation = ToolPresentationCache.presentation(for: tool, projectPath: projectPath)
            // Reads and searches say little about what was done; edits and commands do.
            guard presentation.added != nil || presentation.removed != nil
                    || presentation.command != nil else { continue }
            let line = "- \(presentation.label)\(tool.isError ? " (failed)" : "")"
            if !done.contains(line) { done.append(line) }
        }
        let recentAsks = prompts.dropFirst().suffix(3).map { "- Asked: \(firstLine($0))" }
        let doneLines = (Array(done.suffix(8)) + recentAsks)
        return """
        ## Goal
        \(goal)

        ## Done so far
        \(doneLines.isEmpty ? "- Nothing yet." : doneLines.joined(separator: "\n"))

        ## Open questions
        - None noted.
        """
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    // The first prompt the next agent gets. It is sent by the app, not typed, so it stays
    // out of the transcript; the marker above it holds what was handed over. Nil when the
    // agent is given nothing and waits for the person instead.
    static func handoffPrompt(_ handoff: AgentHandoff, text: String, from: AgentKind,
                              to: AgentKind, returning: Bool) -> String? {
        let opening = returning
            ? "You are back in this session. While you were away, \(from.title) worked in the same folder, and every change it made is still there."
            : "You are taking over this session from \(from.title). It worked in this same folder, and every change it made is still there."
        let body: String
        switch handoff {
        case .worktree:
            return nil
        case .note:
            body = "Here is its handoff note:\n\n<handoff-note>\n\(text)\n</handoff-note>"
        case .transcript:
            body = "Here is the conversation \(returning ? "since you handed over" : "so far"), as plain text:\n\n<transcript>\n\(text)\n</transcript>"
        }
        return """
        \(opening) \(body)

        Do not change anything yet. Reply in two or three short sentences: what you are taking over, and what you would do next. Then wait for the person.
        """
    }

    // MARK: - Checking the next CLI

    // The number in what "<cli> --version" prints. Each CLI words it differently:
    // "2.1.220 (Claude Code)", "codex-cli 0.52.0", "GitHub Copilot CLI 1.0.83.".
    static func versionNumber(from output: String, agent: AgentKind) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let words = line.split(separator: " ")
        let word = agent == .claudeCode ? words.first : words.last
        let number = word.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return number?.isEmpty == false ? number : nil
    }
}
