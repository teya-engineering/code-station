import Foundation
import Testing
@testable import MenuBarApp

// The menu that promotes what the agent just ran has to read both shapes a shell call
// arrives in, since the two CLIs file the same call differently.
@MainActor
struct SessionShortcutsTests {
    @Test func readsAClaudeShellCall() {
        let session = session(with: [
            ToolUse(id: "1", name: "Read", input: #"{"file_path":"a.swift"}"#, result: ""),
            ToolUse(id: "2", name: "Bash",
                    input: #"{"command":"npm run test:unit -- billing"}"#, result: "")
        ])

        #expect(SessionShortcuts.lastAgentCommand(in: session)
            == "npm run test:unit -- billing")
    }

    // Codex hands the command over on its own rather than wrapped in JSON.
    @Test func readsACodexShellCall() {
        let session = session(with: [
            ToolUse(id: "1", name: "Bash", input: "swift build", result: "")
        ])

        #expect(SessionShortcuts.lastAgentCommand(in: session) == "swift build")
    }

    // A chip names one thing, so a script pasted into a call is not offered as one.
    @Test func skipsCommandsThatSpanSeveralLines() {
        let session = session(with: [
            ToolUse(id: "1", name: "Bash", input: "make build", result: ""),
            ToolUse(id: "2", name: "Bash", input: "cat <<EOF\nhello\nEOF", result: "")
        ])

        #expect(SessionShortcuts.lastAgentCommand(in: session) == "make build")
    }

    @Test func findsNothingInASessionThatHasRunNoCommands() {
        #expect(SessionShortcuts.lastAgentCommand(in: session(with: [])) == nil)
    }

    private func session(with tools: [ToolUse]) -> ChatSession {
        var session = ChatSession(projectID: UUID(), agent: .claudeCode)
        session.messages = [
            ChatMessage(role: .user, text: "Split the billing worker."),
            ChatMessage(role: .assistant, text: "Working on it.", tools: tools)
        ]
        return session
    }
}
