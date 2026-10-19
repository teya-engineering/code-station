import Foundation

// A question asked on the Changes screen. It is answered there, by a side copy of the
// session, and never reaches the main chat: only changes go to the agent, with the review.
// The question, its answer and any follow-ups are kept with the review.
public struct ReviewQuestion: Identifiable, Codable, Equatable, Sendable {
    // One question and what came back: the first one asked, or a follow-up.
    public struct Exchange: Identifiable, Codable, Equatable, Sendable {
        public var id = UUID()
        public var question: String
        public var asked = Date()
        public var answer: String?
        // A change the answer proposes, in words that can go to the agent as a comment.
        public var suggestion: String?
        public var answered: Date?
        public var failure: String?
    }

    public enum Status: Equatable, Sendable {
        case answering, answered, failed
    }

    public var id = UUID()
    public var root: String
    // Empty for a question about the whole change rather than some lines of it.
    public var path: String
    public var side: ReviewSide
    public var line: Int
    public var lastLine: Int?
    public var excerpt: String
    public var excerptOffsets: [Int]?
    public var created = Date()
    public var agent: AgentKind
    public var exchanges: [Exchange]
    // The side copy's own conversation, so a follow-up goes on where the answer left off.
    public var forkID: String?
    public var resolved = false
    // The comment made from the answer's suggestion, waiting in the review or sent with it.
    public var changeID: UUID?

    public init(root: String, path: String, anchor: DiffAnchor, excerpt: String, excerptOffsets: [Int]? = nil,
         agent: AgentKind, question: String) {
        self.root = root
        self.path = path
        side = anchor.side
        line = anchor.line
        lastLine = anchor.lastLine
        self.excerpt = excerpt
        self.excerptOffsets = excerptOffsets
        self.agent = agent
        exchanges = [Exchange(question: question)]
    }

    public static func whole(root: String, agent: AgentKind, question: String) -> ReviewQuestion {
        ReviewQuestion(root: root, path: "", anchor: DiffAnchor(side: .new, line: 0), excerpt: "",
                       agent: agent, question: question)
    }

    public var isWhole: Bool { path.isEmpty }

    public var anchor: DiffAnchor { DiffAnchor(side: side, line: line, lastLine: lastLine) }

    public var text: String { exchanges.first?.question ?? "" }

    public var status: Status {
        guard let last = exchanges.last else { return .answered }
        if last.answer != nil { return .answered }
        return last.failure != nil ? .failed : .answering
    }

    public var failure: String? { exchanges.last?.failure }

    // The latest change any answer proposed.
    public var suggestion: String? { exchanges.last { $0.suggestion != nil }?.suggestion }

    public var linesLabel: String { isWhole ? "Whole change" : anchor.label }

    public var spokenName: String {
        let state = switch status {
        case .answering: "answering"
        case .answered: "answered"
        case .failed: "could not answer"
        }
        return "Question on \(linesLabel.lowercased()), \(state): \(text)"
    }

    // What a change made from this question says about where it came from, when the
    // person chooses to send that along.
    public var why: String? {
        guard let answer = exchanges.first?.answer, !answer.isBlank else { return nil }
        return "I asked \"\(text.trimmed)\" and the answer was: " + answer.trimmed
    }
}

// What a side copy needs to answer a question: which agent, where it runs, and what the
// session has said so far.
public struct QuestionContext: Sendable {
    public var agent: AgentKind
    public var executable: String?
    // The folder the session runs in. Claude keeps its conversations by folder, so a
    // fork has to start in the same one.
    public var directory: String
    public var repositories: [ReviewRepository]
    // Claude's id for the session's conversation, to fork it. Nil before the first turn.
    public var conversationID: String?
    public var recentChat: String

    public init(agent: AgentKind, executable: String? = nil, directory: String, repositories: [ReviewRepository], conversationID: String? = nil, recentChat: String) {
        self.agent = agent
        self.executable = executable
        self.directory = directory
        self.repositories = repositories
        self.conversationID = conversationID
        self.recentChat = recentChat
    }
}

