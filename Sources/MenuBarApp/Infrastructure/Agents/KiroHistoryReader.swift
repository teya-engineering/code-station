import Foundation

// Kiro's past sessions, read through its own ACP server the way Codex's and Copilot's
// are read through theirs. Listing asks for the folder's sessions. Importing forks the
// chosen one first, so the original is never touched and the copy is what later turns
// resume, then loads the copy: Kiro replays the whole conversation on load, marked as
// replay, and the replay is folded into the transcript.
enum KiroHistoryReader {
    static func list(folder: String, root: URL,
                     executable: String? = nil) async throws -> [ExternalSessionCandidate] {
        try await run(Exchange(folder: folder, root: root, candidate: nil),
                      executable: executable, timeout: .seconds(20)).candidates
    }

    static func prepare(_ candidate: ExternalSessionCandidate,
                        executable: String? = nil) async throws -> AgentHistoryReader.Reading {
        let root = URL(fileURLWithPath: candidate.origin.configDirectory, isDirectory: true)
        let reading = try await run(Exchange(folder: candidate.cwd, root: root, candidate: candidate),
                                    executable: executable, timeout: .seconds(90))
        guard !reading.messages.isEmpty else {
            throw AgentFailure(message: "The session has no readable conversation.")
        }
        return reading
    }

