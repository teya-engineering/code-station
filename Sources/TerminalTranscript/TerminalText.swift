// Text from agents and files is drawn, never obeyed. An escape sequence in a tool's output
// or a file's diff would otherwise reach the terminal and move the cursor, clear the
// screen or retitle the window, and its bytes would throw every width off. Everything on
// its way to the screen passes through here: the styled text the renderer wraps, every
// row cut with `TerminalColumns.fit`, and every run the theme encodes.
//
// - Escape sequences (CSI, OSC, DCS, SOS, PM, APC and the two-byte ones), in their 7-bit
//   and 8-bit forms, are taken out whole. One left open runs to the end of the text.
// - Other C1 controls are dropped.
// - A carriage return ends a line, so CRLF and a lone CR both become a line break.
// - A tab becomes four spaces, as the wrapper has always drawn it.
// - Any other C0 control and DEL are shown as their Unicode symbols (␇, ␀, ␡, ␛…), so
//   they are seen without being acted on.
// - Newlines stay, for the wrapper to break at.
public enum TerminalText {
    public static func sanitized(_ text: some StringProtocol) -> String {
        guard text.unicodeScalars.contains(where: needsWork) else { return String(text) }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            switch value {
            case 0x1B:
                index = skipEscape(scalars, from: index, into: &out)
                continue
            case 0x9B:
                index = skipCSI(scalars, from: index + 1)
                continue
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
                index = skipString(scalars, from: index + 1)
                continue
            case 0x80...0x9F:
                break
            case 0x0D:
                if index + 1 >= scalars.count || scalars[index + 1].value != 0x0A {
                    out.append("\n")
                }
            case 0x09:
                out.append(contentsOf: "    ".unicodeScalars)
            case 0x0A:
                out.append(scalars[index])
            case 0x00...0x1F:
                out.append(Unicode.Scalar(0x2400 + value)!)
            case 0x7F:
                out.append("\u{2421}")
            default:
                out.append(scalars[index])
            }
            index += 1
        }
        return String(out)
    }

    private static func needsWork(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (value < 0x20 && value != 0x0A) || (0x7F...0x9F).contains(value)
    }

    // An ESC at `start`: the whole sequence it opens is skipped, and the index after it
    // returned. An ESC with nothing after it that could follow it is shown.
    private static func skipEscape(_ scalars: [Unicode.Scalar], from start: Int,
                                   into out: inout String.UnicodeScalarView) -> Int {
        let next = start + 1
        guard next < scalars.count else {
            out.append("\u{241B}")
            return next
        }
        switch scalars[next].value {
        case 0x5B: // [
            return skipCSI(scalars, from: next + 1)
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] P X ^ _
            return skipString(scalars, from: next + 1)
        case 0x20...0x2F:
            // Intermediates, then one final byte.
            var index = next
            while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) { index += 1 }
            if index < scalars.count, (0x30...0x7E).contains(scalars[index].value) { index += 1 }
            return index
        case 0x30...0x7E:
            return next + 1
        default:
            out.append("\u{241B}")
            return next
        }
    }

    // Parameters and intermediates up to a final byte. A byte that cannot be part of the
    // sequence ends it there, so the text after it is kept.
    private static func skipCSI(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if (0x40...0x7E).contains(value) { return index + 1 }
            guard (0x20...0x3F).contains(value) else { return index }
            index += 1
        }
        return index
    }

    // A control string runs to BEL, ST (ESC \ or 0x9C), or the end of the text.
    private static func skipString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            switch scalars[index].value {
            case 0x07, 0x9C: return index + 1
            case 0x1B where index + 1 < scalars.count && scalars[index + 1].value == 0x5C:
                return index + 2
            default: index += 1
            }
        }
        return index
    }
}
