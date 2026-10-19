import Foundation

public enum AgentHistoryReader {
    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Reading: Sendable {
        public var candidates: [ExternalSessionCandidate] = []
        public var messages: [ChatMessage] = []
        public var resumeID: String?
    }

    public static func list(agent: AgentKind, folder: String, root: URL,
                     executable: String? = nil) async throws -> [ExternalSessionCandidate] {
        try await run(Exchange(agent: agent, folder: folder, root: root), executable: executable,
                      timeout: .seconds(15)).candidates
    }

    public static func prepare(_ candidate: ExternalSessionCandidate,
                        executable: String? = nil) async throws -> Reading {
        let root = URL(fileURLWithPath: candidate.origin.configDirectory, isDirectory: true)
        var reading = try await run(Exchange(agent: candidate.agent, folder: candidate.cwd,
                                             root: root, candidate: candidate), executable: executable)
        if candidate.agent == .copilot, let id = reading.resumeID {
            let file = root.appendingPathComponent("session-state/\(id)/events.jsonl")
            reading.messages = try await Task.detached(priority: .userInitiated) {
                try CopilotTranscriptImport.messages(from: file)
            }.value
        }
        guard !reading.messages.isEmpty else {
            throw Failure(message: "The session has no readable conversation.")
        }
        return reading
    }

