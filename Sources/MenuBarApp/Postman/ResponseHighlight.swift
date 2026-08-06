import SwiftUI

// The response body's little terminal: a dark ground with JSON picked out in a few
// colours, so the eye can find a key or a value without reading the whole answer.
enum ResponseStyle {
    static let background = Color(red: 0.086, green: 0.094, blue: 0.102)
    static let base = Color(red: 0.788, green: 0.800, blue: 0.776)
    static let key = Color(red: 0.608, green: 0.773, blue: 0.635)
    static let string = Color(red: 0.878, green: 0.690, blue: 0.290)
    static let literal = Color(red: 0.498, green: 0.690, blue: 0.541)
    static let failure = Color(red: 0.910, green: 0.540, blue: 0.480)

    // Colouring is worth having on an answer a person reads, not on one they scroll
    // past; past this size the plain text is also much cheaper to lay out.
    private static let highlightLimit = 120_000

    // Scans rather than parses, so half an answer or a stray line in the middle keeps
    // its colouring instead of losing it for everything after.
    static func highlight(_ text: String) -> AttributedString {
        guard looksLikeJSON(text), text.utf8.count < highlightLimit else {
            return coloured(text[...], base)
        }

        var result = AttributedString()
        var plain = ""

        func flush() {
            guard !plain.isEmpty else { return }
            result += coloured(plain[...], base)
            plain = ""
        }

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                var j = text.index(after: i)
                while j < text.endIndex, text[j] != "\"" {
                    // A backslash escapes the next character, including a quote.
                    j = text[j] == "\\"
                        ? (text.index(j, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex)
                        : text.index(after: j)
                }
                let end = j < text.endIndex ? text.index(after: j) : j
                // A colon after the closing quote makes the string a key.
                var k = end
                while k < text.endIndex, text[k] == " " { k = text.index(after: k) }
                let isKey = k < text.endIndex && text[k] == ":"
                flush()
                result += coloured(text[i..<end], isKey ? key : string)
                i = end
            } else if c.isNumber || (c == "-" && digitFollows(text, i)) {
                var j = text.index(after: i)
                while j < text.endIndex, "0123456789.eE+-".contains(text[j]) {
                    j = text.index(after: j)
                }
                flush()
                result += coloured(text[i..<j], literal)
                i = j
            } else if c.isLetter {
                var j = text.index(after: i)
                while j < text.endIndex, text[j].isLetter { j = text.index(after: j) }
                let word = text[i..<j]
                flush()
                result += coloured(word, ["true", "false", "null"].contains(String(word)) ? literal : base)
                i = j
            } else {
                plain.append(c)
                i = text.index(after: i)
            }
        }
        flush()
        return result
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        let first = text.first { !$0.isWhitespace }
        return first == "{" || first == "["
    }

    private static func coloured(_ text: Substring, _ colour: Color) -> AttributedString {
        var run = AttributedString(String(text))
        run.foregroundColor = colour
        return run
    }

    private static func digitFollows(_ text: String, _ i: String.Index) -> Bool {
        let next = text.index(after: i)
        return next < text.endIndex && text[next].isNumber
    }
}