    private static func run(_ exchange: Exchange, executable: String?,
                            timeout: Duration) async throws -> AgentHistoryReader.Reading {
        guard let path = executable ?? ProcessManager.resolve(AgentKind.kiro.command) else {
            throw AgentFailure(message: "Kiro is not installed.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        // Kiro is told the folder in every request, so a folder that has since moved does
        // not stop the history being read.
        var isFolder: ObjCBool = false
        let folderExists = FileManager.default.fileExists(atPath: exchange.folder, isDirectory: &isFolder)
            && isFolder.boolValue
        _ = try await CommandRunner.run(executable: path, arguments: ["acp", "--agent-engine", "v3"],
                                        currentDirectory: folderExists ? URL(fileURLWithPath: exchange.folder) : nil,
                                        environment: environment, input: exchange.firstMessage,
                                        outputChunkAction: exchange.receive, timeout: timeout,
                                        outputByteLimit: 4096)
        return try exchange.result.get()
    }

    final class Exchange: @unchecked Sendable {
        private enum Step { case initialize, list, fork, load }

        let folder: String
        private let root: URL
        private let candidate: ExternalSessionCandidate?
        private let lock = NSLock()
        private var framer = AgentMessageFramer(format: .jsonLines)
        private var requestID = 0
        private var step = Step.initialize
        private var reading = AgentHistoryReader.Reading()
        private var transcript = ImportedTranscript()
        private let stream = KiroStream(acceptsReplay: true)
        // Kiro sends a prompt as one or more chunks under one message id.
        private var promptID: String?
        private var promptText = ""
        private var promptDate: Date?
        private var failure: AgentFailure?
        private var complete = false

        init(folder: String, root: URL, candidate: ExternalSessionCandidate?) {
            self.folder = folder
            self.root = root
            self.candidate = candidate
        }

        var result: Result<AgentHistoryReader.Reading, AgentFailure> {
            lock.withLock {
                if let failure { return .failure(failure) }
                guard complete else {
                    return .failure(.init(message: "Kiro did not finish reading its history."))
                }
                return .success(reading)
            }
        }

        var firstMessage: Data {
            lock.withLock {
                request(.initialize, "initialize", [
                    "protocolVersion": 1,
                    "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false],
                                           "terminal": false],
                    "clientInfo": ["name": "code-station-history", "version": "1"],
                ])
            }
        }

        func receive(_ chunk: Data) -> CommandRunner.OutputLineAction {
            lock.withLock {
                guard !complete, failure == nil else { return .none }
                framer.append(chunk)
                do {
                    while let body = try framer.next() {
                        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                        else { continue }
                        if object["method"] as? String == "session/update", step == .load {
                            take(object["params"] as? [String: Any] ?? [:])
                            continue
                        }
                        guard object["method"] == nil, (object["id"] as? NSNumber)?.intValue == requestID
                        else { continue }
                        if let error = object["error"] as? [String: Any] {
                            return fail("Kiro: \(error["message"] as? String ?? "History request failed.")")
                        }
                        let action = accept(object["result"] as? [String: Any] ?? [:])
                        if case .none = action { continue }
                        return action
                    }
                } catch { return fail(error.localizedDescription) }
                return .none
            }
        }

        private func accept(_ result: [String: Any]) -> CommandRunner.OutputLineAction {
            switch step {
            case .initialize:
                guard let candidate else {
                    return .write(request(.list, "session/list", ["cwd": folder]))
                }
                return .write(request(.fork, "session/fork", [
                    "sessionId": candidate.sessionID, "cwd": folder, "mcpServers": [[String: Any]](),
                ]))
            case .list:
                guard let rows = result["sessions"] as? [[String: Any]] else {
                    return fail("Kiro returned an unreadable session list.")
                }
                reading.candidates = rows.compactMap(candidate(from:))
            case .fork:
                guard let id = result["sessionId"] as? String, !id.isEmpty,
                      id != candidate?.sessionID else {
                    return fail("Kiro did not create a separate conversation.")
                }
                reading.resumeID = id
                return .write(request(.load, "session/load", [
                    "sessionId": id, "cwd": folder, "mcpServers": [[String: Any]](),
                ]))
            case .load:
                closePrompt()
                reading.messages = transcript.finish()
            }
            complete = true
            return .finishProcess
        }

        // One replayed update: a prompt goes in as the person's message, anything else
        // through the same adapter a live session uses.
        private func take(_ params: [String: Any]) {
            guard let update = params["update"] as? [String: Any] else { return }
            let meta = (update["_meta"] as? [String: Any])?["kiro"] as? [String: Any]
            let date = ClaudeTranscriptImport.date(meta?["timestamp"])
            if update["sessionUpdate"] as? String == "user_message_chunk" {
                let id = meta?["messageId"] as? String
                if id == nil || id != promptID { closePrompt() }
                promptID = id
                promptDate = promptDate ?? date
                promptText += (update["content"] as? [String: Any])?["text"] as? String ?? ""
                return
            }
            closePrompt()
            for event in stream.events(update) { transcript.apply(event, at: date) }
        }

        private func closePrompt() {
            defer {
                promptID = nil
                promptText = ""
                promptDate = nil
            }
            guard !promptText.isBlank else { return }
            transcript.prompt(promptText, at: promptDate)
            // A new prompt is a new turn: the next piece of text opens a block of its own.
            _ = stream.finish()
        }

        // Only the folder's own sessions on this Mac: a cloud session cannot be resumed here.
        private func candidate(from row: [String: Any]) -> ExternalSessionCandidate? {
            let kiro = (row["_meta"] as? [String: Any])?["kiro"] as? [String: Any]
            guard let id = row["sessionId"] as? String, !id.isEmpty,
                  let cwd = row["cwd"] as? String,
                  ClaudeSessionCatalog.standardized(cwd) == folder,
                  (kiro?["source"] as? String ?? "local") == "local" else { return nil }
            let title = (row["title"] as? String).flatMap { $0.isBlank || $0 == "New Session" ? nil : $0 }
            guard let title else { return nil }
            let started = ClaudeTranscriptImport.date(kiro?["createdAt"])
            let updated = ClaudeTranscriptImport.date(row["updatedAt"])
            return ExternalSessionCandidate(
                sessionID: id, agent: .kiro, file: root.appendingPathComponent("sessions"), cwd: cwd,
                title: title, firstPrompt: nil, startedAt: started,
                lastActivity: updated ?? started ?? .distantPast, gitBranch: nil, bytes: 0,
                configDirectory: root)
        }

        private func request(_ step: Step, _ method: String, _ params: [String: Any]) -> Data {
            self.step = step
            requestID += 1
            let message: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": method, "params": params]
            guard let body = try? JSONSerialization.data(withJSONObject: message) else { return Data() }
            return body + Data([0x0A])
        }

        private func fail(_ message: String) -> CommandRunner.OutputLineAction {
            failure = AgentFailure(message: message)
            return .finishProcess
        }
    }
}