// A side copy of the session answers a question about its changes. For Claude Code it is
// a fork of the conversation in plan mode: it has read the chat, can read files and cannot
// write, and the main conversation never sees it. Any other agent runs read-only, like a
// second opinion, and is given the diff, the quoted lines and the recent chat as text.
public enum SideQuestion {
    public struct Request: Sendable {
        public var question: ReviewQuestion
        public var context: QuestionContext
        public var executable: String
        public var searchPath: String
    }

    public struct Reply: Equatable, Sendable {
        public var answer: String
        public var suggestion: String?
        public var forkID: String?
    }

    public static let chatBudget = 12_000
    public static let patchBudget = 60_000

    public static let suggestionInstructions = "If the answer shows that something in the change should be different, end with a line "
        + "that starts `Suggested change:` followed by one or two sentences I could send you as a review comment. "
        + "Otherwise leave that line out."

    // The prompt for a fork that has the conversation already: just the question and its
    // place, since everything else is in the chat it was copied from.
    public static func forkPrompt(_ question: ReviewQuestion, projectNames: [String: String] = [:]) -> String {
        guard let last = question.exchanges.last else { return "" }
        if question.exchanges.count > 1 {
            return "A follow-up on the same question: " + last.question.trimmed + "\n\n" + suggestionInstructions
        }
        var text = "I have a question about your changes, asked from the review screen. Answer it here and do not "
            + "change any files. This is a side copy of our conversation: nothing you write here reaches the main one."
        text += "\n\n" + place(question, projectNames: projectNames)
        text += "\n\nMy question: " + last.question.trimmed
        text += "\n\nAnswer in a few short paragraphs. " + suggestionInstructions
        return text
    }

    // The prompt for a run that has not seen the conversation: the recent chat, the diff
    // and the thread so far are all given as text.
    public static func readOnlyPrompt(_ question: ReviewQuestion, patches: [SecondOpinion.Patch], recentChat: String,
                               repositories: [ReviewRepository] = []) -> String {
        let names = Dictionary(repositories.map { ($0.root, $0.name) }, uniquingKeysWith: { first, _ in first })
        var text = "You are answering a question about changes another coding agent made in this repository. "
            + "Do not change any files or run commands that change anything. You may read files for context."
        if !recentChat.isBlank {
            text += "\n\nThe recent conversation with that agent, most recent last:\n\n" + recentChat
        }
        if !repositories.isEmpty {
            text += "\n\nProject roots (the first is the working directory):\n"
                + repositories.map { "- \($0.name): \($0.root)" }.joined(separator: "\n")
        }
        var budget = patchBudget
        var shown: [String] = []
        for patch in patches where patch.text.utf8.count <= budget {
            budget -= patch.text.utf8.count
            shown.append("File: \(patch.label)\n" + patch.text)
        }
        if !shown.isEmpty { text += "\n\nThe changes:\n\n" + shown.joined(separator: "\n\n") }
        text += "\n\n" + place(question, projectNames: names)
        for exchange in question.exchanges.dropLast() {
            text += "\n\nI asked: " + exchange.question.trimmed
            if let answer = exchange.answer { text += "\nYou answered: " + answer.trimmed }
        }
        text += "\n\nMy question: " + (question.exchanges.last?.question.trimmed ?? "")
        text += "\n\nAnswer in a few short paragraphs. " + suggestionInstructions
        return text
    }

    private static func place(_ question: ReviewQuestion, projectNames: [String: String]) -> String {
        guard !question.isWhole else { return "It is about the change as a whole." }
        var file = question.path
        if projectNames.count > 1 {
            file = (projectNames[question.root] ?? (question.root as NSString).lastPathComponent) + "/" + file
        }
        let lines = question.lastLine.map { "lines \(question.line)–\($0)" } ?? "line \(question.line)"
        var text = "It is about \(file), " + (question.side == .old ? "removed \(lines) of the previous version" : lines) + "."
        if !question.excerpt.isBlank { text += "\n```\n" + question.excerpt + "\n```" }
        return text
    }

