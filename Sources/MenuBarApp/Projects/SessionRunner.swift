import Foundation
import Observation

// Runs the coding agent's CLI for chat sessions. One process per turn, started in the
// project's own folder, with the agent's resume mechanism carrying the conversation
// forward. The reply is streamed into the ProjectStore as it arrives; nothing about a
// conversation is kept here, only the state that dies with the process. The one stretch:
// a Claude Code turn that started a background task is held open until the task is done,
// because the CLI can only wake the agent with the result while its process is still
// alive.
@MainActor
@Observable
final class SessionRunner {
    // Which agent new turns run on. Turns already going finish on the agent they
    // started with.
    var agent = Preferences.agent {
        didSet { Preferences.agent = agent }
    }

    // What every session runs with unless it has picked something of its own. Each agent
    // has its own defaults because their models and access controls do not overlap.
    private var defaultsByAgent: [AgentKind: SessionSettings]

    var defaults: SessionSettings {
        get { defaults(for: agent) }
        set {
            defaultsByAgent[agent] = newValue
            Preferences.setSessionDefaults(newValue, for: agent)
        }
    }

    // The account's usage windows belong to an agent account rather than a session.
    // Claude Code sends them while a turn runs, so they are kept apart from Codex's
    // account usage instead of allowing the last reporting CLI to replace the other.
    private(set) var rateLimits: [AgentKind: [String: RateLimit]] = [:]
    private(set) var rateLimitsUpdatedAt: [AgentKind: Date] = [:]

    private var states: [UUID: SessionState] = [:]
    private var turns: [UUID: Turn] = [:]
    // Everything the agent is waiting on, oldest first. Parallel tool calls can park more
    // than one at a time, and each is answered on its own.
    private var asked: [UUID: [PermissionRequest]] = [:]
    // What has been typed but not run yet, oldest first. Everything goes through here, so
    // a prompt typed mid-turn keeps its place behind the ones before it.
    private var queues: [UUID: [QueuedPrompt]] = [:]
    // What is half-written in the composer and not sent yet. The detail pane is built
    // again from nothing every time another session is picked, so this cannot live there
    // without the words going with it.
    private var drafts: [UUID: Draft] = [:]

    @ObservationIgnored private let paths: [AgentKind: String]

    // How Claude Code says it no longer holds the conversation we asked to resume.
    private static let lostConversation = "No conversation found with session ID"

