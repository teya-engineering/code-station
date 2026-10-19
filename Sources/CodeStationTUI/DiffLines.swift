import CodeStationCore
import TerminalTranscript

// A unified diff drawn for the terminal, one row per line as `git diff` prints it, or,
// once the pane is wide enough for two readable columns, side by side as the GUI's
// comparison view: the old file on the left, the new on the right, each line with its
// number, and a line taken out sharing a row with the line put in its place. Lines are
// cut at the edge rather than wrapped, so a line of code stays one row.
enum DiffLines {
    // Below this many columns each side would be too narrow to read, so the diff stays
    // unified.
    static let sideBySideWidth = 120

    static func draw(_ lines: [RemoteDiffLine], width: Int, theme: TranscriptTheme) -> [String] {
        guard width >= sideBySideWidth else { return lines.map { unified($0, width: width, theme: theme) } }
        return rows(lines).map { sideBySide($0, width: width, theme: theme) }
    }

    private static func unified(_ line: RemoteDiffLine, width: Int, theme: TranscriptTheme) -> String {
        let text = TerminalColumns.fit(" " + line.text, to: width)
        switch line.kind {
        case .addition: return theme.encode(StyledLine([Span(text, .added)]))
        case .deletion: return theme.encode(StyledLine([Span(text, .removed)]))
        case .hunk: return theme.encode(StyledLine([Span(text, .tool)]))
        case .meta: return theme.encode(StyledLine([Span(text, .notice)]))
        case .section: return Style.bold + text + Style.reset
        case .context: return text
        }
    }

    // MARK: - Side by side

    // One row of the comparison: a line that spans both sides (a hunk header, a file
    // heading), or a cell on each side, either of which can be empty.
    enum Row: Equatable {
        case across(RemoteDiffLine)
        case pair(left: Cell?, right: Cell?)
    }

    struct Cell: Equatable {
        let number: Int
        let line: RemoteDiffLine
    }

    // Lines taken out and put in, in one run, are paired off in order; the longer side's
    // remainder faces empty cells. Numbers come from each hunk header.
    static func rows(_ lines: [RemoteDiffLine]) -> [Row] {
        var rows: [Row] = []
        var old = 1, new = 1
        var removed: [RemoteDiffLine] = [], added: [RemoteDiffLine] = []
        func flush() {
            for offset in 0..<max(removed.count, added.count) {
                let left = offset < removed.count ? Cell(number: old + offset, line: removed[offset]) : nil
                let right = offset < added.count ? Cell(number: new + offset, line: added[offset]) : nil
                rows.append(.pair(left: left, right: right))
            }
            old += removed.count
            new += added.count
            removed = []
            added = []
        }
        for line in lines {
            switch line.kind {
            case .deletion: removed.append(line)
            case .addition: added.append(line)
            case .context:
                flush()
                rows.append(.pair(left: Cell(number: old, line: line), right: Cell(number: new, line: line)))
                old += 1
                new += 1
            case .hunk:
                flush()
                if let start = hunkStart(line.text) { (old, new) = start }
                rows.append(.across(line))
            case .meta, .section:
                flush()
                rows.append(.across(line))
            }
        }
        flush()
        return rows
    }

    // "@@ -12,4 +12,6 @@ func name" gives 12 and 12.
    private static func hunkStart(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
              let new = Int(parts[2].dropFirst().split(separator: ",")[0]) else { return nil }
        return (old, new)
    }

    private static func sideBySide(_ row: Row, width: Int, theme: TranscriptTheme) -> String {
        switch row {
        case .across(let line):
            return unified(line, width: width, theme: theme)
        case .pair(let left, let right):
            let side = (width - 1) / 2
            return cell(left, width: side, theme: theme) + Style.dim + "│" + Style.reset
                + cell(right, width: width - 1 - side, theme: theme)
        }
    }

    private static func cell(_ cell: Cell?, width: Int, theme: TranscriptTheme) -> String {
        guard let cell else { return String(repeating: " ", count: max(width, 0)) }
        let number = String(cell.number)
        let gutter = String(repeating: " ", count: max(5 - number.count, 1)) + number + " "
        let text = TerminalColumns.pad(TerminalColumns.fit(cell.line.text, to: max(width - gutter.count, 1)),
                                       to: max(width - gutter.count, 1))
        let style: LineStyle = switch cell.line.kind {
        case .addition: .added
        case .deletion: .removed
        default: .plain
        }
        return Style.dim + gutter + Style.reset + theme.encode(StyledLine([Span(text, style)]))
    }
}
