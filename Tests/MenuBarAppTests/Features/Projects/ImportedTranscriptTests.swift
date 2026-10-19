import Foundation
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

struct ImportedTranscriptTests {
    private func line(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    @Test func claudeRewindsExcludeAbandonedBranchesAndRepeatedRecords() throws {
        func record(_ role: String, _ id: String, _ parent: String?, _ text: String) throws -> String {
            try line(["type": role, "uuid": id, "parentUuid": parent as Any? ?? NSNull(),
                      "message": ["content": role == "user" ? text as Any : [["type": "text", "text": text]]]])
        }
        let messages = ClaudeTranscriptImport.messages(fromLines: try [
            record("user", "u1", nil, "Start"),
            record("assistant", "a1", "u1", "Ready"),
            record("user", "u2", "a1", "Abandoned"),
            record("assistant", "a2", "u2", "Discarded"),
            record("user", "u3", "a1", "Replacement"),
            record("assistant", "a3", "u3", "Current"),
            record("assistant", "a3", "u3", "Current"),
        ])
        #expect(messages.map(\.text) == ["Start", "Ready", "Replacement", "Current"])
    }

    @Test func copilotImportsToolsAndSkipsSubagentsAndEphemeralDeltas() throws {
        let scratch = ScratchDirectory(prefix: "copilot-transcript")
        let file = scratch.path("events.jsonl")
        let events: [[String: Any]] = [
            ["type": "user.message", "timestamp": "2026-10-01T10:00:00Z", "data": ["content": "Look around"]],
            ["type": "assistant.message_delta", "ephemeral": true, "data": ["deltaContent": "Looking"]],
            ["type": "assistant.message", "data": ["content": "Looking"]],
            ["type": "tool.execution_start", "data": ["toolCallId": "tool", "toolName": "bash", "arguments": ["command": "ls"]]],
            ["type": "tool.execution_complete", "data": ["toolCallId": "tool", "success": true, "result": ["content": "one.swift"]]],
            ["type": "assistant.message", "agentId": "subagent", "data": ["content": "Hidden"]],
            ["type": "assistant.message", "agentId": NSNull(),
             "data": ["content": "One file", "parentToolCallId": NSNull()]],
        ]
        try events.map(line).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let messages = try CopilotTranscriptImport.messages(from: file)
        #expect(messages.map(\.text) == ["Look around", "Looking\n\nOne file"])
        #expect(messages.last?.tools.count == 1)
        #expect(messages.last?.tools.first?.result == "one.swift")
        #expect(messages.last?.tools.first?.textOffset == "Looking".count)
    }
}

@MainActor
struct ImportedSessionRunnerTests {
    @Test(arguments: [AgentKind.claudeCode, .codex, .copilot])
    func importedSessionsUseTheirHistoryDirectoryAndResumeID(agent: AgentKind) async throws {
        let harness = try RunnerHarness(agent: agent, script: """
        IFS= read -r input
        printf '%s\\n' "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" "$COPILOT_HOME" > "$folder/history-roots"
        printf '%s\\n' "$@" > "$folder/arguments"
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"continued"}'
        printf '%s\\n' '{"type":"thread.started","thread_id":"continued"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"OK"}]}}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"OK"}}'
        printf '%s\\n' '{"type":"assistant.message","data":{"content":"OK"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{}}'
        printf '%s\\n' '{"type":"result","sessionId":"continued","exitCode":0,"is_error":false,"result":"OK"}'
        """)
        defer { harness.tearDown() }
        let root = harness.scratch.path("custom-history")
        let candidate = ExternalSessionCandidate(sessionID: "original", agent: agent, file: root,
            cwd: harness.projectURL.path, title: "Imported", firstPrompt: "Start", startedAt: Date(),
            lastActivity: Date(), gitBranch: "main", bytes: 0, configDirectory: root)
        let session = try await harness.store.importSession(.init(candidate: candidate,
            messages: [ChatMessage(role: .user, text: "Start")], resumeID: "imported-fork"),
            into: harness.session.projectID).get()
        harness.runner.send("Continue", sessionID: session.id, store: harness.store)
        #expect(await waitUntil { harness.runner.state(session.id) == .idle })
        let roots = try String(contentsOf: harness.scratch.path("history-roots"), encoding: .utf8)
        let arguments = try String(contentsOf: harness.scratch.path("arguments"), encoding: .utf8)
        let position = try #require([AgentKind.claudeCode, .codex, .copilot].firstIndex(of: agent))
        #expect(roots.components(separatedBy: "\n")[position] == root.path)
        #expect(arguments.contains("imported-fork"))
        #expect(!arguments.contains("original"))
    }
}