    private static func run(_ exchange: Exchange, executable: String?, timeout: Duration = .seconds(60)) async throws -> Reading {
        guard let path = executable ?? ExecutableSearch.resolve(exchange.agent.command) else {
            throw Failure(message: "\(exchange.agent.title) is not installed.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ExecutableSearch.searchPath
        environment[exchange.agent.historyEnvironmentVariable] = exchange.root.path
        let arguments = exchange.agent == .codex ? ["app-server"]
            : ["--headless", "--stdio", "--no-auto-update", "--log-level", "none"]
        _ = try await CommandRunner.run(executable: path, arguments: arguments,
                                        environment: environment, input: exchange.firstMessage,
                                        outputChunkAction: exchange.receive, timeout: timeout,
                                        outputByteLimit: 4096)
        return try exchange.result.get()
    }

    // Pages are converted as they arrive. Only one page of the agent's wire format is
    // retained alongside the app messages, and no session is resumed just to read it.
    public final class Exchange: @unchecked Sendable {
        public let agent: AgentKind
        public let root: URL
        private let folder: String
        private let candidate: ExternalSessionCandidate?
        private let lock = NSLock()
        private var framer: AgentMessageFramer
        private var requestID = 1
        private var method = ""
        private var reading = Reading()
        private var transcript = ImportedTranscript()
        private var failure: Failure?
        private var complete = false
        private var cursors: Set<String> = []
        private var usedLegacyRead = false

        public init(agent: AgentKind, folder: String, root: URL, candidate: ExternalSessionCandidate? = nil) {
            self.agent = agent
            self.folder = folder
            self.root = root
            self.candidate = candidate
            framer = AgentMessageFramer(format: agent == .codex ? .jsonLines : .contentLength)
        }

        public var result: Result<Reading, Failure> {
            lock.withLock {
                if let failure { return .failure(failure) }
                guard complete else { return .failure(Failure(message: "\(agent.title) did not finish reading its history.")) }
                return .success(reading)
            }
        }

        public var firstMessage: Data {
            lock.withLock {
                if agent == .codex {
                    return request("initialize", ["clientInfo": ["name": "code_station_history", "version": "1"]])
                }
                return begin()
            }
        }

        public func receive(_ chunk: Data) -> CommandRunner.OutputLineAction {
            lock.withLock {
                guard !complete, failure == nil else { return .none }
                framer.append(chunk)
                do {
                    while let body = try framer.next() {
                        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                              object["id"] as? Int == requestID else { continue }
                        if let error = object["error"] as? [String: Any] {
                            if method == "thread/turns/list", error["code"] as? Int == -32601,
                               !usedLegacyRead, let id = reading.resumeID {
                                usedLegacyRead = true
                                return .write(next("thread/read", ["threadId": id, "includeTurns": true]))
                            }
                            return fail("\(agent.title): \(error["message"] as? String ?? "History request failed.")")
                        }
                        guard let result = object["result"] as? [String: Any] else {
                            return fail("\(agent.title) returned unreadable history.")
                        }
                        if method == "initialize" {
                            let initialized = frame(["jsonrpc": "2.0", "method": "initialized"])
                            requestID += 1
                            return .write(initialized + begin())
                        }
                        return accept(result)
                    }
                } catch { return fail(error.localizedDescription) }
                return .none
            }
        }

        private func begin() -> Data {
            if let candidate {
                return request(agent == .codex ? "thread/fork" : "sessions.fork",
                               agent == .codex ? ["threadId": candidate.sessionID, "excludeTurns": true]
                                : ["sessionId": candidate.sessionID, "name": candidate.displayTitle])
            }
            return list(cursor: nil)
        }

        private func list(cursor: String?) -> Data {
            if agent == .copilot {
                return request("sessions.list", ["source": "local", "filter": ["cwd": folder]])
            }
            var params: [String: Any] = ["cwd": folder, "limit": 100, "sortKey": "updated_at",
                                         "sourceKinds": ["cli", "vscode"], "useStateDbOnly": true]
            if let cursor { params["cursor"] = cursor }
            return request("thread/list", params)
        }

        private func accept(_ result: [String: Any]) -> CommandRunner.OutputLineAction {
            switch method {
            case "thread/list", "sessions.list":
                guard let rows = result[agent == .codex ? "data" : "sessions"] as? [[String: Any]] else {
                    return fail("\(agent.title) returned an unreadable session list.")
                }
                reading.candidates += rows.compactMap(candidate(from:))
                if let cursor = result["nextCursor"] as? String {
                    guard cursors.insert(cursor).inserted else { return fail("History pagination repeated a page.") }
                    requestID += 1
                    return .write(list(cursor: cursor))
                }
            case "thread/fork", "sessions.fork":
                let id = agent == .codex ? (result["thread"] as? [String: Any])?["id"] as? String
                    : result["sessionId"] as? String
                guard let id, !id.isEmpty, id != candidate?.sessionID,
                      UUID(uuidString: id) != nil else {
                    return fail("\(agent.title) did not create a separate conversation.")
                }
                reading.resumeID = id
                if agent == .codex { return .write(turns(cursor: nil)) }
            case "thread/turns/list", "thread/read":
                let rows = method == "thread/read"
                    ? (result["thread"] as? [String: Any])?["turns"] as? [[String: Any]]
                    : result["data"] as? [[String: Any]]
                guard let rows else { return fail("Codex returned an unreadable conversation.") }
                for turn in rows { CodexTranscriptImport.append(turn, to: &transcript, fallbackDate: candidate?.startedAt) }
                if let cursor = result["nextCursor"] as? String {
                    guard cursors.insert(cursor).inserted else { return fail("History pagination repeated a page.") }
                    return .write(turns(cursor: cursor))
                }
                reading.messages = transcript.finish()
            default: return fail("Unexpected history response.")
            }
            complete = true
            return .finishProcess
        }

        private func turns(cursor: String?) -> Data {
            var params: [String: Any] = ["threadId": reading.resumeID ?? "", "limit": 10,
                                         "sortDirection": "asc", "itemsView": "full"]
            if let cursor { params["cursor"] = cursor }
            return next("thread/turns/list", params)
        }

        private func candidate(from row: [String: Any]) -> ExternalSessionCandidate? {
            let context = row["context"] as? [String: Any] ?? [:]
            guard let id = row[agent == .codex ? "id" : "sessionId"] as? String,
                  UUID(uuidString: id) != nil,
                  let cwd = (row["cwd"] ?? context["cwd"]) as? String,
                  ClaudeSessionCatalog.standardized(cwd) == folder,
                  row["isRemote"] as? Bool != true, row["isDetached"] as? Bool != true else { return nil }
            let start = agent == .codex ? (row["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                : ClaudeTranscriptImport.date(row["startTime"])
            let last = agent == .codex ? (row["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                : ClaudeTranscriptImport.date(row["modifiedTime"])
            let file = agent == .copilot ? root.appendingPathComponent("session-state/\(id)/events.jsonl")
                : URL(fileURLWithPath: row["path"] as? String ?? root.path)
            let prompt = (row["preview"] ?? row["summary"]) as? String
            guard row["name"] as? String != nil || prompt?.isEmpty == false else { return nil }
            return ExternalSessionCandidate(sessionID: id, agent: agent, file: file, cwd: cwd,
                title: row["name"] as? String, firstPrompt: prompt, startedAt: start,
                lastActivity: last ?? start ?? .distantPast,
                gitBranch: (row["gitInfo"] as? [String: Any])?["branch"] as? String ?? context["branch"] as? String,
                bytes: 0, configDirectory: root)
        }

        private func next(_ method: String, _ params: [String: Any]) -> Data {
            requestID += 1
            return request(method, params)
        }

        private func request(_ method: String, _ params: [String: Any]) -> Data {
            self.method = method
            return frame(["jsonrpc": "2.0", "id": requestID, "method": method, "params": params])
        }

        private func frame(_ object: [String: Any]) -> Data {
            guard let body = try? JSONSerialization.data(withJSONObject: object) else { return Data() }
            return agent == .codex ? body + Data([0x0A])
                : Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
        }

        private func fail(_ message: String) -> CommandRunner.OutputLineAction {
            failure = Failure(message: message)
            return .finishProcess
        }
    }
}
