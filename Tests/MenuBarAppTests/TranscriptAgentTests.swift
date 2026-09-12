import Foundation
import Testing
@testable import MenuBarApp

struct TranscriptAgentTests {
    @Test func groupsParallelAgentsWithoutMixingTheirCallsIntoTheMainThread() throws {
        let message = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "before", name: "Read", input: "{}", result: "done"),
            ToolUse(id: "a", name: "Agent", input: "{}"),
            ToolUse(id: "b", name: "Agent", input: "{}"),
            ToolUse(id: "child", name: "Read", input: "{}", parentID: "a"),
            ToolUse(id: "after", name: "Bash", input: "{}")
        ])
        let entries = TranscriptActivityEntry.grouped(message.toolTree)
        #expect(entries.map(\.id) == ["call:before", "agents:a", "call:after"])
        guard case .agents(let agents) = entries[1] else {
            Issue.record("Expected an agent group")
            return
        }
        #expect(agents.map(\.id) == ["a", "b"])
        #expect(agents[0].children.map(\.id) == ["child"])
    }

    @Test func focusesTheContainingGroupForANestedAgent() throws {
        let message = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "lead", name: "Agent", input: "{}"),
            ToolUse(id: "peer", name: "Agent", input: "{}"),
            ToolUse(id: "nested", name: "Agent", input: "{}", parentID: "peer")
        ])
        let agents = activities(message, active: message.tools)
        let nested = try #require(agents.first { $0.sourceTool?.id == "nested" })
        let target = try #require(TranscriptAgents.target(for: nested, in: [message]))
        #expect(target.messageID == message.id)
        #expect(target.toolID == "lead")
    }

    @Test func aHeaderTargetLoadsAnAgentOutsideTheVisibleTranscriptWindow() {
        let messages = (0..<50).map { _ in ChatMessage(role: .assistant) }
        var window = TranscriptWindow(openingPage: 10)
        window.reveal(messages[3].id, in: messages)
        #expect(window.visibleMessages(in: messages).first?.id == messages[3].id)
        window.reveal(messages[49].id, in: messages)
        #expect(window.visibleCount == 47)
    }

    @Test func keepsBackgroundHistoryAndItsFailureReportAfterReload() throws {
        let task = BackgroundTask(id: "task-1", kind: "local_agent", description: "Review the diff",
                                  agentName: "reviewer")
        var message = ChatMessage(role: .assistant, text: "Starting the review.")
        message.recordAgentTask(AgentTaskRecord(task: task))
        #expect(message.tools.first?.textOffset == message.text.count)
        #expect(activities(message, running: [task.id]).first?.state == .running)

        message.recordAgentTask(AgentTaskRecord(task: task, state: .failed,
                                               report: "The repository could not be read.",
                                               finishedAt: Date()))
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(restored.tools.count == 1)
        #expect(restored.tools.first?.agentTask?.report == "The repository could not be read.")
        #expect(activities(restored).first?.state == .failed)
        #expect(TranscriptAgents.summary(activities(restored)) == "1 failed")
    }

    @Test func mergesAnEarlyBackgroundEventWithItsLaunchReceipt() {
        let task = BackgroundTask(id: "abc123", kind: "local_agent", description: "Review")
        let record = AgentTaskRecord(task: task)
        var message = ChatMessage(role: .assistant)
        message.recordAgentTask(record)
        message.tools.append(ToolUse(id: "launch", name: "Agent", input: "{}",
                                     result: "launched. agentId: abc123"))
        message.recordAgentTask(record)
        #expect(message.tools.map(\.id) == ["launch"])
        #expect(activities(message, running: [task.id]).count == 1)
    }

    @Test func attachesTheTaskToItsToolBeforeTheLaunchReceiptArrives() {
        let task = BackgroundTask(id: "task-with-dashes", kind: "local_agent", description: "Review",
                                  toolUseID: "launch")
        var message = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "launch", name: "Agent", input: "{}")
        ])
        message.recordAgentTask(AgentTaskRecord(task: task))
        #expect(message.tools.map(\.id) == ["launch"])
        #expect(message.tools.first?.backgroundAgentID == task.id)
    }

    @Test func keepsTheAgentsOwnNameWhenTheTaskOnlyNamesItsType() {
        let task = BackgroundTask(id: "task-1", kind: "local_agent", description: "Review",
                                  agentName: "general-purpose", toolUseID: "launch")
        var message = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "launch", name: "Agent", input: #"{"name":"angle-a","description":"Review"}"#)
        ])
        message.recordAgentTask(AgentTaskRecord(task: task))
        #expect(activities(message, running: [task.id]).first?.title == "angle-a · Review")
    }

    @Test func doesNotReportSuccessForAnAgentWithoutAnOutcome() {
        let task = BackgroundTask(id: "a", kind: "local_agent", description: "Review")
        var message = ChatMessage(role: .assistant)
        message.recordAgentTask(AgentTaskRecord(task: task))
        #expect(activities(message).first?.state == .interrupted)
        message.recordAgentTask(AgentTaskRecord(task: task, state: .finished))
        #expect(activities(message).first?.state == .finished)
    }

    @Test func summarizesMixedOutcomesAndCountsAgentsApartFromCommands() {
        let message = ChatMessage(role: .assistant, tools: [
            ToolUse(id: "a", name: "Agent", input: "{}"),
            ToolUse(id: "b", name: "Agent", input: "{}", result: "done"),
            ToolUse(id: "c", name: "Agent", input: "{}", result: "failed", isError: true),
            ToolUse(id: "command", name: "Bash", input: "{}")
        ])
        let agents = activities(message, active: message.tools)
        #expect(agents.count == 3)
        #expect(TranscriptAgents.summary(agents) == "1 running · 1 completed · 1 failed")
    }

    private func activities(_ message: ChatMessage, active: [ToolUse] = [],
                            running: Set<String> = []) -> [WorkingSetActivity] {
        WorkingSetSummary.activities(in: [message], activeTools: active, backgroundTasks: [],
                                     runningAgentIDs: running, projectPath: "/project")
    }
}