    // The answer, with the suggested change taken off its end.
    public static func read(_ text: String) -> (answer: String, suggestion: String?) {
        var lines = text.trimmed.components(separatedBy: "\n")
        var suggestion: String?
        if let index = lines.lastIndex(where: { !$0.isBlank }),
           let match = lines[index].firstMatch(of: /^\s*(?:[-*]\s*)?\**_?Suggested change:?\**_?:?\s*(.+)$/.ignoresCase()) {
            let words = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "\"'*_“” "))
            if !words.isEmpty { suggestion = words }
            lines.removeSubrange(index...)
        }
        return (lines.joined(separator: "\n").trimmed, suggestion)
    }

    // The last turns of the conversation as plain text, newest kept when it runs long.
    public static func recentChat(_ messages: [ChatMessage], budget: Int = chatBudget) -> String {
        var parts: [String] = []
        var used = 0
        for message in messages.reversed() where message.role == .user || message.role == .assistant {
            guard !message.text.isBlank else { continue }
            let part = (message.role == .user ? "User: " : "Agent: ") + message.text.trimmed
            guard used + part.count <= budget else {
                if parts.isEmpty { parts.append(String(part.suffix(budget))) }
                break
            }
            parts.append(part)
            used += part.count
        }
        return parts.reversed().joined(separator: "\n\n")
    }

    // Claude goes on in the fork it made for the question, or forks the session for the
    // first answer, always in plan mode with writes and the shell denied outright.
    public static func claudeArguments(prompt: String, resume: String, fork: Bool, addDirectories: [String] = []) -> [String] {
        ["-p", prompt, "--output-format", "stream-json", "--verbose",
         "--resume", resume] + (fork ? ["--fork-session"] : [])
            + ["--permission-mode", "plan",
               "--allowedTools", "Read,Grep,Glob",
               "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit,Bash",
               "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
            + (addDirectories.isEmpty ? [] : ["--add-dir"] + addDirectories)
    }

    public static func answer(_ request: Request, activity: @escaping @Sendable (String) -> Void) async -> Result<Reply, SecondOpinion.Failure> {
        let question = request.question
        let context = request.context
        let others = context.repositories.map(\.root).filter { $0 != context.directory }
        let resume = question.forkID ?? context.conversationID
        let output: Result<String, SecondOpinion.Failure>
        if context.agent == .claudeCode, let resume {
            activity(question.forkID == nil ? "Opening a side copy of this session" : "Going on in the side copy")
            let names = Dictionary(context.repositories.map { ($0.root, $0.name) }, uniquingKeysWith: { first, _ in first })
            output = await SecondOpinion.run(
                agent: .claudeCode, executable: request.executable, searchPath: request.searchPath,
                directory: context.directory, timeout: .seconds(180), writing: "Writing the answer",
                activity: activity) { _, _ in
                    claudeArguments(prompt: forkPrompt(question, projectNames: names), resume: resume,
                                    fork: question.forkID == nil, addDirectories: others)
                }
        } else {
            activity("Reading the diff and the chat")
            var patches = await SecondOpinion.patches(for: context.repositories.map { (root: $0.root, name: $0.name) })
            if !question.isWhole {
                patches = patches.filter { $0.root == question.root && $0.path == question.path }
            }
            let prompt = readOnlyPrompt(question, patches: patches, recentChat: context.recentChat,
                                        repositories: context.repositories)
            output = await SecondOpinion.run(
                agent: context.agent, executable: request.executable, searchPath: request.searchPath,
                directory: context.directory, timeout: .seconds(180), writing: "Writing the answer",
                activity: activity) { codexServers, copilotServers in
                    SecondOpinion.arguments(for: context.agent, prompt: prompt, addDirectories: others,
                                            codexServers: codexServers, copilotServers: copilotServers)
                }
        }
        switch output {
        case .failure(let failure):
            return .failure(failure)
        case .success(let raw):
            let read = read(SecondOpinion.answer(from: raw, agent: context.agent))
            guard !read.answer.isBlank else {
                return .failure(.init(message: "It finished without an answer."))
            }
            let forkID = context.agent == .claudeCode ? (question.forkID ?? sessionID(in: raw)) : nil
            return .success(Reply(answer: read.answer, suggestion: read.suggestion, forkID: forkID))
        }
    }

    // The id of the conversation a Claude run ended up in, which for a fork is a new one.
    public static func sessionID(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            for case .initialized(let id) in StreamEvent.parse(String(line)) { return id }
        }
        return nil
    }
}
