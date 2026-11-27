import Foundation

// Each process owns one conversation. The lock serializes pipe reads, task refreshes,
// and user input so a late task-list reply cannot finish a newer turn.
final class AgentSessionConnection: @unchecked Sendable {
    private enum Request {
        case initialize, session, permissions, send
        case tasks(Int)
        case agentStatus(String, Int)
        case cancel, ignore
        case steer
        // Kiro: a session option set before the first prompt, such as the model. One that
        // is optional is skipped when Kiro refuses it, rather than failing the turn.
        case configure(optional: Bool)
    }

    private let lock = NSLock()
    let launch: AgentServerLaunch
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
    private var tasks: [BackgroundTask] = []
    private var agents: [String: BackgroundTask] = [:]
    private var agentReads: Set<String> = []
    private var terminals: [BackgroundTask] = []
    private let copilot = CopilotStream()
    private let kiro = KiroStream()
    // Kiro's permission requests waiting on the person, by the id the card carries.
    private var kiroPermissions: [String: (id: Any, options: [[String: Any]])] = [:]
    // Kiro session options still to be set before the first prompt goes out.
    private var kiroOptions: [KiroOption] = []
    private var usageBaseline: [String: Int]?
    private var activeTurnID: String?
    private var questions: [String: (id: Any, method: String, params: [String: Any])] = [:]

    init(launch: AgentServerLaunch, write: @escaping @Sendable (Data) -> Bool) {
        framer = AgentMessageFramer(format: launch.agent == .copilot ? .contentLength : .jsonLines)
        self.launch = launch
        self.write = write
    }

