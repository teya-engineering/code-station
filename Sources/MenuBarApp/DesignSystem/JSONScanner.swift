import Foundation

// The one walk over JSON text that the formatter and the MCP box share. It finds where
// strings start and end, and hands over everything outside them a unit at a time, so
// the layout, where the servers are, whether the caret is in a string, and which
// brackets a line left open all agree on it. It counts in UTF-16 units, the way NSString
// and the text views do, so a quote followed by a combining mark is still a quote.
//
// Only straight quotes delimit a string here. Curly ones are put right beforehand by
// JSONPayload.straightened, which has to guess where a string ends and so cannot share
// this walk.
enum JSONScanner {
    static let quote = UInt16(UInt8(ascii: "\""))
    static let backslash = UInt16(UInt8(ascii: "\\"))
    static let openBrace = UInt16(UInt8(ascii: "{"))
    static let closeBrace = UInt16(UInt8(ascii: "}"))
    static let openBracket = UInt16(UInt8(ascii: "["))
    static let closeBracket = UInt16(UInt8(ascii: "]"))
    static let comma = UInt16(UInt8(ascii: ","))
    static let colon = UInt16(UInt8(ascii: ":"))

    enum Token {
        // From the opening quote to just past the closing one, or to the end of the text
        // when the string is left open.
        case string(Range<Int>, closed: Bool)
        // A unit outside any string: a bracket, a comma, a digit, a space.
        case unit(UInt16, at: Int)
    }

    static func forEach(in units: [UInt16], _ body: (Token) -> Void) {
        var index = 0
        while index < units.count {
            let unit = units[index]
            guard unit == quote else {
                body(.unit(unit, at: index))
                index += 1
                continue
            }
            var end = index + 1
            var escaped = false
            while end < units.count {
                if escaped { escaped = false }
                else if units[end] == backslash { escaped = true }
                else if units[end] == quote { break }
                end += 1
            }
            let closed = end < units.count
            let stop = closed ? end + 1 : units.count
            body(.string(index..<stop, closed: closed))
            index = stop
        }
    }

    // The brackets the text opens and leaves open, outermost first, with where each is.
    static func openBrackets(in units: [UInt16]) -> [(unit: UInt16, at: Int)] {
        var open: [(unit: UInt16, at: Int)] = []
        forEach(in: units) { token in
            guard case .unit(let unit, let index) = token else { return }
            switch unit {
            case openBrace, openBracket: open.append((unit, index))
            case closeBrace, closeBracket: if !open.isEmpty { open.removeLast() }
            default: break
            }
        }
        return open
    }

    static func openBrackets(in text: String) -> [UInt16] {
        openBrackets(in: Array(text.utf16)).map(\.unit)
    }

    static func closer(of opener: UInt16) -> UInt16 {
        opener == openBrace ? closeBrace : closeBracket
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        isIndent(unit) || unit == 0x0A || unit == 0x0D
    }

    // The whitespace a line can be indented with: a space or a tab.
    static func isIndent(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09
    }
}
