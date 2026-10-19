import Foundation

// Each process owns one conversation. The lock serializes pipe reads, task refreshes,
// and user input so a late task-list reply cannot finish a newer turn.
public final class AgentSessionConnection: @unchecked Sendable {
    private enum Request {
        case initialize, session, permissions, send
        case tasks(Int)
        case agentStatus(String, Int)
        case cancel, ignore
    }

    private let lock = NSLock()
    public let launch: AgentServerLaunch
    private let write: @Sendable (Data) -> Bool
    private var framer: AgentMessageFramer
    private var requests = AgentRequestTracker<Request>()
    private var sessionID: String?
    private var prompt = ""
    private var generation = 0
    private var idle = false
    private var hasStartedTurn = false
    private var waitingReported = false
    private var taskRequestPending = false
    private var taskPages: [[String: Any]] = []
    private var ending = false
    private var closed = false
    private var writeFailed = false
    private var tasks: [AgentBackgroundTask] = []
    private var agents: [String: AgentBackgroundTask] = [:]
    private var agentReads: Set<String> = []
    private var terminals: [AgentBackgroundTask] = []
    private let copilot = CopilotStream()
    private var usageBaseline: [String: Int]?
    private var activeTurnID: String?
    private var questions: [String: (id: Any, method: String, params: [String: Any])] = [:]

    public init(launch: AgentServerLaunch, write: @escaping @Sendable (Data) -> Bool) {
        framer = AgentMessageFramer(format: launch.agent == .codex ? .jsonLines : .contentLength)
        self.launch = launch
        self.write = write
    }

    public func start(_ prompt: String) -> Bool {
        lock.withLock {
            self.prompt = prompt
            if launch.agent == .codex {
                request("initialize", ["clientInfo": ["name": "code_station", "version": "1.0"],
                                       "capabilities": ["experimentalApi": true]], as: .initialize)
            } else {
                openSession()
            }
            return !writeFailed
        }
    }

    public func send(_ prompt: String) -> Bool {
        lock.withLock {
            guard !closed, sessionID != nil else { return false }
            sendPrompt(prompt)
            return !writeFailed
        }
    }

    public func refreshTasks() -> Bool {
        lock.withLock {
            guard !closed else { return true }
            if requests.hasExpired(at: Date(), timeout: 180) { return false }
            if idle { requestTasks() }
            return !writeFailed
        }
    }

    public func close() { lock.withLock { closed = true } }

    public func cancelTasks() -> Bool {
        lock.withLock {
            guard let sessionID, !closed else { return false }
            ending = true
            idle = false
            if launch.agent == .codex {
                request("thread/backgroundTerminals/clean", ["threadId": sessionID], as: .cancel)
            } else {
                for task in tasks {
                    request("session.tasks.cancel", ["sessionId": sessionID, "id": task.id], as: .cancel)
                }
                request("session.abort", ["sessionId": sessionID], as: .cancel)
            }
            return !writeFailed
        }
    }

    public func receive(_ data: Data) -> [StreamEvent] {
        lock.withLock {
            guard !closed else { return [] }
            framer.append(data)
            var events: [StreamEvent] = []
            while let message = nextMessage() {
                events += receive(message)
            }
            if writeFailed { events.append(.finished(isError: true, message: "Could not write to the agent session.")) }
            return events
        }
    }

    private func nextMessage() -> [String: Any]? {
        do {
            guard let body = try framer.next() else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        } catch {
            writeFailed = true
            return nil
        }
    }

    private func emit(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else {
            writeFailed = true
            return
        }
        var bytes = launch.agent == .codex ? Data()
            : Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        bytes.append(body)
        if launch.agent == .codex { bytes.append(0x0A) }
        if !write(bytes) { writeFailed = true }
    }

