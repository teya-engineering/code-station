import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct JSONFormatTests {
    @Test func indentsAndKeepsKeyOrder() {
        let text = #"{"b":1,"a":{"c":[1,2]},"d":"x"}"#
        #expect(JSONFormat.pretty(text) == """
        {
          "b": 1,
          "a": {
            "c": [
              1,
              2
            ]
          },
          "d": "x"
        }
        """)
    }

    @Test func keepsNumbersAndStringsExactly() {
        let text = #"{"n": 12345678901234567890.10, "s": "a, b: {\"q\"} [ ]"}"#
        #expect(JSONFormat.pretty(text) == """
        {
          "n": 12345678901234567890.10,
          "s": "a, b: {\\"q\\"} [ ]"
        }
        """)
    }

    @Test func keepsEmptyContainersOnOneLine() {
        #expect(JSONFormat.pretty(#"{"a": { }, "b": [ ]}"#) == """
        {
          "a": {},
          "b": []
        }
        """)
    }

    @Test func leavesFormattedTextUnchanged() {
        let text = "{\n  \"a\": [\n    true,\n    null\n  ]\n}"
        #expect(JSONFormat.pretty(text) == text)
    }

    @Test func refusesInvalidJSON() {
        #expect(JSONFormat.pretty(#"{"a": 1,"#) == nil)
        #expect(JSONFormat.pretty("") == nil)
    }
}
