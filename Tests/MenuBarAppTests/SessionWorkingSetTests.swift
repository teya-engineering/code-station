import Foundation
import Testing
@testable import MenuBarApp

@Suite("Session working set")
struct SessionWorkingSetTests {
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
}
