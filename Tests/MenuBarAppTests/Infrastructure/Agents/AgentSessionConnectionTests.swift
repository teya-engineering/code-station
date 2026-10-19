import Foundation
import Testing
@testable import CodeStationCore

struct AgentSessionConnectionTests {
    @Test(arguments: [AgentKind.codex, .copilot])
    func holdsIdleSessionsUntilTheirTasksEnd(agent: AgentKind) throws {
        let wire = try Wire(agent)
        try wire.boot()
        let pending = try wire.idleTasks([wire.task("one"), wire.task("two")])
        #expect(pending.tasks.map(\.id) == ["one", "two"])
        #expect(pending.finished)
        #expect(wire.connection.refreshTasks())
        let unchanged = try wire.replyTasks([wire.task("one"), wire.task("two")])
        #expect(!unchanged.finished)
        #expect(wire.connection.refreshTasks())
        let ended = try wire.replyTasks([])
        #expect(ended.tasks.isEmpty)
        #expect(ended.finished)
    }

    @Test(arguments: [AgentKind.codex, .copilot])
    func ignoresTaskRepliesFromBeforeAFollowUp(agent: AgentKind) throws {
        let wire = try Wire(agent)
        try wire.boot()
        _ = try wire.idleTasks([wire.task("one")])
        #expect(wire.connection.refreshTasks())
        let previous = try wire.lastRequest()
        #expect(wire.connection.send("Continue with the next step"))
        let events = try wire.respond(previous, [wire.taskField: []])
        #expect(!events.finished)
        #expect(events.events.isEmpty)
    }

    @Test func staleTaskErrorsCannotFinishAFollowUp() throws {
        let wire = try Wire(.codex)
        try wire.boot()
        _ = try wire.idleTasks([wire.task("one")])
        #expect(wire.connection.refreshTasks())
        let previous = try wire.lastRequest()
        #expect(wire.connection.send("Continue"))
        let events = wire.connection.receive(try wire.frame([
            "id": try #require(previous["id"]), "error": ["code": -1, "message": "Old request failed"]
        ]))
        #expect(events.isEmpty)
    }

    @Test(arguments: [AgentKind.codex, .copilot])
    func waitsForCancellationAcknowledgements(agent: AgentKind) throws {
        let wire = try Wire(agent)
        try wire.boot()
        _ = try wire.idleTasks([wire.task("one"), wire.task("two")])
        let count = wire.output.messages.count
        #expect(wire.connection.cancelTasks())
        let cancellations = try wire.output.messages.dropFirst(count).map(wire.decode)
        #expect(!cancellations.isEmpty)
        for (index, message) in cancellations.enumerated() {
            let result = try wire.respond(message, ["cancelled": true])
            #expect(result.finished == (index == cancellations.count - 1))
        }
    }

    @Test(arguments: [AgentKind.codex, .copilot])
    func ignoresIdleUntilTheNewTurnStarts(agent: AgentKind) throws {
        let wire = try Wire(agent)
        try wire.boot()
        #expect(wire.connection.send("Follow up"))
        let before = wire.output.messages.count
        if agent == .codex {
            _ = try wire.notify("turn/completed", ["threadId": "session", "turn": ["status": "completed"]])
        } else {
            _ = try wire.copilotEvent("session.idle", [:])
        }
        #expect(wire.output.messages.count == before)
    }

    @Test func readsFragmentedCopilotFramesUsingByteLengths() throws {
        let wire = try Wire(.copilot)
        try wire.boot()
        let bytes = try wire.frame(["method": "session.event", "params": [
            "sessionId": "session", "event": ["type": "assistant.message", "data": ["content": "Olá 🌿"]]
        ]])
        var events: [StreamEvent] = []
        for byte in bytes { events += wire.connection.receive(Data([byte])) }
        #expect(events.contains { if case .text("Olá 🌿") = $0 { return true }; return false })
    }

    @Test func codexCollectsEveryPageBeforeEndingATurn() throws {
        let wire = try Wire(.codex)
        try wire.boot()
        _ = try wire.notify("turn/completed", ["threadId": "session", "turn": ["status": "completed"]])
        let first = try wire.respond(wire.lastRequest(), ["data": [wire.task("one")], "nextCursor": "page2"])
        #expect(!first.finished)
        let second = try wire.replyTasks([wire.task("two")])
        #expect(second.finished)
        #expect(second.tasks.map(\.id) == ["one", "two"])
    }

    @Test func copilotUsesMainLoopIdleAndSkipsCompletedTasks() throws {
        let wire = try Wire(.copilot)
        try wire.boot()
        let count = wire.output.messages.count
        _ = try wire.copilotEvent("assistant.turn_end", [:])
        _ = try wire.copilotEvent("assistant.idle", ["parentToolCallId": "child"])
        #expect(wire.output.messages.count == count)
        var completed = wire.task("finished")
        completed["status"] = "completed"
        let result = try wire.idleTasks([completed, wire.task("pending")])
        #expect(result.tasks.map(\.id) == ["pending"])
        #expect(result.tasks.first?.command == "sleep 600")
    }

