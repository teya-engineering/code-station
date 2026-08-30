import Foundation
import Testing
@testable import MenuBarApp

@Suite("Session working set")
struct SessionWorkingSetTests {
    @Test func verificationContainsOnlyRecordedShellCommands() {
        var completed = ToolUse(id: "completed", name: "Bash",
                                input: #"{"command":"swift test --filter URLTests"}"#,
                                result: "12 tests passed")
        completed.isError = false
        let read = ToolUse(id: "read", name: "Read",
                           input: #"{"file_path":"/project/README.md"}"#,
                           result: "contents")
        var failed = ToolUse(id: "failed", name: "Bash",
                             input: #"{"command":"swift test"}"#,
                             result: "1 test failed")
        failed.isError = true
        let running = ToolUse(id: "running", name: "Bash",
                              input: #"{"command":"swift build"}"#)
        let message = ChatMessage(role: .assistant,
                                  tools: [completed, read, failed, running])

        let commands = WorkingSetSummary.verificationCommands(
            in: [message], projectPath: "/project")

        #expect(commands.map(\.id) == ["completed", "failed", "running"])
        #expect(commands.map(\.command) == [
            "swift test --filter URLTests", "swift test", "swift build",
        ])
        #expect(commands.map(\.state) == [.completed, .failed, .running])
    }

    @Test func verificationKeepsTheNewestCommandsWithinItsLimit() {
        let tools = (1...6).map { number in
            ToolUse(id: "\(number)", name: "Bash", input: "command \(number)", result: "done")
        }
        let message = ChatMessage(role: .assistant, tools: tools)

        let commands = WorkingSetSummary.verificationCommands(
            in: [message], projectPath: "/project", limit: 3)

        #expect(commands.map(\.id) == ["4", "5", "6"])
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