    func start(_ prompt: String) -> Bool {
        lock.withLock {
            self.prompt = prompt
            if launch.agent == .codex {
                request("initialize", ["clientInfo": ["name": "code_station", "version": "1.0"],
                                       "capabilities": ["experimentalApi": true]], as: .initialize)
            } else if launch.agent == .kiro {
                // The app reads and writes no files on the agent's behalf and runs no
                // terminals for it. It does run sign-in in a terminal of its own, which
                // is what the terminal-auth flag tells Kiro.
                request("initialize", [
                    "protocolVersion": 1,
                    "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false],
                                           "terminal": false, "_meta": ["terminal-auth": true]],
                    "clientInfo": ["name": "code-station", "version": "1.0"],
                ], as: .initialize)
            } else {
                openSession()
            }
            return !writeFailed
        }
    }

    func send(_ prompt: String) -> Bool {
        lock.withLock {
            guard !closed, sessionID != nil else { return false }
            sendPrompt(prompt)
            return !writeFailed
        }
    }

    // Puts a prompt into the turn that is running instead of waiting for it to end. The
    // request id comes back so the reply can be matched to the prompt it carried; nil
    // means there is no live turn to steer, and the prompt should wait in the queue.
    func steer(_ prompt: String) -> Int? {
        lock.withLock {
            guard !closed, !ending, launch.agent == .codex,
                  let sessionID, let activeTurnID else { return nil }
            let id = requests.insert(.steer, at: Date())
            emit(["jsonrpc": "2.0", "id": id, "method": "turn/steer",
                  "params": ["threadId": sessionID, "expectedTurnId": activeTurnID,
                             "input": [["type": "text", "text": prompt]]]])
            return writeFailed ? nil : id
        }
    }

    var hasActiveTurn: Bool {
        lock.withLock { !closed && !ending && activeTurnID != nil }
    }

    func refreshTasks(at date: Date = Date()) -> Bool {
        lock.withLock {
            guard !closed else { return true }
            if requests.hasExpired(at: date, timeout: 180, where: { request in
                // ACP answers a prompt only when the whole turn ends, including time
                // spent waiting for permission. It is not a short-lived RPC.
                if launch.agent == .kiro, case .send = request { return false }
                return true
            }) { return false }
            if idle { requestTasks() }
            return !writeFailed
        }
    }

    func close() {
        lock.withLock {
            closed = true
            kiroPermissions = [:]
        }
    }

    func cancelTasks() -> Bool {
        lock.withLock {
            guard let sessionID, !closed else { return false }
            ending = true
            idle = false
            if launch.agent == .codex {
                request("thread/backgroundTerminals/clean", ["threadId": sessionID], as: .cancel)
            } else if launch.agent == .kiro {
                // ACP's cancel is a notification. The prompt it stops answers with a
                // cancelled stop reason, which is what ends the turn.
                emit(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionID]])
            } else {
                for task in tasks {
                    request("session.tasks.cancel", ["sessionId": sessionID, "id": task.id], as: .cancel)
                }
                request("session.abort", ["sessionId": sessionID], as: .cancel)
            }
            return !writeFailed
        }
    }

    func receive(_ data: Data) -> [StreamEvent] {
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
        guard let bytes = framer.frame(message), write(bytes) else {
            writeFailed = true
            return
        }
    }

    private func request(_ method: String, _ params: [String: Any], as kind: Request) {
        let id = requests.insert(kind, at: Date())
        emit(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func openSession() {
        var params = (try? JSONSerialization.jsonObject(with: launch.sessionParameters)) as? [String: Any] ?? [:]
        if let initial = params.removeValue(forKey: "initialPrompt") as? String { prompt = initial }
        if launch.agent == .kiro {
            // Loading answers without the id it loaded, so the id asked for is the one kept.
            sessionID = launch.resume ? params["sessionId"] as? String : nil
            request(launch.resume ? "session/load" : "session/new", params, as: .session)
            return
        }
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
        } else if launch.agent == .kiro {
            request("session/prompt", ["sessionId": sessionID,
                                       "prompt": [["type": "text", "text": prompt]]], as: .send)
        } else {
            request("session.send", ["sessionId": sessionID, "prompt": prompt], as: .send)
        }
    }

    private func requestTasks(cursor: String? = nil) {
        // Kiro has no list of background work to ask for: a turn is over when its prompt
        // is answered.
        guard launch.agent != .kiro else { return }
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
            switch launch.agent {
            case .codex: return codexNotification(method, params)
            case .kiro: return kiroNotification(method, params)
            default: return copilotNotification(method, params)
            }
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
        // A steer that missed its turn is not the turn failing: the prompt is simply still
        // to be sent, which the runner handles.
        if case .steer = kind {
            if let error = message.error {
                return [.steerRejected(requestID: id, message: error.message)]
            }
            return [.steerAccepted(requestID: id)]
        }
        if case .configure(optional: true) = kind, let error = message.error {
            SessionLog.note("kiro skipped a session option: \(error.message)")
            configureKiroOrSend()
            return []
        }
        if let error = message.error {
            return [.finished(isError: true, message: "\(launch.agent.title) session request failed: "
                              + error.message)]
        }
        let result = message.result
        switch kind {
        case .initialize:
            if launch.agent != .kiro { emit(["jsonrpc": "2.0", "method": "initialized", "params": [:]]) }
            openSession()
        case .session:
            if launch.agent == .kiro {
                sessionID = sessionID ?? result["sessionId"] as? String
                guard let sessionID else {
                    return [.finished(isError: true, message: "Kiro did not return a session ID.")]
                }
                kiroOptions = Self.kiroSessionOptions(current: result["configOptions"] as? [[String: Any]],
                                                      model: launch.model,
                                                      planning: launch.permissionMode == .plan)
                configureKiroOrSend()
                return [.initialized(sessionID: sessionID)]
            }
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
        case .configure:
            configureKiroOrSend()
        case .send where launch.agent == .kiro:
            // The prompt's answer is the end of the turn: ACP has nothing else to wait on,
            // and no request the turn made can still be answered.
            idle = true
            kiroPermissions = [:]
            var events = kiro.finish()
            switch result["stopReason"] as? String {
            case "refusal":
                events.append(.finished(isError: true, message: "Kiro declined to answer this request."))
            case "max_tokens":
                events.append(.finished(isError: true, message: "Kiro stopped: the reply reached its length limit."))
            case "max_turn_requests":
                events.append(.finished(isError: true, message: "Kiro stopped: the turn made too many model requests."))
            default:
                events.append(.finished(isError: false, message: nil))
            }
            return events
        case .send, .ignore, .steer:
            break
        }
        return []
    }

    struct KiroOption: Equatable {
        let id: String
        let value: String
        var optional = false
    }

    // The options a Kiro session is opened with before its first prompt: the model the
    // session chose, and Kiro's own planning mode for a plan-first session. An option the
    // session already has is not set again.
    static func kiroSessionOptions(current: [[String: Any]]?, model: String?,
                                   planning: Bool) -> [KiroOption] {
        let mode = current?.first { $0["id"] as? String == "mode" }
        func now(_ id: String) -> String? {
            current?.first { $0["id"] as? String == id }?["currentValue"] as? String
        }
        var wanted: [KiroOption] = []
        if let model, now("model") != model { wanted.append(KiroOption(id: "model", value: model)) }
        // Planning is asked for outright. Leaving it is only sent to a session Kiro says
        // is still planning, which a resumed one can be. The way out is one of the modes
        // Kiro lists, and if it refuses, the turn still goes ahead in plan mode, which
        // only asks more of the person, never less.
        if planning {
            if now("mode") != "plan" { wanted.append(KiroOption(id: "mode", value: "plan")) }
        } else if now("mode") == "plan" {
            let listed = selectValues(mode?["options"]).filter { $0 != "plan" }
            let leave = listed.first { $0 == "vibe" } ?? listed.first ?? "vibe"
            wanted.append(KiroOption(id: "mode", value: leave, optional: true))
        }
        return wanted
    }

    // The values of an ACP select option, whose choices can be listed flat or in groups.
    private static func selectValues(_ options: Any?) -> [String] {
        (options as? [[String: Any]] ?? []).flatMap { entry -> [String] in
            if let value = entry["value"] as? String { return [value] }
            return selectValues(entry["options"])
        }
    }

    private func configureKiroOrSend() {
        guard let sessionID else { return }
        guard !kiroOptions.isEmpty else {
            sendPrompt(prompt)
            return
        }
        let option = kiroOptions.removeFirst()
        request("session/set_config_option",
                ["sessionId": sessionID, "configId": option.id, "value": option.value],
                as: .configure(optional: option.optional))
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

    private func backgroundTask(_ raw: [String: Any]) -> BackgroundTask? {
        if launch.agent == .codex {
            guard let id = raw["processId"] as? String else { return nil }
            return BackgroundTask(id: id, kind: "local_bash", description: "Command \(id)",
                                  toolUseID: raw["itemId"] as? String,
                                  command: raw["command"] as? String)
        }
        guard let id = raw["id"] as? String,
              ["running", "idle"].contains(raw["status"] as? String ?? "") else { return nil }
        return BackgroundTask(id: id, kind: raw["type"] as? String == "agent" ? "local_agent" : "local_bash",
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
            activeTurnID = nil
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
                            agents[id] = agents[id] ?? BackgroundTask(
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

    func kiroNotification(_ method: String, _ params: [String: Any]) -> [StreamEvent] {
        guard method == "session/update", params["sessionId"] as? String == sessionID,
              let update = params["update"] as? [String: Any] else { return [] }
        let events = kiro.events(update)
        if events.contains(where: { if case .turnStarted = $0 { return true }; return false }) {
            hasStartedTurn = true
            generation += 1
            idle = false
        }
        return events
    }

    // Kiro asks before a call its own settings do not already allow. The session's access
    // mode answers what it covers - edits inside the session's folders, when edits are
    // allowed - and everything else goes to the person.
    func kiroPermission(id: Any, params: [String: Any]) -> [StreamEvent] {
        let options = params["options"] as? [[String: Any]] ?? []
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let callID = toolCall["toolCallId"] as? String ?? ""
        let consent = ((params["_meta"] as? [String: Any])?["kiro"] as? [String: Any])?["consent"]
            as? [String: Any]
        if allowsWithoutAsking(capability: consent?["capability"] as? String,
                               resource: consent?["resource"] as? String),
           let allow = options.first(where: { $0["kind"] as? String == "allow_once" })?["optionId"] {
            emit(["jsonrpc": "2.0", "id": id,
                  "result": ["outcome": ["outcome": "selected", "optionId": allow]]])
            return []
        }
        let key = UUID().uuidString
        kiroPermissions[key] = (id, options)
        let call = kiro.call(callID)
            ?? (consent?["capability"] as? String == "mcp"
                ? (consent?["resource"] as? String).flatMap(KiroStream.mcpCall(resource:)) : nil)
        return [.permissionRequest(.kiro(id: key, call: call,
                                         title: toolCall["title"] as? String ?? "Tool",
                                         projectPath: launch.directory))]
    }

    private func allowsWithoutAsking(capability: String?, resource: String?) -> Bool {
        guard capability == "fs_write",
              [.acceptEdits, .auto].contains(launch.permissionMode),
              let resource, !resource.isEmpty else { return false }
        let absolute = resource.hasPrefix("/") ? resource : launch.directory + "/" + resource
        guard let path = Self.resolvedWritePath(absolute) else { return false }
        return ([launch.directory] + launch.directories).contains { root in
            guard let root = Self.resolvedWritePath(root) else { return false }
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    private static func resolvedWritePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        var resolved = ""
        // Resolve links before consuming '..', even when the file or its parents are
        // still to be created. URL normalization alone can miss both cases.
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                resolved = String(resolved.prefix(upTo: resolved.lastIndex(of: "/") ?? resolved.startIndex))
                continue
            }
            let candidate = resolved + "/" + component
            if let canonical = realpath(candidate, nil) {
                resolved = String(cString: canonical)
                free(canonical)
            } else {
                guard errno == ENOENT else { return nil }
                var attributes = stat()
                // A dangling link also fails realpath with ENOENT. It must ask, since
                // creating its target could otherwise turn this into an outside write.
                guard lstat(candidate, &attributes) != 0, errno == ENOENT else { return nil }
                resolved = candidate
            }
        }
        return resolved.isEmpty ? "/" : resolved
    }

    func serverRequest(id: Any, method: String, params: [String: Any]) -> [StreamEvent] {
        if launch.agent == .kiro, method == "session/request_permission" {
            return kiroPermission(id: id, params: params)
        }
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
    func answer(_ request: PermissionRequest, with answer: PermissionAnswer) -> Bool {
        lock.withLock {
            if let pending = kiroPermissions.removeValue(forKey: request.id) {
                guard !closed else { return false }
                // Kiro names its own options; the answer picks the one of the matching kind.
                let kind = switch answer {
                case .allowAlways: "allow_always"
                case .deny, .revise: "reject_once"
                case .allowOnce, .allowAddingDirectory, .answers: "allow_once"
                }
                let option = pending.options.first { $0["kind"] as? String == kind }?["optionId"]
                    ?? pending.options.first { $0["kind"] as? String == (answer.allows ? "allow_once" : "reject_once") }?["optionId"]
                let outcome: [String: Any] = option.map { ["outcome": "selected", "optionId": $0] }
                    ?? ["outcome": "cancelled"]
                emit(["jsonrpc": "2.0", "id": pending.id, "result": ["outcome": outcome]])
                return !writeFailed
            }
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
