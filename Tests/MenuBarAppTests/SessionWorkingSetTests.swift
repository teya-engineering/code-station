import Foundation
import Testing
@testable import MenuBarApp

@Suite("Session working set")
struct SessionWorkingSetTests {
    @Test func listsEveryKindOfToolCallAcrossMessagesInOrder() {
        let first = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "read", name: "Read",
                    input: #"{"file_path":"/project/README.md"}"#, result: "contents"),
            ToolUse(id: "edit", name: "Edit",
                    input: #"{"file_path":"/project/Sources/App.swift"}"#, result: "done"),
            ToolUse(id: "shell", name: "Bash",
                    input: #"{"command":"swift test"}"#, result: "passed"),
        ])
        let second = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "agent", name: "Agent",
                    input: #"{"name":"reviewer","description":"review the diff"}"#,
                    result: "done"),
            ToolUse(id: "search", name: "WebSearch",
                    input: #"{"query":"Swift Observation"}"#, result: "results"),
            ToolUse(id: "mcp", name: "MCP", input: "github.search", result: "results"),
            ToolUse(id: "todos", name: "TodoWrite",
                    input: #"{"todos":[{"content":"build"},{"content":"test"}]}"#,
                    result: "done"),
        ])

        let calls = WorkingSetSummary.toolCalls(in: [first, second], activeTools: [],
                                                projectPath: "/project")

        #expect(calls.map(\.title) == [
            "Read · README.md",
            "Edit · Sources/App.swift",
            "Bash · swift test",
            "Agent · reviewer · review the diff",
            "WebSearch · Swift Observation",
            "MCP · github.search",
            "TodoWrite · 2 items",
        ])
        #expect(calls.map(\.tool.id) == [
            "read", "edit", "shell", "agent", "search", "mcp", "todos",
        ])
        #expect(calls[2].tool.result == "passed")
    }

    @Test func mapsRunningCompletedAndFailedToolCalls() {
        let running = ToolUse(id: "running", name: "Read", input: "README.md")
        let completed = ToolUse(id: "completed", name: "Bash", input: "swift test",
                                result: "passed")
        var failed = ToolUse(id: "failed", name: "Bash", input: "swift test",
                             result: "failed")
        failed.isError = true
        var runningWithAnEarlyErrorFlag = ToolUse(id: "running-error", name: "MCP",
                                                  input: "github.search")
        runningWithAnEarlyErrorFlag.isError = true
        let message = ChatMessage(role: .assistant,
                                  tools: [running, completed, failed,
                                          runningWithAnEarlyErrorFlag])

        let calls = WorkingSetSummary.toolCalls(
            in: [message], activeTools: [running, runningWithAnEarlyErrorFlag],
            projectPath: "/project")

        #expect(calls.map(\.state) == [.running, .completed, .failed, .running])
    }

    @Test func marksAnUnresolvedCallInterruptedWhenItIsNoLongerActive() {
        let stopped = ToolUse(id: "stopped", name: "Bash", input: "swift test")
        let message = ChatMessage(role: .assistant, tools: [stopped])

        let calls = WorkingSetSummary.toolCalls(in: [message], activeTools: [],
                                                projectPath: "/project")

        #expect(calls.map(\.state) == [.interrupted])
    }

    @Test func onlyTheNewestUnresolvedOccurrenceOfAnActiveIDIsRunning() {
        let older = ToolUse(id: "reused", name: "Bash", input: "first command")
        let newer = ToolUse(id: "reused", name: "Bash", input: "second command")
        let first = ChatMessage(role: .assistant, tools: [older])
        let second = ChatMessage(role: .assistant, tools: [newer])

        let calls = WorkingSetSummary.toolCalls(in: [first, second], activeTools: [newer],
                                                projectPath: "/project")

        #expect(calls.map(\.title) == ["Bash · first command", "Bash · second command"])
        #expect(calls.map(\.state) == [.interrupted, .running])
    }

    @Test func keepsTheWholeToolCallHistory() {
        let tools = (1...12).map { number in
            ToolUse(id: "raw-\(number)", name: "Tool", input: "target \(number)", result: "done")
        }
        let message = ChatMessage(role: .assistant, tools: tools)

        let calls = WorkingSetSummary.toolCalls(in: [message], activeTools: [],
                                                projectPath: "/project")

        #expect(calls.map(\.title) == (1...12).map { "Tool · target \($0)" })
    }

    @Test func initiallyShowsOnlyTheNewestFiveToolCalls() {
        let calls = toolCalls(8)
        let visibility = WorkingSetToolCallVisibility()

        #expect(visibility.visible(calls).map(\.id) == calls.suffix(5).map(\.id))
    }

    @Test func showingMoreIncludesTheWholeToolCallHistory() {
        let calls = toolCalls(8)
        var visibility = WorkingSetToolCallVisibility()

        visibility.showAll()

        #expect(visibility.visible(calls) == calls)
        #expect(visibility.visible(toolCalls(9)).count == 9)
    }

    @Test func hidingOlderToolCallsRestoresTheLimit() {
        let calls = toolCalls(8)
        var visibility = WorkingSetToolCallVisibility()
        visibility.showAll()

        visibility.hideOlder()

        #expect(visibility.visible(calls).map(\.id) == calls.suffix(5).map(\.id))
    }

    @Test func givesRepeatedRawToolIDsDistinctStableRowIDs() {
        let first = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "reused", name: "Read",
                    input: #"{"file_path":"/project/first"}"#, result: "done"),
        ])
        let second = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "reused", name: "Read",
                    input: #"{"file_path":"/project/second"}"#, result: "done"),
        ])

        let calls = WorkingSetSummary.toolCalls(in: [first, second], activeTools: [],
                                                projectPath: "/project")
        let repeated = WorkingSetSummary.toolCalls(in: [first, second], activeTools: [],
                                                   projectPath: "/project")

        #expect(calls.map(\.title) == ["Read · first", "Read · second"])
        #expect(Set(calls.map(\.id)).count == 2)
        #expect(repeated.map(\.id) == calls.map(\.id))
    }

    @Test @MainActor func openToolDetailsFollowCompletionAndToggleClosed() {
        let runningTool = ToolUse(id: "raw", name: "Bash", input: "swift test")
        let running = WorkingSetToolCall(id: "message\u{0}0",
                                         title: "Bash · swift test",
                                         state: .running,
                                         tool: runningTool)
        let presenter = ToolCallDetailPresenter()
        let anchor = CGRect(x: 20, y: 40, width: 260, height: 50)

        presenter.toggle(running, projectPath: "/project", from: anchor)

        #expect(presenter.current?.call == running)
        #expect(presenter.anchor == anchor)

        let completedTool = ToolUse(id: "raw", name: "Bash", input: "swift test",
                                    result: "passed")
        let completed = WorkingSetToolCall(id: running.id,
                                           title: running.title,
                                           state: .completed,
                                           tool: completedTool)
        presenter.refresh(completed, projectPath: "/project")

        #expect(presenter.current?.call == completed)
        #expect(presenter.generation == 2)

        presenter.toggle(completed, projectPath: "/project", from: anchor)

        #expect(presenter.current == nil)
    }

    @Test func listsEachCollaboratingAgentSeparately() {
        let team = ToolUse(id: "team", name: "Agent",
                           input: #"{"name":"search_east, search_west","description":"waiting"}"#)

        let activities = WorkingSetSummary.activities(
            runningTools: [team], backgroundTasks: [], projectPath: "/project")

        #expect(activities.map(\.title) == ["search_east", "search_west"])
        #expect(activities.map(\.kind) == [.agent, .agent])
    }

    @Test func includesForegroundAgentsAndBackgroundWork() {
        let foreground = ToolUse(id: "reviewer", name: "Task",
                                 input: #"{"subagent_type":"reviewer","description":"review the diff"}"#)
        let backgroundAgent = BackgroundTask(id: "agent", kind: "local_agent",
                                             description: "run tests", agentName: "tester")
        let backgroundCommand = BackgroundTask(id: "server", kind: "local_bash",
                                               description: "npm run dev")
        let ordinaryTool = ToolUse(id: "read", name: "Read", input: "README.md")

        let activities = WorkingSetSummary.activities(
            runningTools: [foreground, ordinaryTool],
            backgroundTasks: [backgroundAgent, backgroundCommand],
            projectPath: "/project")

        #expect(activities.map(\.title) == [
            "reviewer · review the diff", "tester · run tests", "npm run dev",
        ])
        #expect(activities.map(\.kind) == [.agent, .agent, .backgroundTask])
    }

    @Test func visibilityIsRememberedIndependentlyForEachSession() throws {
        let suite = "SessionWorkingSetTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID()
        let second = UUID()

        #expect(Preferences.workingSetVisibility(in: defaults).isEmpty)

        Preferences.setWorkingSetVisible(true, for: first, in: defaults)
        Preferences.setWorkingSetVisible(false, for: second, in: defaults)

        #expect(Preferences.workingSetVisibility(in: defaults) == [first: true, second: false])
    }

    private func toolCalls(_ count: Int) -> [WorkingSetToolCall] {
        (1...count).map { number in
            let tool = ToolUse(id: "raw-\(number)", name: "Tool",
                               input: "target \(number)", result: "done")
            return WorkingSetToolCall(id: "call-\(number)", title: "Tool \(number)",
                                      state: .completed, tool: tool)
        }
    }
}
