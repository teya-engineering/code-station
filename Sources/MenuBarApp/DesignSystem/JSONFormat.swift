import Foundation

enum JSONFormat {
    // Re-indents the text rather than parsing and writing it back out, so the keys stay in
    // the order they were typed and numbers keep their exact digits. JSONSerialization
    // would reorder an object's keys and could round a long number. Only whitespace
    // changes, unless trailing commas are asked to go. Shared by Dispatch and the Add MCP
    // server box.
    static func pretty(_ text: String, indent: String = "  ",
                       droppingTrailingCommas: Bool = false) -> String? {
        guard parse(text) != nil else { return nil }
        return layout(text, indent: indent, droppingTrailingCommas: droppingTrailingCommas)
    }

    // The value JSONSerialization reads from the text, or nil. The one place its options
    // are chosen, so the formatter and the MCP import accept exactly the same text.
    static func parse(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    // The layout alone, for a caller that has already parsed the text. Text that does not
    // parse comes out laid out as far as it goes.
    //
    // JSONSerialization accepts a trailing comma, as in [1, 2,]. It is kept by default,
    // on the line it ends, so Dispatch still shows a response exactly as it was sent.
    // The MCP box drops it, since the import reads past it anyway.
    static func layout(_ text: String, indent: String = "  ",
                       droppingTrailingCommas: Bool = false) -> String {
        layout(text, indent: indent, droppingTrailingCommas: droppingTrailingCommas, caret: 0).text
    }

    // The layout, and where a caret at `caret` in the text lands in it: by the same
    // characters, so it stays in the word or value it was in. A caret in whitespace that
    // goes lands before whatever came next.
    static func layout(_ text: String, indent: String = "  ", droppingTrailingCommas: Bool = false,
                       caret: Int) -> (text: String, caret: Int) {
        let units = Array(text.utf16)
        let indentUnits = Array(indent.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count * 2)
        var depth = 0
        // An empty pair is written in one go when its opener is met, so its closer and
        // the whitespace before it are skipped.
        var skipThrough = -1
        var movedCaret: Int?

        func newline() {
            out.append(0x0A)
            for _ in 0..<max(depth, 0) { out.append(contentsOf: indentUnits) }
        }

        func nextSignificant(after index: Int) -> (unit: UInt16, at: Int)? {
            var next = index + 1
            while next < units.count, JSONScanner.isWhitespace(units[next]) { next += 1 }
            return next < units.count ? (units[next], next) : nil
        }

        JSONScanner.forEach(in: units) { token in
            switch token {
            case .string(let range, _):
                if movedCaret == nil, caret < range.upperBound {
                    movedCaret = out.count + max(caret - range.lowerBound, 0)
                }
                out.append(contentsOf: units[range])
            case .unit(let unit, let index):
                guard index > skipThrough else {
                    // A caret inside an empty pair stays between its brackets, which are
                    // the last two units written.
                    if movedCaret == nil, caret <= index { movedCaret = out.count - 1 }
                    return
                }
                if movedCaret == nil, caret <= index { movedCaret = out.count }
                switch unit {
                case JSONScanner.openBrace, JSONScanner.openBracket:
                    let close = JSONScanner.closer(of: unit)
                    if let next = nextSignificant(after: index), next.unit == close {
                        out.append(unit)
                        out.append(close)
                        skipThrough = next.at
                    } else {
                        out.append(unit)
                        depth += 1
                        newline()
                    }
                case JSONScanner.closeBrace, JSONScanner.closeBracket:
                    depth -= 1
                    newline()
                    out.append(unit)
                case JSONScanner.comma:
                    out.append(unit)
                    if let next = nextSignificant(after: index),
                       next.unit == JSONScanner.closeBrace || next.unit == JSONScanner.closeBracket {
                        // The closer's own newline follows, so none is written here.
                        if droppingTrailingCommas { out.removeLast() }
                    } else {
                        newline()
                    }
                case JSONScanner.colon:
                    out.append(unit)
                    out.append(0x20)
                default:
                    if !JSONScanner.isWhitespace(unit) { out.append(unit) }
                }
            }
        }
        return (String(decoding: out, as: UTF16.self), movedCaret ?? out.count)
    }
}