    private func request(_ method: String, _ params: [String: Any], as kind: Request) {
        let id = requests.insert(kind, at: Date())
        emit(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func openSession() {
        var params = (try? JSONSerialization.jsonObject(with: launch.sessionParameters)) as? [String: Any] ?? [:]
        if let initial = params.removeValue(forKey: "initialPrompt") as? String { prompt = initial }
        request(launch.agent == .codex ? (launch.resume ? "thread/resume" : "thread/start")
                : (launch.resume ? "session.resume" : "session.create"), params, as: .session)
    }

    private func sendPrompt(_ prompt: String) {
        guard let sessionID else { return }
        generation += 1
        hasStartedTurn = false
        activeTurnID = nil
        idle = false
        waitingReported = false
        if launch.agent == .codex {
            request("turn/start", ["threadId": sessionID,
                                   "input": [["type": "text", "text": prompt]]], as: .send)
        } else {
            request("session.send", ["sessionId": sessionID, "prompt": prompt], as: .send)
        }
    }

    private func requestTasks(cursor: String? = nil) {
        guard let sessionID, cursor != nil || !taskRequestPending else { return }
        taskRequestPending = true
        var params: [String: Any] = [launch.agent == .codex ? "threadId" : "sessionId": sessionID]
        if let cursor { params["cursor"] = cursor }
        else { taskPages = [] }
        request(launch.agent == .codex ? "thread/backgroundTerminals/list" : "session.tasks.list",
                params, as: .tasks(generation))
    }

    private func receive(_ object: [String: Any]) -> [StreamEvent] {
        let message = AgentRPCMessage(object)
        if let method = message.method {
            guard !ending else { return [] }
            let params = message.params
            if let id = message.id { return serverRequest(id: id, method: method, params: params) }
            return launch.agent == .codex ? codexNotification(method, params) : copilotNotification(method, params)
        }
        guard let id = message.id as? Int, let kind = requests.remove(id) else { return [] }
        switch kind {
        case .tasks(let requestedGeneration) where ending || requestedGeneration != generation:
            taskRequestPending = false
            if idle, !ending { requestTasks() }
            return []
        case .agentStatus(let id, let requestedGeneration) where ending || requestedGeneration != generation:
            agentReads.remove(id)
            if agentReads.isEmpty {
                taskRequestPending = false
                if idle, !ending { requestTasks() }
            }
            return []
        default: break
        }
        if let error = message.error {
            return [.finished(isError: true, message: "\(launch.agent.title) session request failed: "
                              + error.message)]
        }
        let result = message.result
        switch kind {
        case .initialize:
            emit(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
            openSession()
        case .session:
            sessionID = launch.agent == .codex
                ? (result["thread"] as? [String: Any])?["id"] as? String : result["sessionId"] as? String
            guard let sessionID else {
                return [.finished(isError: true, message: "The agent did not return a session ID.")]
            }
            if launch.agent == .copilot {
                request("session.permissions.configure", [
                    "sessionId": sessionID, "approveAllToolPermissionRequests": true,
                    "approveAllReadPermissionRequests": launch.fullAccess,
                    "paths": ["unrestricted": launch.fullAccess, "additionalDirectories": launch.directories],
                    "urls": ["unrestricted": launch.fullAccess]
                ], as: .permissions)
            } else {
                sendPrompt(prompt)
            }
            return [.initialized(sessionID: sessionID)]
        case .permissions:
            guard result["success"] as? Bool == true else {
                return [.finished(isError: true, message: "Copilot could not apply the session access settings.")]
            }
            sendPrompt(prompt)
        case .tasks:
            let raw = result[launch.agent == .codex ? "data" : "tasks"] as? [[String: Any]]
            guard let raw else {
                return [.finished(isError: true, message: "The agent returned an unreadable background task list.")]
            }
            taskPages += raw
            if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                requestTasks(cursor: cursor)
                return []
            }
            terminals = taskPages.compactMap(backgroundTask)
            if launch.agent == .codex, !agents.isEmpty {
                agentReads = Set(agents.keys)
                for id in agentReads.sorted() {
                    request("thread/read", ["threadId": id, "includeTurns": false], as: .agentStatus(id, generation))
                }
                return []
            }
            return taskEvents()
        case .agentStatus(let id, _):
            agentReads.remove(id)
            if let thread = result["thread"] as? [String: Any] {
                if (thread["status"] as? [String: Any])?["type"] as? String != "active" {
                    agents.removeValue(forKey: id)
                } else if let name = thread["agentNickname"] as? String {
                    agents[id]?.agentName = name
                }
            }
            guard agentReads.isEmpty else { return [] }
            return taskEvents()
        case .cancel:
            if !requests.values.contains(where: { if case .cancel = $0 { return true }; return false }) {
                tasks = []
                return [.backgroundTasks([]), .finished(isError: false, message: nil)]
            }
        case .send, .ignore:
            break
        }
        return []
    }

    private func taskEvents() -> [StreamEvent] {
        taskRequestPending = false
        tasks = terminals + agents.values.sorted { $0.id < $1.id }
        var events: [StreamEvent] = [.backgroundTasks(tasks)]
        if idle, !waitingReported || tasks.isEmpty {
            waitingReported = true
            events.append(.finished(isError: false, message: nil))
        }
        return events
    }

    private func backgroundTask(_ raw: [String: Any]) -> AgentBackgroundTask? {
        if launch.agent == .codex {
            guard let id = raw["processId"] as? String else { return nil }
            return AgentBackgroundTask(id: id, kind: "local_bash", description: "Command \(id)",
                                  toolUseID: raw["itemId"] as? String,
                                  command: raw["command"] as? String)
        }
        guard let id = raw["id"] as? String,
              ["running", "idle"].contains(raw["status"] as? String ?? "") else { return nil }
        return AgentBackgroundTask(id: id, kind: raw["type"] as? String == "agent" ? "local_agent" : "local_bash",
                              description: raw["description"] as? String,
                              agentName: raw["displayName"] as? String,
                              toolUseID: raw["toolCallId"] as? String, command: raw["command"] as? String)
    }
}

private extension AgentSessionConnection {
    func codexNotification(_ method: String, _ params: [String: Any]) -> [StreamEvent] {
        if let thread = params["threadId"] as? String, thread != sessionID { return [] }
        switch method {
        case "turn/started":
            hasStartedTurn = true
            generation += 1
            idle = false
            waitingReported = false
            activeTurnID = (params["turn"] as? [String: Any])?["id"] as? String
            return [.turnStarted]
        case "turn/completed":
            guard hasStartedTurn else { return [] }
            let turn = params["turn"] as? [String: Any] ?? [:]
            if turn["status"] as? String == "failed" || turn["status"] as? String == "interrupted" {
                return [.finished(isError: true, message: (turn["error"] as? [String: Any])?["message"] as? String
                                  ?? "The Codex turn was interrupted.")]
            }
            idle = true
            requestTasks()
        case "item/started", "item/completed":
            guard var item = params["item"] as? [String: Any] else { return [] }
            let complete = method == "item/completed"
            switch item["type"] as? String {
            case "agentMessage": item["type"] = "agent_message"
            case "commandExecution":
                item["type"] = "command_execution"
                item["aggregated_output"] = item["aggregatedOutput"]
                item["exit_code"] = item["exitCode"]
            case "fileChange":
                item["type"] = "file_change"
                item["changes"] = (item["changes"] as? [[String: Any]] ?? []).map { change in
                    var change = change
                    if let kind = change["kind"] as? [String: Any] { change["kind"] = kind["type"] }
                    return change
                }
            case "mcpToolCall": item["type"] = "mcp_tool_call"
            case "collabAgentToolCall":
                if complete {
                    for (id, raw) in item["agentsStates"] as? [String: [String: Any]] ?? [:] {
                        if ["running", "pendingInit"].contains(raw["status"] as? String ?? "") {
                            agents[id] = agents[id] ?? AgentBackgroundTask(
                                id: id, kind: "local_agent", description: item["prompt"] as? String ?? "Background agent",
                                toolUseID: item["id"] as? String)
                        } else {
                            agents.removeValue(forKey: id)
                        }
                    }
                }
                item["type"] = "collab_tool_call"
                let tools = ["spawnAgent": "spawn_agent", "sendInput": "send_input",
                             "resumeAgent": "resume_agent", "closeAgent": "close_agent"]
                if let tool = item["tool"] as? String { item["tool"] = tools[tool] ?? tool }
                item["receiver_agents"] = item["receiverThreadIds"]
                item["agents_states"] = item["agentsStates"]
            case "webSearch": item["type"] = "web_search"
            case "reasoning":
                item["text"] = (item["summary"] as? [String] ?? []).joined(separator: "\n\n")
            case "contextCompaction":
                return complete ? [.compacted(preTokens: nil, postTokens: nil)] : []
            default: break
            }
            let envelope: [String: Any] = ["type": complete ? "item.completed" : "item.started", "item": item]
            let events = StreamEvent.codexEvents(envelope)
            if idle, complete { requestTasks() }
            return events
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? [String: Any],
                  let total = usage["total"] as? [String: Int],
                  let last = usage["last"] as? [String: Int] else { return [] }
            if let turnID = params["turnId"] as? String, turnID != activeTurnID {
                if usageBaseline == nil { usageBaseline = total }
                return []
            }
            if usageBaseline == nil {
                usageBaseline = total
                for (key, value) in last { usageBaseline?[key] = max(0, (total[key] ?? 0) - value) }
            }
            func grown(_ key: String) -> Int { max(0, (total[key] ?? 0) - (usageBaseline?[key] ?? 0)) }
            var reading = TurnUsage()
            reading.cacheReadTokens = grown("cachedInputTokens")
            reading.inputTokens = max(0, grown("inputTokens") - reading.cacheReadTokens)
            reading.outputTokens = grown("outputTokens")
            if let window = usage["modelContextWindow"] as? Int { reading.contextWindow = window }
            return [.usage(reading), .context(tokens: last["totalTokens"] ?? 0)]
        case "error":
            let error = params["error"] as? [String: Any] ?? [:]
            let message = error["message"] as? String ?? "Codex lost its connection."
            return params["willRetry"] as? Bool == true ? [.streamError(message)]
                : [.finished(isError: true, message: message)]
        default: break
        }
        return []
    }

    func copilotNotification(_ method: String, _ params: [String: Any]) -> [StreamEvent] {
        guard method == "session.event", params["sessionId"] as? String == sessionID,
              let event = params["event"] as? [String: Any] else { return [] }
        let data = event["data"] as? [String: Any] ?? [:]
        let root = data["parentToolCallId"] == nil && event["agentId"] == nil
        switch event["type"] as? String {
        case "assistant.turn_start" where root:
            hasStartedTurn = true
            generation += 1
            idle = false
            waitingReported = false
            return [.turnStarted]
        case "assistant.idle" where root, "session.idle" where root:
            guard hasStartedTurn else { return [] }
            idle = true
            requestTasks()
        case "session.background_tasks_changed":
            requestTasks()
        case "session.error":
            return [.finished(isError: true, message: data["message"] as? String ?? "Copilot session failed.")]
        case "permission.requested":
            // The configured policy handles allowed operations. Anything still asking
            // falls outside that policy; never silently broaden the session's access.
            if let requestID = data["requestId"] as? String, data["resolvedByHook"] as? Bool != true,
               let sessionID {
                request("session.permissions.handlePendingPermissionRequest", [
                    "sessionId": sessionID, "requestId": requestID,
                    "result": ["kind": "user-not-available"]
                ], as: .ignore)
            }
        default: break
        }
        return copilot.events(event)
    }

    func serverRequest(id: Any, method: String, params: [String: Any]) -> [StreamEvent] {
        if method == "item/tool/requestUserInput" || method == "userInput.request" {
            let raw: [[String: Any]] = method == "userInput.request"
                ? [["id": "answer", "question": params["question"] as? String ?? "",
                    "options": (params["choices"] as? [String] ?? []).map { ["label": $0] }]]
                : params["questions"] as? [[String: Any]] ?? []
            let key = UUID().uuidString
            questions[key] = (id, method, params)
            let questions = raw.enumerated().map { index, question in
                AgentQuestion(id: index, header: question["header"] as? String ?? "",
                              text: question["question"] as? String ?? "", multiSelect: false,
                              options: (question["options"] as? [[String: Any]] ?? []).enumerated().map {
                    AgentQuestion.Option(id: $0.offset, label: $0.element["label"] as? String ?? "",
                                         description: $0.element["description"] as? String ?? "")
                })
            }
            return [.permissionRequest(PermissionRequest(
                id: key, toolName: "AskUserQuestion", title: "Question", subject: "", detail: "",
                input: Data("{}".utf8), suggestions: nil, alwaysTitle: nil, questions: questions))]
        }
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            emit(["jsonrpc": "2.0", "id": id, "result": ["decision": "decline"]])
        } else {
            emit(["jsonrpc": "2.0", "id": id,
                  "error": ["code": -32601, "message": "Code Station does not handle \(method)."]])
        }
        return []
    }
}

extension AgentSessionConnection {
    public func answer(_ request: PermissionRequest, with answer: PermissionAnswer) -> Bool {
        lock.withLock {
            guard !closed, let pending = questions.removeValue(forKey: request.id) else { return false }
            let given: [String: String]
            if case .answers(let answers) = answer { given = answers } else { given = [:] }
            let result: [String: Any]
            if pending.method == "userInput.request" {
                result = ["answer": given.values.first ?? "", "wasFreeform": true]
            } else {
                var answers: [String: Any] = [:]
                for question in pending.params["questions"] as? [[String: Any]] ?? [] {
                    guard let id = question["id"] as? String,
                          let text = question["question"] as? String else { continue }
                    answers[id] = ["answers": given[text].map { [$0] } ?? []]
                }
                result = ["answers": answers]
            }
            emit(["jsonrpc": "2.0", "id": pending.id, "result": result])
            return !writeFailed
        }
    }
}
