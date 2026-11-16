import Foundation
import Testing
@testable import MenuBarApp

struct AgentActivitySummaryTests {
    @Test func listsEachCollaboratingAgentSeparately() {
        let team = ToolUse(id: "team", name: "Agent",
                           input: #"{"name":"search_east, search_west","description":"waiting"}"#)
        let message = ChatMessage(role: .assistant, tools: [team])

        let activities = AgentActivitySummary.activities(
            in: [message], activeTools: [team],
            runningAgentIDs: [], projectPath: "/project")

        #expect(activities.map(\.title) == ["search_east", "search_west"])
        #expect(activities.map(\.state) == [.running, .running])
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

        let activities = AgentActivitySummary.activities(
            in: [message], activeTools: [],
            runningAgentIDs: [], projectPath: "/project")

        let activity = try #require(activities.first)
        #expect(activities.count == 1)
        #expect(activity.title == "reviewer · review the diff")
        #expect(activity.state == .completed)
        #expect(activity.actions.map(\.title) == [
            "Read · Sources/App.swift", "Bash · swift test",
        ])
        #expect(activity.actions.map(\.state) == [.completed, .completed])
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

        let activities = AgentActivitySummary.activities(
            in: [message], activeTools: [],
            runningAgentIDs: [], projectPath: "/project")

        #expect(activities.count == 2)
        #expect(activities[0].actions.map(\.tool.id) == ["lead-read"])
        #expect(activities[1].actions.map(\.tool.id) == ["helper-read"])
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

        let activities = AgentActivitySummary.activities(
            in: [message], activeTools: [waiting],
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

        let activities = AgentActivitySummary.activities(
            in: [message], activeTools: [],
            runningAgentIDs: [task.id], projectPath: "/project")

        let activity = try #require(activities.first)
        #expect(activities.count == 1)
        #expect(activity.state == .running)
    }

    @Test func reusedToolIDsKeepTheirHistoryAndOnlyTheNewestCallRuns() {
        let older = ToolUse(id: "reused", name: "Agent", input: #"{"description":"First task"}"#)
        let newer = ToolUse(id: "reused", name: "Agent", input: #"{"description":"Second task"}"#)
        let messages = [ChatMessage(role: .assistant, tools: [older]),
                        ChatMessage(role: .assistant, tools: [newer])]

        let activities = AgentActivitySummary.activities(
            in: messages, activeTools: [newer], runningAgentIDs: [], projectPath: "/project")

        #expect(activities.map(\.title) == ["First task", "Second task"])
        #expect(activities.map(\.state) == [.interrupted, .running])
        #expect(Set(activities.map(\.id)).count == 2)
    }

    @Test func childCallsKeepTheAgentRunningAndCarryFailures() {
        let agent = ToolUse(id: "reviewer", name: "Agent", input: "Review", result: "done")
        let child = ToolUse(id: "read", name: "Read", input: "README.md", parentID: agent.id)
        var message = ChatMessage(role: .assistant, tools: [agent, child])

        let running = AgentActivitySummary.activities(
            in: [message], activeTools: [child], runningAgentIDs: [], projectPath: "/project")
        #expect(running.first?.state == .running)

        message.tools[1].result = "File missing"
        message.tools[1].isError = true
        let failed = AgentActivitySummary.activities(
            in: [message], activeTools: [], runningAgentIDs: [], projectPath: "/project")
        #expect(failed.first?.state == .failed)
    }
}
