import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct AgentHistoryReaderTests {
    private let sourceID = "11111111-1111-4111-8111-111111111111"
    private let forkID = "22222222-2222-4222-8222-222222222222"
    private let root = URL(fileURLWithPath: "/history")

    private func decode(_ data: Data, agent: AgentKind = .codex) throws -> [String: Any] {
        var framer = AgentMessageFramer(format: agent == .codex ? .jsonLines : .contentLength)
        framer.append(data)
        var last: [String: Any] = [:]
        while let body = try framer.next() { last = try JSONSerialization.jsonObject(with: body) as! [String: Any] }
        return last
    }

    private func written(_ action: CommandRunner.OutputLineAction, agent: AgentKind = .codex) throws -> [String: Any] {
        guard case .write(let data) = action else { Issue.record("Expected another history request"); return [:] }
        return try decode(data, agent: agent)
    }

    private func reply(_ exchange: AgentHistoryReader.Exchange, id: Int, result: [String: Any],
                       agent: AgentKind = .codex) throws -> CommandRunner.OutputLineAction {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        return exchange.receive(agent == .codex ? body + Data([10])
            : Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
    }

    private func candidate(_ agent: AgentKind) -> ExternalSessionCandidate {
        ExternalSessionCandidate(sessionID: sourceID, agent: agent, file: root, cwd: "/work/app",
            title: "Imported", firstPrompt: "Hello", startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 2_000), gitBranch: "main", bytes: 0,
            configDirectory: root)
    }

    @Test func codexListsProjectMetadataAcrossPagesWithoutResuming() throws {
        let exchange = AgentHistoryReader.Exchange(agent: .codex, folder: "/work/app", root: root)
        #expect(try decode(exchange.firstMessage)["method"] as? String == "initialize")
        let list = try written(reply(exchange, id: 1, result: [:]))
        #expect(list["method"] as? String == "thread/list")
        let params = try #require(list["params"] as? [String: Any])
        #expect(params["cwd"] as? String == "/work/app")
        #expect(params["useStateDbOnly"] as? Bool == true)
        let next = try written(reply(exchange, id: 2, result: ["data": [
            ["id": sourceID, "cwd": "/work/app", "preview": "Hello", "createdAt": 1_000, "updatedAt": 2_000],
            ["id": forkID, "cwd": "/other", "preview": "Other"]
        ], "nextCursor": "next"]))
        #expect((next["params"] as? [String: Any])?["cursor"] as? String == "next")
        _ = try reply(exchange, id: 3, result: ["data": []])
        let found = try exchange.result.get().candidates
        #expect(found.map(\.sessionID) == [sourceID])
        #expect(found.first?.origin.configDirectory == root.path)
    }

    @Test func codexForksBeforeReadingItsConversation() throws {
        let exchange = AgentHistoryReader.Exchange(agent: .codex, folder: "/work/app", root: root,
                                                    candidate: candidate(.codex))
        _ = exchange.firstMessage
        let fork = try written(reply(exchange, id: 1, result: [:]))
        #expect(fork["method"] as? String == "thread/fork")
        #expect((fork["params"] as? [String: Any])?["threadId"] as? String == sourceID)
        let read = try written(reply(exchange, id: 2, result: ["thread": ["id": forkID]]))
        #expect(read["method"] as? String == "thread/turns/list")
        #expect((read["params"] as? [String: Any])?["threadId"] as? String == forkID)
        let turn: [String: Any] = ["startedAt": 1_000, "completedAt": 1_010, "items": [
            ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "List files"]]],
            ["id": "a", "type": "agentMessage", "text": "Looking"],
            ["id": "t", "type": "commandExecution", "command": "ls", "aggregatedOutput": "one.swift", "exitCode": 0],
        ]]
        let page = try written(reply(exchange, id: 3, result: ["data": [turn], "nextCursor": "older"]))
        #expect((page["params"] as? [String: Any])?["cursor"] as? String == "older")
        _ = try reply(exchange, id: 4, result: ["data": []])
        let reading = try exchange.result.get()
        #expect(reading.resumeID == forkID)
        #expect(reading.messages.map(\.text) == ["List files", "Looking"])
        #expect(reading.messages.last?.tools.first?.result == "one.swift")
        #expect(reading.messages.first?.date == Date(timeIntervalSince1970: 1_000))
    }

    @Test func copilotListsLocalSessionsAndForksWithoutOpeningTheSource() throws {
        let listing = AgentHistoryReader.Exchange(agent: .copilot, folder: "/work/app", root: root)
        #expect(try decode(listing.firstMessage, agent: .copilot)["method"] as? String == "sessions.list")
        _ = try reply(listing, id: 1, result: ["sessions": [
            ["sessionId": sourceID, "context": ["cwd": "/work/app", "branch": "feature"],
             "name": "Named", "isRemote": false, "modifiedTime": "2026-10-01T10:00:00Z"],
            ["sessionId": forkID, "context": ["cwd": "/work/app"], "name": "Remote", "isRemote": true],
        ]], agent: .copilot)
        #expect(try listing.result.get().candidates.map(\.sessionID) == [sourceID])
        let exchange = AgentHistoryReader.Exchange(agent: .copilot, folder: "/work/app", root: root,
                                                    candidate: candidate(.copilot))
        #expect(try decode(exchange.firstMessage, agent: .copilot)["method"] as? String == "sessions.fork")
        _ = try reply(exchange, id: 1, result: ["sessionId": forkID], agent: .copilot)
        #expect(try exchange.result.get().resumeID == forkID)
    }

    @Test func refusesAForkThatReusesTheOriginalID() throws {
        let exchange = AgentHistoryReader.Exchange(agent: .copilot, folder: "/work/app", root: root,
                                                    candidate: candidate(.copilot))
        _ = exchange.firstMessage
        _ = try reply(exchange, id: 1, result: ["sessionId": sourceID], agent: .copilot)
        #expect(throws: AgentHistoryReader.Failure.self) { try exchange.result.get() }
    }
}
