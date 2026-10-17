import Testing
@testable import MenuBarApp

struct OneShotAgentTests {
    // `claude -p --output-format json` prints one result object and no text events.
    @Test func readsTheAnswerOfClaudesSingleJSONResult() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"The gateway timed out.\nOrders was slow."}"#
        #expect(OneShotAgent.collected([line], agent: .claudeCode)
                == "The gateway timed out.\nOrders was slow.")
    }

    @Test func ignoresAResultThatReportsAnError() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529"}"#
        #expect(OneShotAgent.collected([line], agent: .claudeCode) == nil)
    }
}
