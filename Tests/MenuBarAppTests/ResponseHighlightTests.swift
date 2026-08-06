import SwiftUI
import Testing
@testable import MenuBarApp

// The response colouring works by scanning, so what matters is that a key, a string
// value and a literal land in their own colours and that broken input stays whole.
struct ResponseHighlightTests {

    private func colour(of part: String, in text: String) -> Color? {
        let highlighted = ResponseStyle.highlight(text)
        for run in highlighted.runs {
            if String(highlighted[run.range].characters).contains(part) {
                return run.foregroundColor
            }
        }
        return nil
    }

    @Test func tellsKeysAndStringValuesApart() {
        let json = #"{"status": "captured"}"#
        #expect(colour(of: #""status""#, in: json) == ResponseStyle.key)
        #expect(colour(of: #""captured""#, in: json) == ResponseStyle.string)
    }

    @Test func coloursNumbersAndLiterals() {
        let json = #"{"amount": 1450, "has_more": true, "gone": null}"#
        #expect(colour(of: "1450", in: json) == ResponseStyle.literal)
        #expect(colour(of: "true", in: json) == ResponseStyle.literal)
        #expect(colour(of: "null", in: json) == ResponseStyle.literal)
    }

    // An escaped quote inside a string must not end it early, or everything after is
    // coloured as the wrong thing.
    @Test func survivesEscapedQuotes() {
        let json = #"{"note": "say \"hi\"", "n": 7}"#
        let highlighted = ResponseStyle.highlight(json)
        #expect(String(highlighted.characters) == json)
        #expect(colour(of: "7", in: json) == ResponseStyle.literal)
    }

    @Test func leavesWhatIsNotJSONInOneColour() {
        let html = "<html><body>404</body></html>"
        let highlighted = ResponseStyle.highlight(html)
        #expect(String(highlighted.characters) == html)
        #expect(highlighted.runs.count == 1)
    }

    // Whatever the colouring does, it must never change the text itself.
    @Test func neverAltersTheText() {
        let awkward = #"{"a": "unterminated, "b": -1.5e3, "c": tru"#
        #expect(String(ResponseStyle.highlight(awkward).characters) == awkward)
    }
}
