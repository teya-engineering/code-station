import Foundation
import Testing
@testable import MenuBarApp

@Suite("Session working set")
struct SessionWorkingSetTests {
    @Test func listsRegularToolCallsAcrossMessagesInOrder() {
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

        let calls = mainThreadCalls(in: [first, second], activeTools: [],
                                    projectPath: "/project")

        #expect(calls.map(\.title) == [
            "Read · README.md",
            "Edit · Sources/App.swift",
            "Bash · swift test",
            "WebSearch · Swift Observation",
            "MCP · github.search",
            "TodoWrite · 2 items",
        ])
        #expect(calls.map(\.tool.id) == [
            "read", "edit", "shell", "search", "mcp", "todos",
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

        let calls = mainThreadCalls(
            in: [message], activeTools: [running, runningWithAnEarlyErrorFlag],
            projectPath: "/project")

        #expect(calls.map(\.state) == [.running, .completed, .failed, .running])
    }

    @Test func marksAnUnresolvedCallInterruptedWhenItIsNoLongerActive() {
        let stopped = ToolUse(id: "stopped", name: "Bash", input: "swift test")
        let message = ChatMessage(role: .assistant, tools: [stopped])

        let calls = mainThreadCalls(in: [message], activeTools: [],
                                    projectPath: "/project")

        #expect(calls.map(\.state) == [.interrupted])
    }

    @Test func onlyTheNewestUnresolvedOccurrenceOfAnActiveIDIsRunning() {
        let older = ToolUse(id: "reused", name: "Bash", input: "first command")
        let newer = ToolUse(id: "reused", name: "Bash", input: "second command")
        let first = ChatMessage(role: .assistant, tools: [older])
        let second = ChatMessage(role: .assistant, tools: [newer])

        let calls = mainThreadCalls(in: [first, second], activeTools: [newer],
                                    projectPath: "/project")

        #expect(calls.map(\.title) == ["Bash · first command", "Bash · second command"])
        #expect(calls.map(\.state) == [.interrupted, .running])
    }

    @Test func keepsTheWholeToolCallHistory() {
        let tools = (1...12).map { number in
            ToolUse(id: "raw-\(number)", name: "Tool", input: "target \(number)", result: "done")
        }
        let message = ChatMessage(role: .assistant, tools: tools)

        let calls = mainThreadCalls(in: [message], activeTools: [],
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

    @Test func eachToolCallListExpandsIndependently() {
        let calls = toolCalls(8)
        var visibility = WorkingSetToolCallVisibility()

        visibility.showAll(in: "agent-a")

        #expect(visibility.visible(calls, in: "agent-a") == calls)
        #expect(visibility.visible(calls, in: "agent-b").map(\.id)
                == calls.suffix(5).map(\.id))
        #expect(visibility.visible(calls).map(\.id) == calls.suffix(5).map(\.id))

        visibility.hideOlder(in: "agent-a")

        #expect(visibility.visible(calls, in: "agent-a").map(\.id)
                == calls.suffix(5).map(\.id))
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

        let calls = mainThreadCalls(in: [first, second], activeTools: [],
                                    projectPath: "/project")
        let repeated = mainThreadCalls(in: [first, second], activeTools: [],
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
        let message = ChatMessage(role: .assistant, tools: [team])

        let activities = WorkingSetSummary.activities(
            in: [message], activeTools: [team], backgroundTasks: [],
            runningAgentIDs: [], projectPath: "/project")

        #expect(activities.map(\.title) == ["search_east", "search_west"])
        #expect(activities.map(\.kind) == [.agent, .agent])
        #expect(activities.map(\.state) == [.running, .running])
    }

    @Test func includesForegroundAgentsAndBackgroundWork() {
        let foreground = ToolUse(id: "reviewer", name: "Task",
                                 input: #"{"subagent_type":"reviewer","description":"review the diff"}"#)
        let backgroundAgent = BackgroundTask(id: "agent", kind: "local_agent",
                                             description: "run tests", agentName: "tester")
        let backgroundCommand = BackgroundTask(id: "server", kind: "local_bash",
                                               description: "npm run dev")
        let ordinaryTool = ToolUse(id: "read", name: "Read", input: "README.md")
        let message = ChatMessage(role: .assistant, tools: [foreground, ordinaryTool])

        let activities = WorkingSetSummary.activities(
            in: [message], activeTools: [foreground, ordinaryTool],
            backgroundTasks: [backgroundAgent, backgroundCommand],
            runningAgentIDs: ["agent"],
            projectPath: "/project")

        #expect(activities.map(\.title) == [
            "reviewer · review the diff", "tester · run tests", "npm run dev",
        ])
        #expect(activities.map(\.kind) == [.agent, .agent, .backgroundTask])
        #expect(activities.map(\.state) == [.running, .running, .running])
    }

    @Test func completedAgentsPersistWithTheirActionsNestedUnderThem() throws {
        let agent = ToolUse(
            id: "reviewer", name: "Task",
            input: #"{"subagent_type":"reviewer","description":"review the diff"}"#,
            result: "review complete")
        let read = ToolUse(
            id: "read", name: "Read",
            input: #"{"file_path":"/project/Sources/App.swift"}"#,
            result: "contents", parentID: agent.id)
        let shell = ToolUse(
            id: "test", name: "Bash",
            input: #"{"command":"swift test"}"#,
            result: "passed", parentID: agent.id)
        let message = ChatMessage(role: .assistant, tools: [agent, read, shell])

        let activities = WorkingSetSummary.activities(
            in: [message], activeTools: [], backgroundTasks: [],
            runningAgentIDs: [], projectPath: "/project")

        let activity = try #require(activities.first)
        #expect(activities.count == 1)
        #expect(activity.title == "reviewer · review the diff")
        #expect(activity.state == .completed)
        #expect(activity.actions.map(\.title) == [
            "Read · Sources/App.swift", "Bash · swift test",
        ])
        #expect(activity.actions.map(\.state) == [.completed, .completed])
        #expect(mainThreadCalls(in: [message], activeTools: [],
                                projectPath: "/project").isEmpty)
    }

    @Test func actionsStayWithTheAgentThatExecutedThem() throws {
        let lead = ToolUse(id: "lead", name: "Agent", input: "lead", result: "done")
        let helper = ToolUse(id: "helper", name: "Agent", input: "helper", result: "done",
                             parentID: lead.id)
        let leadAction = ToolUse(id: "lead-read", name: "Read", input: "Lead.swift",
                                 result: "done", parentID: lead.id)
        let helperAction = ToolUse(id: "helper-read", name: "Read", input: "Helper.swift",
                                   result: "done", parentID: helper.id)
        let ordinary = ToolUse(id: "root", name: "Bash", input: "swift test", result: "done")
        let message = ChatMessage(
            role: .assistant,
            tools: [lead, helper, leadAction, helperAction, ordinary])

        let activities = WorkingSetSummary.activities(
            in: [message], activeTools: [], backgroundTasks: [],
            runningAgentIDs: [], projectPath: "/project")

        #expect(activities.count == 2)
        #expect(activities[0].actions.map(\.tool.id) == ["lead-read"])
        #expect(activities[1].actions.map(\.tool.id) == ["helper-read"])
        #expect(mainThreadCalls(
            in: [message], activeTools: [], projectPath: "/project").map(\.tool.id) == ["root"])
    }

    @Test func repeatedCollaborationUpdatesKeepOneDurableRowPerAgent() {
        let spawned = ToolUse(
            id: "spawn", name: "Agent",
            input: #"{"name":"east, west","description":"spawned"}"#,
            result: "done")
        let waiting = ToolUse(
            id: "wait", name: "Agent",
            input: #"{"name":"east, west","description":"waiting"}"#)
        let message = ChatMessage(role: .assistant, tools: [spawned, waiting])

        let activities = WorkingSetSummary.activities(
            in: [message], activeTools: [waiting], backgroundTasks: [],
            runningAgentIDs: [], projectPath: "/project")

        #expect(activities.map(\.title) == ["east", "west"])
        #expect(activities.map(\.state) == [.running, .running])
    }

    @Test func aBackgroundAgentUsesItsPersistedRow() throws {
        let receipt = "launched. agentId: af1aa370 (internal)"
        let agent = ToolUse(id: "launch", name: "Agent", input: "reviewer", result: receipt)
        let message = ChatMessage(role: .assistant, tools: [agent])
        let task = BackgroundTask(id: "af1aa370", kind: "local_agent",
                                  description: "review", agentName: "reviewer")

        let activities = WorkingSetSummary.activities(
            in: [message], activeTools: [], backgroundTasks: [task],
            runningAgentIDs: [task.id], projectPath: "/project")

        let activity = try #require(activities.first)
        #expect(activities.count == 1)
        #expect(activity.state == .running)
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

    @Test func agentSpansKeepTheirPlaceBetweenMainThreadCalls() {
        let before = ToolUse(id: "before", name: "Bash",
                             input: #"{"command":"swift build"}"#, result: "done")
        let agent = ToolUse(id: "reviewer", name: "Task",
                            input: #"{"subagent_type":"reviewer","description":"review"}"#,
                            result: "done")
        let action = ToolUse(id: "read", name: "Read",
                             input: #"{"file_path":"/project/App.swift"}"#,
                             result: "done", parentID: agent.id)
        let after = ToolUse(id: "after", name: "Bash",
                            input: #"{"command":"swift test"}"#, result: "done")
        let message = ChatMessage(role: .assistant,
                                  tools: [before, agent, action, after])

        let entries = timeline(in: [message])

        #expect(entries.map(\.title) == [
            "Bash · swift build", "reviewer · review", "Bash · swift test",
        ])
        #expect(spans(in: entries).map { $0.actions.map(\.tool.id) } == [["read"]])
        #expect(WorkingSetSummary.eventCount(in: entries) == 3)
    }

    @Test func tasksTheCLIReportedOnItsOwnLandAtTheEnd() {
        let call = ToolUse(id: "read", name: "Read",
                           input: #"{"file_path":"/project/README.md"}"#, result: "done")
        let task = BackgroundTask(id: "server", kind: "local_bash",
                                  description: "npm run dev")

        let entries = timeline(in: [ChatMessage(role: .assistant, tools: [call])],
                               backgroundTasks: [task])

        #expect(entries.map(\.title) == ["Read · README.md", "npm run dev"])
    }

    @Test func theRunningSetNamesWhatEachAgentIsDoingNow() {
        let agent = ToolUse(id: "explorer", name: "Task",
                            input: #"{"subagent_type":"explorer","description":"explore"}"#)
        let action = ToolUse(id: "read", name: "Read",
                             input: #"{"file_path":"/project/DesignKit.swift"}"#,
                             parentID: agent.id)
        let command = ToolUse(id: "build", name: "Bash",
                              input: #"{"command":"swift build"}"#)
        let task = BackgroundTask(id: "recap", kind: "local_bash",
                                  description: "session recap")
        let message = ChatMessage(role: .assistant, tools: [agent, action, command])

        let running = WorkingSetSummary.running(in: timeline(
            in: [message], activeTools: [agent, action, command],
            backgroundTasks: [task]))

        #expect(running.map(\.title) == [
            "explorer · explore", "Bash · swift build", "session recap",
        ])
        #expect(running.map(\.origin) == [.agent, .mainThread, .backgroundTask])
        #expect(running.map(\.detail) == [
            "now: Read · DesignKit.swift", "main thread", "background task",
        ])
    }

    @Test func finishedWorkIsNotRunning() {
        let agent = ToolUse(id: "reviewer", name: "Task", input: "reviewer", result: "done")
        let command = ToolUse(id: "build", name: "Bash", input: "swift build",
                              result: "done")
        let message = ChatMessage(role: .assistant, tools: [agent, command])

        #expect(WorkingSetSummary.running(in: timeline(in: [message])).isEmpty)
    }

    @Test func changedFilesAreAttributedToTheAgentThatLastWroteThem() {
        let agent = ToolUse(id: "fixer", name: "Task",
                            input: #"{"subagent_type":"fixer","description":"fix"}"#,
                            result: "done")
        let agentEdit = ToolUse(id: "edit-a", name: "Edit",
                                input: #"{"file_path":"/project/Sources/App.swift"}"#,
                                result: "done", parentID: agent.id)
        let mainEdit = ToolUse(id: "edit-b", name: "Write",
                               input: #"{"file_path":"/project/Sources/Theme.swift"}"#,
                               result: "done")
        let read = ToolUse(id: "read", name: "Read",
                           input: #"{"file_path":"/project/Sources/Read.swift"}"#,
                           result: "done")
        let message = ChatMessage(role: .assistant,
                                  tools: [agent, agentEdit, mainEdit, read])

        let written = WorkingSetSummary.attribution(in: timeline(in: [message]),
                                                    projectPath: "/project")

        #expect(written.count == 2)
        #expect(WorkingSetSummary.attributor(of: "Sources/App.swift", in: "/project",
                                             from: written)
                == WorkingSetAttribution(name: "fixer · fix", isAgent: true))
        #expect(WorkingSetSummary.attributor(of: "Sources/Theme.swift", in: "/project",
                                             from: written) == .mainThread)
        // A file nothing wrote is the main loop's, since only edits name a path.
        #expect(WorkingSetSummary.attributor(of: "Sources/Read.swift", in: "/project",
                                             from: written) == .mainThread)
    }

    @Test func aFileEditedTwiceNamesWhoeverWroteItLast() {
        let agent = ToolUse(id: "fixer", name: "Task", input: "fixer", result: "done")
        let agentEdit = ToolUse(id: "edit-a", name: "Edit",
                                input: #"{"file_path":"/project/App.swift"}"#,
                                result: "done", parentID: agent.id)
        let mainEdit = ToolUse(id: "edit-b", name: "Edit",
                               input: #"{"file_path":"/project/App.swift"}"#,
                               result: "done")
        let message = ChatMessage(role: .assistant,
                                  tools: [agent, agentEdit, mainEdit])

        let written = WorkingSetSummary.attribution(in: timeline(in: [message]),
                                                    projectPath: "/project")

        #expect(WorkingSetSummary.attributor(of: "App.swift", in: "/project",
                                             from: written) == .mainThread)
    }

    @Test func aWorktreeCopyIsAttributedThroughTheTailOfItsPath() {
        let edit = ToolUse(id: "edit", name: "Edit",
                           input: #"{"file_path":"/project/Sources/App.swift"}"#,
                           result: "done")
        let agent = ToolUse(id: "fixer", name: "Task",
                            input: #"{"subagent_type":"fixer"}"#, result: "done")
        var owned = edit
        owned.id = "owned"
        owned.parentID = agent.id
        let message = ChatMessage(role: .assistant, tools: [agent, owned])

        let written = WorkingSetSummary.attribution(in: timeline(in: [message]),
                                                    projectPath: "/project")

        #expect(WorkingSetSummary.attributor(of: "Sources/App.swift",
                                             in: "/worktrees/copy", from: written).name
                == "fixer")
    }

    @Test func spansFollowTheirAgentUntilOpenedByHand() {
        var spans = WorkingSetSpanExpansion()

        #expect(spans.isExpanded("agent", running: true))
        #expect(!spans.isExpanded("agent", running: false))

        spans.toggle("agent", running: true)

        // Closed while it ran, it stays closed once the agent has finished.
        #expect(!spans.isExpanded("agent", running: true))
        #expect(!spans.isExpanded("agent", running: false))

        spans.reset()

        #expect(spans.isExpanded("agent", running: true))
    }

    @Test func theTimelineShowsOnlyItsNewestFiveEntriesUntilOpened() {
        let tools = (1...8).map { number in
            ToolUse(id: "raw-\(number)", name: "Tool", input: "target \(number)",
                    result: "done")
        }
        let entries = timeline(in: [ChatMessage(role: .assistant, tools: tools)])
        var visibility = WorkingSetToolCallVisibility()

        #expect(visibility.visible(entries, in: "timeline").map(\.title)
                == (4...8).map { "Tool · target \($0)" })

        visibility.showAll(in: "timeline")

        #expect(visibility.visible(entries, in: "timeline").count == 8)
    }

    @Test func aCallWithoutAStampIsPlacedAtTheTurnItSitsIn() {
        let turn = Date(timeIntervalSince1970: 1_700_000_000)
        let stampedAt = turn.addingTimeInterval(30)
        var stamped = ToolUse(id: "edit", name: "Edit", input: "App.swift", result: "done")
        stamped.startedAt = stampedAt
        let unstamped = ToolUse(id: "read", name: "Read", input: "README.md",
                                result: "done")
        let message = ChatMessage(role: .assistant, tools: [stamped, unstamped],
                                  date: turn)

        let calls = mainThreadCalls(in: [message], activeTools: [],
                                    projectPath: "/project")

        #expect(calls.map(\.startedAt) == [stampedAt, turn])
    }

    private func timeline(in messages: [ChatMessage], activeTools: [ToolUse] = [],
                          backgroundTasks: [BackgroundTask] = [])
        -> [WorkingSetTimelineEntry] {
        WorkingSetSummary.timeline(in: messages, activeTools: activeTools,
                                   backgroundTasks: backgroundTasks,
                                   runningAgentIDs: [], projectPath: "/project")
    }

    // Everything the main loop ran, which is what the timeline shows at its root.
    private func mainThreadCalls(in messages: [ChatMessage], activeTools: [ToolUse],
                                 projectPath: String) -> [WorkingSetToolCall] {
        WorkingSetSummary.timeline(in: messages, activeTools: activeTools,
                                   backgroundTasks: [], runningAgentIDs: [],
                                   projectPath: projectPath)
            .compactMap { entry in
                if case .call(let call) = entry.content { call } else { nil }
            }
    }

    private func spans(in entries: [WorkingSetTimelineEntry]) -> [WorkingSetActivity] {
        entries.compactMap { entry in
            if case .agent(let activity) = entry.content { activity } else { nil }
        }
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
