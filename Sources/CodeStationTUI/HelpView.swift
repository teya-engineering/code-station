import TerminalKit
import TerminalTranscript

// The help overlay: every key the TUI handles, from the binding table, with the screen it
// was opened from first. View state only: where it was opened and how far it is scrolled.
struct HelpView {
    let place: KeyBindings.Place
    private var top = 0

    init(from place: KeyBindings.Place) {
        self.place = place
    }

    // Whether the key scrolled the overlay, closed it, or was not one of its own.
    mutating func handle(_ key: Key, rows: Int) -> Outcome {
        let page = max(rows - 4, 1)
        switch key {
        case .escape, .char("q", []), .char("?", []), .char("?", .shift): return .close
        case .up, .char("k", []): top -= 1
        case .down, .char("j", []): top += 1
        case .pageUp, .char("b", []): top -= page
        case .pageDown, .char(" ", []), .char("f", []): top += page
        case .home, .char("g", []): top = 0
        case .end, .char("G", []): top = 1_000_000
        default: return .ignored
        }
        return .handled
    }

    enum Outcome { case handled, close, ignored }

    private func body(width: Int) -> [String] {
        var lines: [String] = []
        let keyWidth = min(30, max(width / 3, 10))
        for section in KeyBindings.sections(from: place) {
            if !lines.isEmpty { lines.append("") }
            lines.append(Style.bold + TerminalColumns.fit(" " + section.title, to: width) + Style.reset)
            for binding in section.bindings {
                let keys = TerminalColumns.pad(TerminalColumns.fit("   " + binding.keyNames, to: keyWidth),
                                               to: keyWidth)
                lines.append(Style.cyan + keys + Style.reset
                             + TerminalColumns.fit("  " + binding.does, to: max(width - keyWidth, 0)))
            }
        }
        return lines
    }

    mutating func frame(size: TerminalSize) -> [String] {
        let width = max(size.cols, 10)
        let height = max(size.rows - 3, 1)
        let all = body(width: width)
        top = min(max(top, 0), max(all.count - height, 0))
        let shown = Array(all[top..<min(all.count, top + height)])
        let header = Style.bold + TerminalColumns.fit(" Code Station · Keys", to: width) + Style.reset
        let more = top + height < all.count ? " ▼ more below " : ""
        let help = Style.dim
            + TerminalColumns.pad(TerminalColumns.fit(" jk scroll · esc close", to: max(width - TerminalColumns.width(of: more), 1)),
                                  to: width - TerminalColumns.width(of: more))
            + Style.reset + Style.reverse + more + Style.reset
        return [header, ""] + shown + Array(repeating: "", count: max(height - shown.count, 0)) + [help]
    }
}
