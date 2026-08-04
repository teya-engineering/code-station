import Foundation
import Observation

// Runs the Claude Code CLI for chat sessions. One process per turn, started in the
// project's own folder, with `--resume` carrying the conversation forward. The reply is
// streamed into the ProjectStore as it arrives; nothing about a conversation is kept
// here, only the state that dies with the process.
@MainActor
@Observable
final class SessionRunner {
    var permissionMode = "acceptEdits"
    // nil leaves the choice to Claude Code's own default.
    var model: String?

    private var states: [UUID: SessionState] = [:]
    private var turns: [UUID: Turn] = [:]

    @ObservationIgnored private let claudePath: String?

    // How Claude Code says it no longer holds the conversation we asked to resume.
    private static let lostConversation = "No conversation found with session ID"

    init() {
        claudePath = ProcessManager.resolve("claude")
    }

    var available: Bool { claudePath != nil }

    func state(_ sessionID: UUID) -> SessionState { states[sessionID] ?? .idle }

    func send(_ prompt: String, sessionID: UUID, store: ProjectStore) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state(sessionID).isBusy else { return }
        guard let session = store.session(sessionID) else { return }

        // Two agents in one folder would edit the same files underneath each other, so
        // sessions that share a directory cannot run at once. Worktree sessions each
        // have their own directory, so they run in parallel freely.
        if let other = busySession(sharingDirectoryWith: session, store: store) {
            states[sessionID] = .failed(
                "\"\(other.title)\" is already running in this folder. Sessions that share a directory cannot run at the same time - stop that one first, or use a worktree session to run in parallel.")
            return
        }

        store.append(ChatMessage(role: .user, text: text), to: sessionID)
        launch(text, sessionID: sessionID, store: store, canRetryWithoutResume: true)
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
    func stop(_ sessionID: UUID) {
        guard let turn = turns[sessionID] else { return }
        turns[sessionID] = nil
        states[sessionID] = .idle
        turn.process.terminationHandler = nil
        cleanUp(turn)
        if turn.process.isRunning { turn.process.terminate() }
    }

    func stopAll() {
        for sessionID in Array(turns.keys) { stop(sessionID) }
    }

    // MARK: - Running one turn

    private func launch(_ prompt: String, sessionID: UUID, store: ProjectStore,
                        canRetryWithoutResume: Bool) {
        // Read the session again rather than passing it in: a retry runs after the stored
        // claudeSessionID has been cleared, and must not try to resume anything.
        guard let session = store.session(sessionID) else { return }
        guard let project = store.project(session.projectID) else {
            states[sessionID] = .failed("This session's project is no longer in the app.")
            return
        }
        guard let claudePath else {
            states[sessionID] = .failed(
                "Could not find \"claude\" on PATH. Install the Claude Code CLI (npm install -g @anthropic-ai/claude-code) and reopen the app.")
            return
        }
        let workingDirectory = session.worktreePath ?? project.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            states[sessionID] = .failed("\(workingDirectory) no longer exists.")
            return
        }

        // The whole turn, tool calls included, lands in this one message.
        let reply = ChatMessage(role: .assistant)
        store.append(reply, to: sessionID)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var arguments = ["-p", "--output-format", "stream-json", "--verbose",
                         "--permission-mode", permissionMode]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        let resume = session.claudeSessionID.flatMap { $0.isEmpty ? nil : $0 }
        if let resume { arguments += ["--resume", resume] }
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessManager.searchPath
        process.environment = env

        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors

        // The prompt goes in through a file rather than an argument or a pipe: as an
        // argument a prompt starting with a dash would be read as a flag, and a pipe the
        // CLI never drains (a rejected --resume exits straight away) risks a broken-pipe
        // signal on the write.
        let promptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-prompt-\(UUID().uuidString).txt")
        do {
            try Data(prompt.utf8).write(to: promptFile, options: .atomic)
            process.standardInput = try FileHandle(forReadingFrom: promptFile)
        } catch {
            try? FileManager.default.removeItem(at: promptFile)
            store.removeMessage(reply.id, from: sessionID)
            states[sessionID] = .failed("Could not hand the prompt to Claude Code: \(error.localizedDescription)")
            return
        }

