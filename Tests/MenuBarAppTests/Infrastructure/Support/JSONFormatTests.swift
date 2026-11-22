import Foundation
import Testing
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

    @Test func stringsAndNumbersKeepHowTheyWereWritten() {
        let text = #"{ "a" : "x, {y}: \"z\"" , "n":1.50e2,"e":[ ] }"#
        #expect(JSONFormat.pretty(text) == """
        {
          "a": "x, {y}: \\"z\\"",
          "n": 1.50e2,
          "e": []
        }
        """)
    }

    // JSONSerialization accepts trailing commas. Dispatch shows a response as it was
    // sent, so they stay, at the end of their line.
    @Test func trailingCommasAreKeptOnTheirLine() {
        #expect(JSONFormat.pretty(#"{"a":1,"b":[1,2,],}"#) == """
        {
          "a": 1,
          "b": [
            1,
            2,
          ],
        }
        """)
    }

    // VS Code settings often have them, and the MCP box has no use for them.
    @Test func trailingCommasCanBeDropped() {
        #expect(JSONFormat.pretty(#"{"a":1,"b":[1,2,],}"#, droppingTrailingCommas: true) == """
        {
          "a": 1,
          "b": [
            1,
            2
          ]
        }
        """)
    }

    // A quote followed by a combining mark is one Character, but still opens a string.
    @Test func aStringStartingWithACombiningMarkIsKeptWhole() {
        #expect(JSONFormat.pretty("{\"\u{0301}a\":[1]}") == "{\n  \"\u{0301}a\": [\n    1\n  ]\n}")
    }

    // A caret between an empty pair's brackets stays between them, rather than jumping
    // past the closer along with the whitespace that went.
    @Test func aCaretInsideAnEmptyPairStaysInside() {
        for text in [#"{"a": {}}"#, #"{"a": { }}"#, #"{"a": [  ]}"#] {
            let caret = (text as NSString).range(of: #"": "#).upperBound + 1
            let laidOut = JSONFormat.layout(text, caret: caret)
            let pair = (laidOut.text as NSString).range(of: #"": "#).upperBound
            #expect(laidOut.caret == pair + 1, "\(text)")
        }
    }
}
