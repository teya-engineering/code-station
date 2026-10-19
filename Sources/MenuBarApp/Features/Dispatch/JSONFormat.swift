import Foundation
import CodeStationCore

enum JSONFormat {
    // Re-indents the text rather than parsing and writing it back out, so the keys stay in
    // the order they were typed and numbers keep their exact digits. JSONSerialization
    // would reorder an object's keys and could round a long number.
    static func pretty(_ text: String, indent: String = "  ") -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return nil }

        let chars = Array(text)
        var out = ""
        var depth = 0
        var i = 0

        func newline() {
            out.append("\n")
            out.append(String(repeating: indent, count: depth))
        }

        func nextSignificant(after index: Int) -> Character? {
            var j = index + 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            return j < chars.count ? chars[j] : nil
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                var j = i + 1
                while j < chars.count, chars[j] != "\"" {
                    j += chars[j] == "\\" ? 2 : 1
                }
                out.append(contentsOf: chars[i...min(j, chars.count - 1)])
                i = j + 1
                continue
            case "{", "[":
                let close: Character = c == "{" ? "}" : "]"
                if nextSignificant(after: i) == close {
                    out.append(c)
                    out.append(close)
                    // Skip to the closing bracket so it is not written a second time.
                    while chars[i] != close { i += 1 }
                } else {
                    out.append(c)
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(": ")
            default:
                if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return out
    }
}