    @Test func codexMapsCommandResultsAndDoesNotChargeHistoricalUsage() throws {
        let wire = try Wire(.codex)
        try wire.boot()
        let events = try wire.notify("item/completed", ["threadId": "session", "item": [
            "type": "commandExecution", "id": "cmd", "command": "sleep 600",
            "aggregatedOutput": "done", "exitCode": 0, "status": "completed"
        ]])
        #expect(events.events.contains {
            if case .toolResult("cmd", "done", false, 0) = $0 { return true }; return false
        })
        let usage = try wire.notify("thread/tokenUsage/updated", ["threadId": "session", "tokenUsage": [
            "total": ["inputTokens": 1000, "cachedInputTokens": 400, "outputTokens": 100],
            "last": ["inputTokens": 200, "cachedInputTokens": 50, "outputTokens": 20, "totalTokens": 220]
        ]])
        let reading = try #require(usage.events.compactMap { event -> TurnUsage? in
            if case .usage(let value) = event { return value }; return nil
        }.first)
        #expect(reading.inputTokens == 150)
        #expect(reading.cacheReadTokens == 50)
        #expect(reading.outputTokens == 20)
    }

    @Test func codexKeepsChildAgentsUntilTheyBecomeIdle() throws {
        let wire = try Wire(.codex)
        try wire.boot()
        _ = try wire.notify("item/completed", ["threadId": "session", "item": [
            "id": "spawn", "type": "collabAgentToolCall", "tool": "spawnAgent",
            "receiverThreadIds": ["child"], "agentsStates": ["child": ["status": "running"]],
            "prompt": "Review the change", "status": "completed"
        ]])
        let pending = try wire.idleTasks([])
        #expect(!pending.finished)
        #expect(try wire.lastRequest()["method"] as? String == "thread/read")
        let running = try wire.respond(wire.lastRequest(), ["thread": [
            "id": "child", "agentNickname": "Reviewer", "status": ["type": "active"]
        ]])
        #expect(running.tasks.first?.label == "Reviewer · Review the change")
        #expect(running.finished)
        #expect(wire.connection.refreshTasks())
        _ = try wire.replyTasks([])
        let done = try wire.respond(wire.lastRequest(), ["thread": ["id": "child", "status": ["type": "idle"]]])
        #expect(done.tasks.isEmpty)
        #expect(done.finished)
    }

    @Test func copilotQuestionsReturnThroughTheServerProtocol() throws {
        let wire = try Wire(.copilot)
        try wire.boot()
        let events = wire.connection.receive(try wire.frame([
            "id": "question", "method": "userInput.request", "params": [
                "sessionId": "session", "question": "Which task?", "choices": ["First", "Second"]
            ]
        ]))
        let request = try #require(events.compactMap { event -> PermissionRequest? in
            if case .permissionRequest(let value) = event { return value }; return nil
        }.first)
        #expect(wire.connection.answer(request, with: .answers(["Which task?": "Second"])))
        let reply = try wire.lastRequest()
        #expect(reply["id"] as? String == "question")
        #expect((reply["result"] as? [String: Any])?["answer"] as? String == "Second")
    }

    @Test func unsupportedRequestsReceiveAnErrorInsteadOfHanging() throws {
        let wire = try Wire(.codex)
        try wire.boot()
        _ = wire.connection.receive(try wire.frame(["id": 900, "method": "unsupported/request", "params": [:]]))
        let response = try wire.lastRequest()
        #expect(response["id"] as? Int == 900)
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func doesNotTreatTaskListFailuresAsAnEmptyList() throws {
        let wire = try Wire(.codex)
        try wire.boot()
        _ = try wire.notify("turn/completed", ["threadId": "session", "turn": ["status": "completed"]])
        let request = try wire.lastRequest()
        let events = wire.connection.receive(try wire.frame([
            "id": try #require(request["id"]), "error": ["code": -32601, "message": "Method not found"]
        ]))
        #expect(events.contains { if case .finished(true, _) = $0 { return true }; return false })
        #expect(!events.contains { if case .backgroundTasks = $0 { return true }; return false })
    }

    @Test(arguments: [false, true])
    func copilotPreservesAccessBoundaries(fullAccess: Bool) throws {
        let wire = try Wire(.copilot, settings: SessionSettings(copilotAccessMode: fullAccess ? .fullAccess : .workspace),
                            directories: ["/tmp/attached"], prompt: "--allow-all")
        #expect(wire.connection.start("hello"))
        _ = try wire.respond(wire.lastRequest(), ["sessionId": "session"])
        let request = try wire.lastRequest()
        #expect(request["method"] as? String == "session.permissions.configure")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["approveAllToolPermissionRequests"] as? Bool == true)
        #expect(params["approveAllReadPermissionRequests"] as? Bool == fullAccess)
        #expect((params["paths"] as? [String: Any])?["unrestricted"] as? Bool == fullAccess)
        #expect((params["urls"] as? [String: Any])?["unrestricted"] as? Bool == fullAccess)
        #expect((params["paths"] as? [String: Any])?["additionalDirectories"] as? [String] == ["/tmp/attached"])
    }

    @Test func codexPreservesSandboxAndAutoReviewSettings() throws {
        let configuration = AgentLaunchConfiguration(
            agent: .codex,
            settings: SessionSettings(model: "gpt-5.6-terra", effort: "high", codexSandboxMode: .approveForMe),
            defaults: SessionSettings(), addDirectories: ["/tmp/attached"],
            writableRoots: ["/tmp/attached"], resume: "existing")
        let launch = try AgentServerLaunch(configuration: configuration, directory: "/tmp/project")
        #expect(launch.arguments.first == "app-server")
        #expect(launch.arguments.contains("sandbox_mode=\"workspace-write\""))
        #expect(launch.arguments.contains("approvals_reviewer=\"auto_review\""))
        #expect(launch.arguments.contains("sandbox_workspace_write.writable_roots=[\"/tmp/attached\"]"))
        let params = try #require(JSONSerialization.jsonObject(with: launch.sessionParameters) as? [String: Any])
        #expect(params["threadId"] as? String == "existing")
        #expect(params["model"] as? String == "gpt-5.6-terra")
        #expect(params["approvalPolicy"] == nil)
    }
}

