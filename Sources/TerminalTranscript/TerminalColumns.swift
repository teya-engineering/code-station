// How many terminal columns text takes. East Asian wide characters and emoji take two,
// combining marks and controls none, everything else one. Close to wcwidth, which is
// what terminals themselves follow.
public enum TerminalColumns {
    public static func width(of text: some StringProtocol) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    public static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let scalar = scalars.first else { return 0 }
        // An emoji asked for in its picture form (VS16) is drawn two columns wide.
        if scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.properties.generalCategory {
        case .control, .format, .nonspacingMark, .enclosingMark: return 0
        default: break
        }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    // The text cut to `width` columns, ending in "…" when anything was cut. Line breaks
    // become spaces, since the result is one row. Controls and escape sequences are made
    // safe first (see TerminalText), so the width is what is drawn.
    public static func fit(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        let flat = TerminalText.sanitized(text).replacingOccurrences(of: "\n", with: " ")
        guard Self.width(of: flat) > width else { return flat }
        var out = ""
        var used = 0
        for character in flat {
            let next = Self.width(of: character)
            if used + next > width - 1 { break }
            out.append(character)
            used += next
        }
        return out + "…"
    }

    // The text with spaces after it up to `width` columns.
    public static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(width - Self.width(of: text), 0))
    }
}
