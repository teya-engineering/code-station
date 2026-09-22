import Testing
@testable import MenuBarApp

// Telling an agent CLI that is too old for the app apart from one that is fine, both
// from the version it reports and from the way it refuses an argument it does not know.
struct AgentVersionTests {

    @Test func aVersionBelowTheMinimumIsOutdated() {
        #expect(AgentKind.claudeCode.isOutdated("2.1.153") == true)
        #expect(AgentKind.codex.isOutdated("0.146.1") == true)
        #expect(AgentKind.copilot.isOutdated("1.0.31") == true)
    }

    @Test func theMinimumAndAnythingNewerIsNot() {
        #expect(AgentKind.claudeCode.isOutdated("2.1.154") == false)
        #expect(AgentKind.codex.isOutdated("0.153.4") == false)
        #expect(AgentKind.copilot.isOutdated("1.0.86") == false)
    }

    @Test func partsAreComparedAsNumbersNotText() {
        #expect(AgentKind.claudeCode.isOutdated("2.1.1000") == false)
        #expect(AgentKind.claudeCode.isOutdated("2.1.99") == true)
        #expect(AgentKind.claudeCode.isOutdated("3.0") == false)
    }

    @Test func aShorterVersionCountsItsMissingPartsAsZero() {
        #expect(AgentKind.copilot.isOutdated("1.0") == true)
        #expect(AgentKind.copilot.isOutdated("2") == nil)
    }

    @Test func aPrereleaseCountsAsTheReleaseItLeadsTo() {
        #expect(AgentKind.codex.isOutdated("0.147.0-alpha.3") == false)
        #expect(AgentKind.codex.isOutdated("0.146.0-alpha.3") == true)
    }

    @Test func anUnreadableVersionIsNeverCalledOutdated() {
        #expect(AgentKind.codex.isOutdated("codex-cli") == nil)
        #expect(AgentKind.codex.isOutdated("") == nil)
        #expect(AgentKind.codex.isOutdated("v0.100.0") == nil)
    }

    @Test func eachCLIsRefusalOfAnUnknownArgumentIsRecognised() {
        #expect(SessionRunner.rejectedArguments("error: unknown option '--prompt-suggestions'"))
        #expect(SessionRunner.rejectedArguments("error: unexpected argument '--approve-for-me' found"))
        #expect(SessionRunner.rejectedArguments(
            "Error loading config.toml: unknown variant `auto_review`, expected `user` or `guardian_subagent`"))
        #expect(SessionRunner.rejectedArguments("error: Invalid command format.\n\nIt looks like your prompt was not quoted"))
    }

    @Test func otherFailuresGetNoUpdateHint() {
        #expect(!SessionRunner.rejectedArguments("Error: No session, task, or name matched 'abc'."))
        #expect(!SessionRunner.rejectedArguments("Claude Code exited with code 1."))
        #expect(!SessionRunner.rejectedArguments(""))
    }
}