        let turn = Turn(process: process, messageID: reply.id, promptFile: promptFile,
                        prompt: prompt, resumed: resume != nil,
                        canRetryWithoutResume: canRetryWithoutResume)
        let token = turn.token
        let runner = self
        let buffer = LineBuffer()

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                let tail = buffer.flush().flatMap(StreamEvent.parse)
                Task { @MainActor in
                    runner.apply(tail, sessionID: sessionID, token: token, store: store)
                    runner.pipeClosed(sessionID, token: token, stdout: true, store: store)
                }
                return
            }
            let events = buffer.lines(from: data).flatMap(StreamEvent.parse)
            guard !events.isEmpty else { return }
            Task { @MainActor in
                runner.apply(events, sessionID: sessionID, token: token, store: store)
            }
        }

        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Task { @MainActor in
                    runner.pipeClosed(sessionID, token: token, stdout: false, store: store)
                }
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in runner.appendStderr(sessionID, token: token, chunk) }
        }

        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                runner.processExited(sessionID, token: token, status: status, store: store)
            }
        }

        do {
            turns[sessionID] = turn
            states[sessionID] = .starting
            try process.run()
            // The child has its own copy of the prompt file now.
            try? (process.standardInput as? FileHandle)?.close()
        } catch {
            turns[sessionID] = nil
            process.terminationHandler = nil
            cleanUp(turn)
            store.removeMessage(reply.id, from: sessionID)
            states[sessionID] = .failed("Could not start Claude Code: \(error.localizedDescription)")
        }
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
        for event in events {
            switch event {
            case .initialized(let claudeSessionID):
                // Saved right away, before the turn can fail: this id is what --resume
                // needs, so losing it would strand the conversation.
                store.setClaudeSessionID(claudeSessionID, for: sessionID)

            case .text(let text):
                states[sessionID] = .streaming
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    // Each event carries a complete block, and blocks are split around
                    // tool calls, so they need a gap between them.
                    if !message.text.isEmpty { message.text += "\n\n" }
                    message.text += text
                }

            case .toolUse(let tool):
                states[sessionID] = .streaming
                store.updateMessage(turn.messageID, in: sessionID) { $0.tools.append(tool) }

            case .toolResult(let id, let output, let isError):
                store.updateMessage(turn.messageID, in: sessionID) { message in
                    guard let i = message.tools.firstIndex(where: { $0.id == id }) else { return }
                    message.tools[i].result = output
                    message.tools[i].isError = isError
                }

            case .finished(let isError, let message):
                guard isError else { continue }
                turn.failure = message ?? "Claude Code reported an error."
            }
        }
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
        cleanUp(turn)

        // A turn that produced nothing at all would otherwise leave a blank assistant
        // bubble sitting under the failure.
        if store.session(sessionID)?.messages.first(where: { $0.id == turn.messageID })?.isEmpty ?? false {
            store.removeMessage(turn.messageID, from: sessionID)
        }

        // Warnings on stderr are common and harmless, so only a reported error or a bad
        // exit code counts as a failed turn.
        guard turn.failure != nil || status != 0 else {
            states[sessionID] = .idle
            return
        }
        var parts: [String] = []
        if let failure = turn.failure { parts.append(failure) }
        let stderr = turn.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { parts.append(stderr) }
        if parts.isEmpty { parts.append("Claude Code exited with code \(status).") }
        let message = parts.joined(separator: "\n\n")

        // Claude Code no longer holds the conversation we asked it to resume, usually
        // because its own history was pruned. The prompt is still good, so run it once
        // more as a new conversation instead of leaving the session stuck for good.
        if turn.canRetryWithoutResume, turn.resumed, message.contains(Self.lostConversation) {
            store.clearClaudeSessionID(for: sessionID)
            store.append(
                ChatMessage(role: .system,
                            text: "The earlier conversation could not be resumed, so this reply starts a fresh one without the previous context."),
                to: sessionID)
            launch(turn.prompt, sessionID: sessionID, store: store, canRetryWithoutResume: false)
            return
        }

        states[sessionID] = .failed(message)
    }

    private func cleanUp(_ turn: Turn) {
        (turn.process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (turn.process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: turn.promptFile)
    }

    // One live turn. Only ever touched on the main actor.
    private final class Turn {
        let token = UUID()
        let process: Process
        let messageID: UUID
        let promptFile: URL
        let prompt: String
        let resumed: Bool
        let canRetryWithoutResume: Bool
        var stderr = ""
        var failure: String?
        var stdoutOpen = true
        var stderrOpen = true
        var exitStatus: Int32?

        init(process: Process, messageID: UUID, promptFile: URL, prompt: String,
             resumed: Bool, canRetryWithoutResume: Bool) {
            self.process = process
            self.messageID = messageID
            self.promptFile = promptFile
            self.prompt = prompt
            self.resumed = resumed
            self.canRetryWithoutResume = canRetryWithoutResume
        }
    }
}