    init() {
        defaultsByAgent = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, Preferences.sessionDefaults(for: $0))
        })
        var found: [AgentKind: String] = [:]
        for kind in AgentKind.allCases {
            if let path = ProcessManager.resolve(kind.command) { found[kind] = path }
        }
        paths = found
    }

    func defaults(for agent: AgentKind) -> SessionSettings {
        defaultsByAgent[agent] ?? SessionSettings()
    }

    var available: Bool { paths[agent] != nil }

    func state(_ sessionID: UUID) -> SessionState { states[sessionID] ?? .idle }

    // When this session last heard anything at all from the CLI. A turn that is working
    // says something every few seconds, so a long gap here is the one visible difference
    // between a slow turn and one that has stopped moving.
    func lastActivity(_ sessionID: UUID) -> Date? { turns[sessionID]?.lastActivity }

    // What this session is waiting on the person for, if anything.
    func question(_ sessionID: UUID) -> PermissionRequest? { asked[sessionID]?.first }

    // Sends the answer back down the pipe the turn is parked on. An answered question is
    // also written into the transcript: the answers travel inside the tool's own input,
    // where nothing in the conversation would ever show them.
    func answer(_ request: PermissionRequest, with answer: PermissionAnswer,
                sessionID: UUID, store: ProjectStore) {
        guard let turn = turns[sessionID],
              asked[sessionID]?.contains(where: { $0.id == request.id }) == true else { return }
        asked[sessionID]?.removeAll { $0.id == request.id }
        SessionLog.note("answered \(request.toolName) \(request.id) with \(answer.logLabel)",
                        session: sessionID)

        guard let line = request.responseLine(answer), turn.write(line) else {
            states[sessionID] = .failed("Could not send the answer to Claude Code. The turn has been stopped.")
            stop(sessionID, store: store)
            return
        }

        // The turn goes on writing after this, and what it writes has to read as having
        // come after the answer rather than above it.
        if case .answers(let given) = answer, !given.isEmpty,
           let carriesOn = store.recordAnswer(PermissionRequest.transcript(of: given),
                                              in: sessionID, continuing: turn.messageID) {
            turn.messageID = carriesOn
        }
    }

    // A prompt waiting for its turn to start.
    struct QueuedPrompt: Identifiable, Equatable, Sendable {
        let id = UUID()
        let text: String
        let attachments: [Attachment]
    }

    // An unsent composer: what has been typed, and what has been dropped or pasted onto it.
    struct Draft: Equatable {
        var text: String = ""
        var attachments: [Attachment] = []

        var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        }
    }

    func draft(_ sessionID: UUID) -> Draft { drafts[sessionID] ?? Draft() }

    func editDraft(_ sessionID: UUID, _ change: (inout Draft) -> Void) {
        var draft = drafts[sessionID] ?? Draft()
        change(&draft)
        drafts[sessionID] = draft.isEmpty ? nil : draft
    }

    func clearDraft(_ sessionID: UUID) { drafts[sessionID] = nil }

    func queued(_ sessionID: UUID) -> [QueuedPrompt] { queues[sessionID] ?? [] }

    func unqueue(_ id: UUID, sessionID: UUID) { queues[sessionID]?.removeAll { $0.id == id } }

    // Takes a waiting prompt back into the composer so it can be reworked before it runs.
    // A half-written draft is not thrown away: it takes the recalled prompt's place in
    // the queue, so nothing typed is ever lost.
    func recall(_ id: UUID, sessionID: UUID) {
        guard let index = queues[sessionID]?.firstIndex(where: { $0.id == id }),
              let item = queues[sessionID]?[index] else { return }
        queues[sessionID]?.remove(at: index)
        let current = draft(sessionID)
        if !current.isEmpty {
            queues[sessionID]?.insert(QueuedPrompt(text: current.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   attachments: current.attachments), at: index)
        }
        drafts[sessionID] = Draft(text: item.text, attachments: item.attachments)
    }

    // Nothing is ever sent straight to the CLI: a prompt joins the queue and the queue is
    // what runs. Typing during a turn therefore costs nothing, and the ones already waiting
    // keep their order.
    func send(_ prompt: String, attachments: [Attachment] = [], sessionID: UUID, store: ProjectStore) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        queues[sessionID, default: []].append(QueuedPrompt(text: text, attachments: attachments))
        runQueue(sessionID, store: store)
    }

    // Starts the oldest waiting prompt, if the session is free to take it. A prompt that
    // cannot start yet stays at the head of the queue rather than being lost.
    func runQueue(_ sessionID: UUID, store: ProjectStore) {
        // A turn that is only waiting on a background task has a live process with an
        // open pipe, so the next prompt goes straight down it instead of sitting behind
        // a timer that could run for a long while.
        if turns[sessionID]?.waitingOnTasks == true {
            injectQueued(sessionID, store: store)
            return
        }
        guard !state(sessionID).isBusy,
              let next = queues[sessionID]?.first,
              let session = store.session(sessionID) else { return }

        // Two agents in one folder would edit the same files underneath each other, so
        // sessions that share a directory cannot run at once. Worktree sessions each
        // have their own directory, so they run in parallel freely.
        if let other = busySession(sharingDirectoryWith: session, store: store) {
            states[sessionID] = .failed(
                "\"\(other.title)\" is already running in this folder. Sessions that share a directory cannot run at the same time - stop that one first, or use a worktree session to run in parallel.")
            return
        }

        queues[sessionID]?.removeFirst()
        var message = ChatMessage(role: .user, text: next.text)
        if !next.attachments.isEmpty { message.attachments = next.attachments.map(\.url.path) }
        store.append(message, to: sessionID)
        launch(Self.prompt(next.text, with: next.attachments), attachments: next.attachments,
               sessionID: sessionID, store: store, canRetryWithoutResume: true)
    }

    // Everything the CLI is run with for one turn. The session's own choices win, the app
    // defaults fill the gaps, and anything neither has chosen is left off entirely rather
    // than sent as a guess, so the agent's own configuration keeps deciding it. A model
    // or effort picked while the other agent was active would only be refused, so it
    // counts as unchosen here.
    nonisolated static func arguments(agent: AgentKind = .claudeCode,
                                      settings: SessionSettings, defaults: SessionSettings,
                                      addDirectories: [String] = [], writableRoots: [String] = [],
                                      resume: String? = nil) -> [String] {
        let model = ModelChoice.valid(settings.model ?? defaults.model, for: agent)
        let effort = EffortChoice.valid(settings.effort ?? defaults.effort, for: agent)
        let codexSandbox = CodexSandboxMode.resolved(settings.codexSandboxMode
            ?? defaults.codexSandboxMode)

        switch agent {
        case .claudeCode:
            // The app is what puts the questions on screen, so it always says which ones
            // it wants rather than letting the CLI's own config decide.
            let permissionMode = settings.permissionMode ?? defaults.permissionMode ?? "acceptEdits"

            // Streaming input is what makes the CLI able to ask anything back: with
            // "--permission-prompt-tool stdio" it puts permission prompts and the agent's
            // own questions on stdout as control requests and waits for an answer on
            // stdin. Without it a prompt is auto-denied and the turn carries on half-done.
            var arguments = ["-p", "--output-format", "stream-json", "--input-format", "stream-json",
                             "--permission-prompt-tool", "stdio", "--verbose",
                             "--permission-mode", permissionMode]
            if let model { arguments += ["--model", model] }
            if let effort { arguments += ["--effort", effort] }
            if !addDirectories.isEmpty { arguments += ["--add-dir"] + addDirectories }
            if let resume, !resume.isEmpty { arguments += ["--resume", resume] }
            return arguments

        case .codex:
            // Codex has no streaming input for permission questions. The sandbox goes
            // over as a config override because the resume subcommand has no --sandbox
            // option. Its full-access flag works for both initial and resumed turns;
            // the approve-for-me flag needs config overrides when resuming.
            var arguments = ["exec"]
            if let resume, !resume.isEmpty { arguments += ["resume", resume] }
            arguments += ["--json", "--skip-git-repo-check"]
            switch codexSandbox {
            case .workspaceWrite, .approveForMe:
                arguments += ["-c", "sandbox_mode=\"workspace-write\""]
                // A worktree session keeps its git metadata in the main checkout's .git
                // directory, outside the sandbox. Without write access there git cannot
                // even stage a file, so that directory goes in as an extra writable root.
                if !writableRoots.isEmpty {
                    let list = writableRoots
                        .map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
                        .joined(separator: ",")
                    arguments += ["-c", "sandbox_workspace_write.writable_roots=[\(list)]"]
                }
                if codexSandbox == .approveForMe {
                    if resume == nil || resume?.isEmpty == true {
                        arguments.append("--approve-for-me")
                    } else {
                        arguments += ["-c", "approval_policy=\"on-failure\"",
                                      "-c", "approvals_reviewer=\"auto_review\""]
                    }
                }
            case .fullAccess:
                arguments.append("--dangerously-bypass-approvals-and-sandbox")
            }
            if let model { arguments += ["--model", model] }
            if let effort { arguments += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            // The prompt goes over stdin, which "-" asks for; passed as an argument, a
            // prompt starting with a dash would be read as a flag.
            arguments.append("-")
            return arguments
        }
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
        let root = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path
        var directories: [String] = []
        for attachment in attachments {
            let parent = attachment.url.deletingLastPathComponent()
                .resolvingSymlinksInPath().path
            guard parent != root, !parent.hasPrefix(root + "/"), !directories.contains(parent) else {
                continue
            }
            directories.append(parent)
        }
        return directories
    }

    private func busySession(sharingDirectoryWith session: ChatSession,
                             store: ProjectStore) -> ChatSession? {
        guard let directory = store.workingDirectory(for: session) else { return nil }
        return turns.keys
            .filter { $0 != session.id }
            .compactMap { store.session($0) }
            .first { store.workingDirectory(for: $0) == directory }
    }

    // Leaves whatever has streamed in so far in place.
    func stop(_ sessionID: UUID, store: ProjectStore) {
        guard let messageID = turns[sessionID]?.messageID, stopTurn(sessionID) else { return }
        // A turn stopped before it wrote anything leaves a blank bubble behind - and one
        // stopped just after a question was answered leaves the half of the reply that
        // had not begun.
        if store.transcript(of: sessionID).first(where: { $0.id == messageID })?.isEmpty ?? false {
            store.removeMessage(messageID, from: sessionID)
        }
        store.release(sessionID, for: .running)
    }

    // Only for the app going away. The transcripts are not given back because there is
    // nothing left to give them back to; the store writes out what is still pending as
    // part of the same shutdown.
    func stopAll() {
        for sessionID in Array(turns.keys) { stopTurn(sessionID) }
    }

    @discardableResult
    private func stopTurn(_ sessionID: UUID) -> Bool {
        guard let turn = turns[sessionID] else { return false }
        SessionLog.note("stopped by hand", session: sessionID)
        turns[sessionID] = nil
        asked[sessionID] = nil
        states[sessionID] = .idle
        turn.process.terminationHandler = nil
        cleanUp(turn)
        if turn.process.isRunning { turn.process.terminate() }
        return true
    }

    // MARK: - Running one turn

    private func launch(_ prompt: String, attachments: [Attachment], sessionID: UUID,
                        store: ProjectStore, canRetryWithoutResume: Bool) {
        // Read the session again rather than passing it in: a retry runs after the stored
        // claudeSessionID has been cleared, and must not try to resume anything.
        guard let session = store.session(sessionID) else { return }
        guard let project = store.project(session.projectID) else {
            states[sessionID] = .failed("This session's project is no longer in the app.")
            return
        }
        let agent = agent
        guard let agentPath = paths[agent] else {
            states[sessionID] = .failed(
                "Could not find \"\(agent.command)\" on PATH. Install the \(agent.title) CLI (\(agent.installHint)) and reopen the app.")
            return
        }
        let workingDirectory = session.worktreePath ?? project.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            states[sessionID] = .failed("\(workingDirectory) no longer exists.")
            return
        }

        // A turn writes into the conversation for as long as it runs, whether or not
        // anyone has it open, so the transcript is held until this turn is done with it.
        store.hold(sessionID, for: .running)

        // The whole turn, tool calls included, lands in this one message.
        let reply = ChatMessage(role: .assistant)
        store.append(reply, to: sessionID)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let resume = session.agentSessionID(for: agent).flatMap { $0.isEmpty ? nil : $0 }
        process.arguments = Self.arguments(
            agent: agent,
            settings: session.settings ?? SessionSettings(),
            defaults: defaults(for: agent),
            // A pasted screenshot or a file picked from anywhere on disk sits outside the
            // folder the agent runs in, and reading outside it needs saying so up front.
            addDirectories: Self.directoriesOutside(workingDirectory, for: attachments),
            // The git metadata of a worktree lives under the project's own .git folder,
            // and committing there has to be allowed for the session to do git work.
            writableRoots: session.worktreePath != nil ? [project.path + "/.git"] : [],
            resume: resume)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessManager.searchPath
        process.environment = env

        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors

        // The prompt goes in as a JSON line on stdin rather than as an argument, and the
        // pipe stays open for the rest of the turn: it is the way back for the answers to
        // whatever the agent asks. Prompts are not read as flags there either, which an
        // argument starting with a dash would be.
        let input = Pipe()
        process.standardInput = input

        let turn = Turn(process: process, agent: agent, messageID: reply.id, input: input,
                        prompt: prompt, attachments: attachments, resumed: resume != nil,
                        canRetryWithoutResume: canRetryWithoutResume)
        let token = turn.token
        let runner = self
        let buffer = LineBuffer()

        let parseLine: @Sendable (String) -> [StreamEvent] = { line in
            SessionLog.note("< \(line)", session: sessionID)
            return agent == .codex ? StreamEvent.parseCodex(line)
                                   : StreamEvent.parse(line, projectPath: workingDirectory)
        }

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                SessionLog.note("stdout closed", session: sessionID)
                let tail = buffer.flush().flatMap(parseLine)
                Task { @MainActor in
                    runner.apply(tail, sessionID: sessionID, token: token, store: store)
                    runner.pipeClosed(sessionID, token: token, stdout: true, store: store)
                }
                return
            }
            let events = buffer.lines(from: data).flatMap(parseLine)
            // Even a line that means nothing to the app proves the CLI is alive, so the
            // clock moves on the read rather than on the events it turned into.
            Task { @MainActor in
                runner.apply(events, sessionID: sessionID, token: token, store: store)
            }
        }

        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                SessionLog.note("stderr closed", session: sessionID)
                Task { @MainActor in
                    runner.pipeClosed(sessionID, token: token, stdout: false, store: store)
                }
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            SessionLog.note("! \(chunk.trimmingCharacters(in: .whitespacesAndNewlines))",
                            session: sessionID)
            Task { @MainActor in runner.appendStderr(sessionID, token: token, chunk) }
        }

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            SessionLog.note("exited with status \(status)", session: sessionID)
            Task { @MainActor in
                runner.processExited(sessionID, token: token, status: status, store: store)
            }
        }

        do {
            turns[sessionID] = turn
            states[sessionID] = .starting
            SessionLog.note("starting \(agent.command) \(process.arguments?.joined(separator: " ") ?? "") in \(workingDirectory)",
                            session: sessionID)
            try process.run()
            switch agent {
            case .claudeCode:
                guard let line = Self.userMessageLine(prompt), turn.write(line) else {
                    throw Failure("the prompt could not be handed over")
                }
            case .codex:
                // Codex reads the prompt off stdin until the pipe closes, and nothing
                // ever goes back down it: there are no questions to answer mid-turn.
                guard turn.write(Data((prompt + "\n").utf8)) else {
                    throw Failure("the prompt could not be handed over")
                }
                turn.closeInput()
            }
        } catch {
            turns[sessionID] = nil
            process.terminationHandler = nil
            cleanUp(turn)
            store.removeMessage(reply.id, from: sessionID)
            store.release(sessionID, for: .running)
            SessionLog.note("could not start: \(error.localizedDescription)", session: sessionID)
            states[sessionID] = .failed("Could not start \(agent.title): \(error.localizedDescription)")
        }
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
        guard let turn = turns[sessionID], turn.token == token else { return nil }
        return turn
    }

    private func apply(_ events: [StreamEvent], sessionID: UUID, token: UUID, store: ProjectStore) {
        guard let turn = turn(sessionID, token) else { return }
        turn.lastActivity = Date()
        for event in events {
            switch event {
            case .initialized(let claudeSessionID):
                // Saved right away, before the turn can fail: this id is what resuming
                // needs, so losing it would strand the conversation.
                store.setAgentSessionID(claudeSessionID, agent: turn.agent, for: sessionID)

            case .text(let text):
                states[sessionID] = .streaming
                freshReply(turn, sessionID: sessionID, store: store)
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    // Each event carries a complete block, and blocks are split around
                    // tool calls, so they need a gap between them.
                    if !message.text.isEmpty { message.text += "\n\n" }
                    message.text += text
                }

            case .agentText(let parentID, let text):
                states[sessionID] = .streaming
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    guard let i = message.tools.firstIndex(where: { $0.id == parentID }) else { return }
                    message.tools[i].status = Self.statusLine(text)
                }

            case .toolUse(let tool):
                states[sessionID] = .streaming
                freshReply(turn, sessionID: sessionID, store: store)
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    // Stamped here rather than in the parser: only the message being
                    // built knows how much has been said so far, and that is what puts
                    // the call back in place when the turn is drawn.
                    var placed = tool
                    placed.textOffset = message.text.count
                    message.tools.append(placed)
                }

            case .toolResult(let id, let output, let isError):
                var command = ""
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    guard let i = message.tools.firstIndex(where: { $0.id == id }) else { return }
                    message.tools[i].result = output
                    message.tools[i].isError = isError
                    // An agent that has reported back is no longer partway through
                    // anything, and its last words are in the result.
                    message.tools[i].status = nil
                    command = message.tools[i].input
                }
                // The only moment a pull request announces itself is in the output of the
                // command that opened it.
                if let opened = PullRequestScanner.opened(command: command, output: output) {
                    store.notePullRequest(opened, for: sessionID)
                }

            case .permissionRequest(let request):
                states[sessionID] = .streaming
                asked[sessionID, default: []].append(request)

            case .permissionWithdrawn(let id):
                asked[sessionID]?.removeAll { $0.id == id }

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
                rateLimitsUpdatedAt[turn.agent] = Date()

            case .usage(let totals):
                // A process reports running totals for its whole run, and a turn held
                // open for background tasks sees several of them, so only what has grown
                // since the last one is new spend.
                store.recordUsage(Self.grown(totals, since: turn.recordedUsage),
                                  from: turn.agent, for: sessionID)
                turn.recordedUsage = totals

            case .context(let tokens):
                store.recordContext(tokens, from: turn.agent, for: sessionID)

            case .backgroundTasks(let ids):
                turn.pendingTasks = Set(ids)

            case .finished(let isError, let message):
                if isError { turn.failure = message ?? "Claude Code reported an error." }
                // A result with background tasks still running is not the end of the
                // turn: the CLI runs a follow-up turn when a task finishes, but only
                // while its process is alive, so the input pipe is held open until the
                // last task is done and the turn after it has answered.
                if !isError, !turn.pendingTasks.isEmpty {
                    SessionLog.note("holding turn open for background tasks \(turn.pendingTasks.sorted())",
                                    session: sessionID)
                    turn.waitingOnTasks = true
                    turn.needsFreshReply = true
                    states[sessionID] = .waiting
                    // A prompt typed while the agent was working can go down the open
                    // pipe now instead of sitting behind the task.
                    injectQueued(sessionID, store: store)
                    continue
                }
                // Nothing more is coming, and the CLI keeps its input stream open waiting
                // for another message, so this is where the turn is let go.
                turn.closeInput()
            }
        }
    }

    // Opens a new reply bubble for a turn the CLI started on its own - the one it runs
    // when a background task finishes. Without this the follow-up would keep writing
    // into the bubble of the turn that already answered.
    private func freshReply(_ turn: Turn, sessionID: UUID, store: ProjectStore) {
        guard turn.needsFreshReply else { return }
        turn.needsFreshReply = false
        turn.waitingOnTasks = false
        // The bubble being left behind is normally full, but a turn that said nothing
        // would leave an empty one sitting in the transcript for good.
        if store.transcript(of: sessionID).first(where: { $0.id == turn.messageID })?.isEmpty ?? false {
            store.removeMessage(turn.messageID, from: sessionID)
        }
        let reply = ChatMessage(role: .assistant)
        store.append(reply, to: sessionID)
        turn.messageID = reply.id
    }

    // Hands the next queued prompt to the process a waiting turn is holding open. The
    // CLI accepts further user messages for as long as the pipe is open, so the person
    // is not stuck behind a task that could run for many minutes. One prompt at a time:
    // the ones behind it go when this one's result comes back.
    private func injectQueued(_ sessionID: UUID, store: ProjectStore) {
        guard let turn = turns[sessionID], turn.waitingOnTasks,
              let next = queues[sessionID]?.first else { return }
        let prompt = Self.prompt(next.text, with: next.attachments)
        // A failed write means the pipe is gone; the prompt stays queued and starts a
        // fresh process once this turn winds down.
        guard let line = Self.userMessageLine(prompt), turn.write(line) else { return }
        queues[sessionID]?.removeFirst()
        SessionLog.note("prompt sent into waiting turn", session: sessionID)

        var message = ChatMessage(role: .user, text: next.text)
        if !next.attachments.isEmpty { message.attachments = next.attachments.map(\.url.path) }
        store.append(message, to: sessionID)
        let reply = ChatMessage(role: .assistant)
        store.append(reply, to: sessionID)
        turn.messageID = reply.id
        turn.needsFreshReply = false
        turn.waitingOnTasks = false
        states[sessionID] = .streaming
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
        turn.exitStatus = status
        finishIfDone(sessionID, store: store)
    }

    // The exit status and the last bytes of output arrive on different queues, so a turn
    // only ends once both pipes are at EOF and the process is gone. Otherwise the tail of
    // a reply, or the stderr that explains a failure, can be dropped. Dropping the turn
    // before doing anything else means the events the CLI still writes after its result
    // cannot end the same turn twice.
    private func finishIfDone(_ sessionID: UUID, store: ProjectStore) {
        guard let turn = turns[sessionID], !turn.stdoutOpen, !turn.stderrOpen,
              let status = turn.exitStatus else { return }
        turns[sessionID] = nil
        // The process that parked them is gone, so nothing is listening for an answer.
        asked[sessionID] = nil
        cleanUp(turn)

        // A turn that produced nothing at all would otherwise leave a blank assistant
        // bubble sitting under the failure.
        if store.transcript(of: sessionID).first(where: { $0.id == turn.messageID })?.isEmpty ?? false {
            store.removeMessage(turn.messageID, from: sessionID)
        }

        // Warnings on stderr are common and harmless, so only a reported error or a bad
        // exit code counts as a failed turn.
        guard turn.failure != nil || status != 0 else {
            SessionLog.note("turn finished", session: sessionID)
            states[sessionID] = .idle
            // Given back before the queue runs: the next turn takes the transcript for
            // itself, and releasing after it started would take that hold away.
            store.release(sessionID, for: .running)
            // Only a turn that ended on its own pulls the next one in. After a failure or a
            // stop the queue waits to be sent by hand, so the reason it stopped stays on
            // screen long enough to read.
            runQueue(sessionID, store: store)
            // A queued prompt starting straight away means the session has not stopped
            // working, and there is nothing to come back to yet.
            if !state(sessionID).isBusy { store.noteTurnEnded(for: sessionID) }
            return
        }
        var parts: [String] = []
        if let failure = turn.failure { parts.append(failure) }
        let stderr = turn.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { parts.append(stderr) }
        if parts.isEmpty { parts.append("\(turn.agent.title) exited with code \(status).") }
        let message = parts.joined(separator: "\n\n")
        SessionLog.note("turn failed: \(message)", session: sessionID)

        // Claude Code no longer holds the conversation we asked it to resume, usually
        // because its own history was pruned. The prompt is still good, so run it once
        // more as a new conversation instead of leaving the session stuck for good.
        if turn.agent == .claudeCode, turn.canRetryWithoutResume, turn.resumed,
           message.contains(Self.lostConversation) {
            store.clearAgentSessionID(agent: .claudeCode, for: sessionID)
            store.append(
                ChatMessage(role: .system,
                            text: "The earlier conversation could not be resumed, so this reply starts a fresh one without the previous context."),
                to: sessionID)
            launch(turn.prompt, attachments: turn.attachments, sessionID: sessionID,
                   store: store, canRetryWithoutResume: false)
            return
        }

        states[sessionID] = .failed(message)
        store.release(sessionID, for: .running)
        store.noteTurnEnded(for: sessionID)
    }

    private func cleanUp(_ turn: Turn) {
        (turn.process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (turn.process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        turn.closeInput()
    }

    // One live turn. Only ever touched on the main actor.
    private final class Turn {
        let token = UUID()
        let process: Process
        // The agent this turn started on. The app-wide choice can move mid-turn, and
        // the stream already in flight still has to be read in its own dialect.
        let agent: AgentKind
        // Where the reply is being written. A question answered mid-turn closes the
        // message the turn opened with and moves this on to the one after the answer.
        var messageID: UUID
        let input: Pipe
        private var inputOpen = true
        let prompt: String
        let attachments: [Attachment]
        let resumed: Bool
        let canRetryWithoutResume: Bool
        var stderr = ""
        var failure: String?
        var stdoutOpen = true
        var stderrOpen = true
        var exitStatus: Int32?
        // The background tasks the CLI says are still running, by id.
        var pendingTasks: Set<String> = []
        // True from a result that left tasks running until the CLI moves again or a
        // prompt is sent into the open pipe. This is what holds the input open.
        var waitingOnTasks = false
        // True when whatever streams next belongs in a reply bubble of its own, because
        // the last one was already closed off by a result.
        var needsFreshReply = false
        // The totals from the last usage report, so the next one is recorded as a delta.
        var recordedUsage: TurnUsage?
        // Moved on every read off the CLI's stdout, so it measures silence rather than
        // progress: a turn deep in a long build still counts as alive.
        var lastActivity = Date()

        // One line down the pipe the CLI is reading. False when it could not be sent: the
        // process is gone, or its end of the pipe is shut.
        func write(_ line: Data) -> Bool {
            guard inputOpen, process.isRunning else { return false }
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
            try? input.fileHandleForWriting.close()
        }

        init(process: Process, agent: AgentKind, messageID: UUID, input: Pipe, prompt: String,
             attachments: [Attachment], resumed: Bool, canRetryWithoutResume: Bool) {
            self.process = process
            self.agent = agent
            self.messageID = messageID
            self.input = input
            self.prompt = prompt
            self.attachments = attachments
            self.resumed = resumed
            self.canRetryWithoutResume = canRetryWithoutResume
        }
    }
}
