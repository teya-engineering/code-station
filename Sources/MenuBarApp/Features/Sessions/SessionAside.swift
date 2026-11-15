import Foundation

// A quick question asked with /btw. It is answered on the side and never joins the
// conversation, so it can be asked while a turn is running and costs that turn nothing.
//
// Claude Code answers from a throwaway copy of the conversation: the session is forked
// and the fork is never saved, so it knows everything said so far and leaves no trace.
// The other two cannot fork without writing to the session, so they are handed the
// recent chat as text instead.
enum SessionAside {
    struct Request: Sendable {
        var question: String
        var agent: AgentKind
        var executable: String
        var searchPath: String
        var directories: [String]
        // Claude Code's conversation to copy. Nil before the first turn, and for the
        // agents that read the chat as text.
        var conversationID: String?
        var recentChat: String
        var model: String?
    }

    static let instructions = "Answer briefly, in a few sentences or a short list. Do not change any files and "
        + "do not carry on with the task. Only read a file if the answer needs it."

    static func prompt(for request: Request) -> String {
        var text: String
        if request.conversationID != nil {
            text = "This is a quick side question, asked while you work. Nothing you write here reaches our "
                + "main conversation. Answer from what you already know of it."
        } else {
            text = "You are answering a quick side question from a person working with a coding agent in this project."
            if !request.recentChat.isBlank {
                text += "\n\nThe recent conversation with that agent, most recent last:\n\n" + request.recentChat
            }
        }
        return text + "\n\n" + instructions + "\n\nMy question: " + request.question.trimmed
    }

    // A fork that is never saved, with every tool that can change something denied
    // outright, so nothing on disk is touched by the question.
    static func claudeArguments(prompt: String, resume: String, model: String?,
                                addDirectories: [String] = []) -> [String] {
        ["-p", prompt, "--output-format", "stream-json", "--verbose",
         "--resume", resume, "--fork-session", "--no-session-persistence",
         "--permission-mode", "plan",
         "--allowedTools", "Read,Grep,Glob",
         "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit,Bash",
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
            + (model.map { ["--model", $0] } ?? [])
            + (addDirectories.isEmpty ? [] : ["--add-dir"] + addDirectories)
    }

    static func ask(_ request: Request,
                    activity: @escaping @Sendable (String) -> Void) async -> Result<String, SecondOpinion.Failure> {
        guard let directory = request.directories.first else {
            return .failure(.init(message: "There is no project folder to ask in."))
        }
        let others = Array(request.directories.dropFirst())
        let prompt = prompt(for: request)
        let output = await SecondOpinion.run(
            agent: request.agent, executable: request.executable, searchPath: request.searchPath,
            directory: directory, timeout: .seconds(180), writing: "Writing the answer",
            activity: activity) { codexServers, copilotServers in
                if request.agent == .claudeCode, let resume = request.conversationID {
                    return claudeArguments(prompt: prompt, resume: resume, model: request.model,
                                           addDirectories: others)
                }
                return SecondOpinion.arguments(
                    for: SecondOpinion.Reviewer(agent: request.agent, model: request.model), prompt: prompt,
                    addDirectories: others, codexServers: codexServers, copilotServers: copilotServers)
            }
        switch output {
        case .failure(let failure):
            return .failure(failure)
        case .success(let raw):
            let answer = SecondOpinion.answer(from: raw, agent: request.agent).trimmed
            return answer.isEmpty ? .failure(.init(message: "It finished without an answer.")) : .success(answer)
        }
    }

    // The question typed after /btw, which may be empty, or nil when the text is not the
    // command.
    static func question(in text: String) -> String? {
        let line = text.trimmed
        guard line.lowercased().hasPrefix("/btw") else { return nil }
        let rest = line.dropFirst("/btw".count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return String(rest).trimmed
    }
}

struct Aside: Identifiable, Equatable {
    enum State: Equatable {
        case answering(activity: String)
        case answered(String)
        case failed(String)
    }

    var id = UUID()
    var question: String
    var agent: AgentKind
    var state: State = .answering(activity: "Reading the conversation")

    var isAnswering: Bool {
        if case .answering = state { return true }
        return false
    }
}

// One side question per session, kept only while the app runs. Asking another replaces
// it, the way the answer to the last one is put away once read.
@MainActor
@Observable
final class SessionAsideStore {
    private(set) var asides: [UUID: Aside] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    // How a question is answered; tests swap in their own so nothing is run.
    @ObservationIgnored var answer: @Sendable (SessionAside.Request, @escaping @Sendable (String) -> Void)
        async -> Result<String, SecondOpinion.Failure> = { request, activity in
            await SessionAside.ask(request, activity: activity)
        }

    func aside(_ sessionID: UUID) -> Aside? { asides[sessionID] }

    func ask(_ request: SessionAside.Request, in sessionID: UUID) {
        tasks[sessionID]?.cancel()
        let aside = Aside(question: request.question, agent: request.agent)
        asides[sessionID] = aside
        let answer = answer
        tasks[sessionID] = Task { [weak self] in
            let outcome = await answer(request) { [weak self] text in
                Task { @MainActor in
                    guard self?.asides[sessionID]?.id == aside.id,
                          self?.asides[sessionID]?.isAnswering == true else { return }
                    self?.asides[sessionID]?.state = .answering(activity: text)
                }
            }
            guard !Task.isCancelled else { return }
            self?.finish(aside.id, outcome: outcome, in: sessionID)
        }
    }

    // Called when the run ends; tests call it directly.
    func finish(_ id: UUID, outcome: Result<String, SecondOpinion.Failure>, in sessionID: UUID) {
        guard asides[sessionID]?.id == id else { return }
        tasks[sessionID] = nil
        switch outcome {
        case .success(let text): asides[sessionID]?.state = .answered(text)
        case .failure(let failure): asides[sessionID]?.state = .failed(failure.message)
        }
    }

    // Putting it away also stops a run still answering it, since nobody is waiting.
    func dismiss(_ sessionID: UUID) {
        tasks.removeValue(forKey: sessionID)?.cancel()
        asides[sessionID] = nil
    }
}