private final class Wire {
    let agent: AgentKind
    let output = Output()
    let connection: AgentSessionConnection
    var taskField: String { agent == .codex ? "data" : "tasks" }

    init(_ agent: AgentKind, settings: SessionSettings = SessionSettings(),
         directories: [String] = [], prompt: String? = nil) throws {
        self.agent = agent
        let output = self.output
        connection = AgentSessionConnection(launch: try AgentServerLaunch(
            configuration: AgentLaunchConfiguration(agent: agent, settings: settings, defaults: SessionSettings(),
                                                    addDirectories: directories, prompt: prompt),
            directory: "/tmp/project")) {
                output.append($0)
                return true
            }
    }

    func boot() throws {
        #expect(connection.start("Start the timer"))
        if agent == .codex { _ = try respond(lastRequest(), [:]) }
        _ = try respond(lastRequest(), agent == .codex ? ["thread": ["id": "session"]] : ["sessionId": "session"])
        if agent == .copilot { _ = try respond(lastRequest(), ["success": true]) }
        _ = try respond(lastRequest(), [:])
        if agent == .codex {
            _ = try notify("turn/started", ["threadId": "session", "turn": ["id": "turn"]])
        } else {
            _ = try copilotEvent("assistant.turn_start", [:])
        }
    }

    func frame(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        if agent == .codex { return body + Data([0x0A]) }
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    func decode(_ bytes: Data) throws -> [String: Any] {
        let start = agent == .copilot ? try #require(bytes.range(of: Data("\r\n\r\n".utf8))).upperBound : bytes.startIndex
        return try #require(JSONSerialization.jsonObject(with: bytes[start...]) as? [String: Any])
    }

    func lastRequest() throws -> [String: Any] { try decode(#require(output.messages.last)) }

    func respond(_ request: [String: Any], _ result: [String: Any]) throws -> Events {
        Events(events: connection.receive(try frame(["id": try #require(request["id"]), "result": result])))
    }

    func notify(_ method: String, _ params: [String: Any]) throws -> Events {
        Events(events: connection.receive(try frame(["method": method, "params": params])))
    }

    func copilotEvent(_ type: String, _ data: [String: Any]) throws -> Events {
        try notify("session.event", ["sessionId": "session", "event": ["type": type, "data": data]])
    }

    func idleTasks(_ tasks: [[String: Any]]) throws -> Events {
        if agent == .codex {
            _ = try notify("turn/completed", ["threadId": "session", "turn": ["status": "completed"]])
        } else {
            _ = try copilotEvent("assistant.idle", [:])
        }
        return try replyTasks(tasks)
    }

    func replyTasks(_ tasks: [[String: Any]]) throws -> Events {
        try respond(lastRequest(), [taskField: tasks])
    }

    func task(_ id: String) -> [String: Any] {
        agent == .codex ? ["processId": id, "itemId": "command-\(id)", "command": "sleep 600"]
            : ["id": id, "type": "shell", "description": "Preview timer", "command": "sleep 600", "status": "running"]
    }

    struct Events {
        let events: [StreamEvent]
        var finished: Bool { events.contains { if case .finished(false, _) = $0 { return true }; return false } }
        var tasks: [AgentBackgroundTask] {
            events.compactMap { if case .backgroundTasks(let tasks) = $0 { return tasks }; return nil }.last ?? []
        }
    }

    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []
        var messages: [Data] { lock.withLock { stored } }
        func append(_ bytes: Data) { lock.withLock { stored.append(bytes) } }
    }
}
