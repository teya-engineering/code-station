import TerminalKit
import TerminalTranscript

// What a terminal would show after the bytes the TUI wrote: a grid of cells, each with
// its character and the SGR style it was drawn in. Only the sequences the TUI writes are
// understood (cursor moves, clearing, SGR, private modes and OSC, which draw nothing), so
// a test reads the frame the person would see, not the escape codes that made it.
struct VirtualScreen {
    // How a cell was drawn. Colours keep the form they were written in.
    struct Style: Hashable, Sendable {
        enum Colour: Hashable, Sendable {
            // 30–37 and 90–97 (or 40–47 and 100–107), as the foreground code.
            case basic(Int)
            case palette(Int)
            case rgb(Int, Int, Int)
        }

        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false
        var strikethrough = false
        var foreground: Colour?
        var background: Colour?

        static let plain = Style()
    }

    struct Cell: Equatable {
        var character: Character = " "
        var style: Style = .plain
        // The right half of a wide character, which draws nothing of its own.
        var continuation = false
    }

    private(set) var size: TerminalSize
    private(set) var cells: [[Cell]]
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    private(set) var cursorVisible = true
    private(set) var alternateScreen = false
    private var style = Style.plain
    private var pending: [Character] = []

    init(cols: Int, rows: Int) {
        size = TerminalSize(cols: cols, rows: rows)
        cells = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
    }

    // A new size keeps what fits, as a terminal does before the program repaints.
    mutating func resize(cols: Int, rows: Int) {
        var next = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        for row in 0..<min(rows, size.rows) {
            for col in 0..<min(cols, size.cols) { next[row][col] = cells[row][col] }
        }
        cells = next
        size = TerminalSize(cols: cols, rows: rows)
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    mutating func feed(_ text: String) {
        pending.append(contentsOf: text)
        var index = 0
        while index < pending.count {
            let character = pending[index]
            if character == "\u{1B}" {
                guard let used = escape(at: index) else { break }
                index += used
            } else {
                put(character)
                index += 1
            }
        }
        pending.removeFirst(index)
    }

    // MARK: - Reading

    var lines: [Line] {
        cells.map { row in
            var runs: [Line.Run] = []
            for cell in row where !cell.continuation {
                if let last = runs.last, last.style == cell.style {
                    runs[runs.count - 1].text.append(cell.character)
                } else {
                    runs.append(Line.Run(text: String(cell.character), style: cell.style))
                }
            }
            return Line(runs: runs)
        }
    }

    // One row of the frame.
    struct Line: Equatable, CustomStringConvertible {
        struct Run: Equatable {
            var text: String
            var style: Style
        }

        var runs: [Run]

        // What the row says, without the blank cells after its last character.
        var text: String {
            var out = runs.map(\.text).joined()
            while out.last == " " { out.removeLast() }
            return out
        }

        var description: String { text }

        private var cells: [(Character, Style)] {
            runs.flatMap { run in run.text.map { ($0, run.style) } }
        }

        // How many columns the row has.
        var width: Int { runs.reduce(0) { $0 + $1.text.count } }

        func character(at column: Int) -> Character? {
            let cells = cells
            return column < cells.count ? cells[column].0 : nil
        }

        // The part of the row in those columns, as a region of the frame sees it.
        func columns(_ range: Range<Int>) -> Line {
            let cells = cells
            let lower = min(range.lowerBound, cells.count), upper = min(range.upperBound, cells.count)
            var runs: [Run] = []
            for (character, style) in cells[lower..<upper] {
                if let last = runs.last, last.style == style {
                    runs[runs.count - 1].text.append(character)
                } else {
                    runs.append(Run(text: String(character), style: style))
                }
            }
            return Line(runs: runs)
        }

        // The style of the first cell where `fragment` starts, when the row has it.
        func style(of fragment: String) -> Style? {
            var cells: [(Character, Style)] = []
            for run in runs { cells += run.text.map { ($0, run.style) } }
            let characters = cells.map(\.0)
            let wanted = Array(fragment)
            guard !wanted.isEmpty, characters.count >= wanted.count else { return nil }
            for start in 0...(characters.count - wanted.count)
            where Array(characters[start..<start + wanted.count]) == wanted {
                return cells[start].1
            }
            return nil
        }
    }

    // MARK: - Drawing

    private mutating func put(_ character: Character) {
        switch character {
        case "\r": cursorCol = 0
        case "\n": cursorRow = min(cursorRow + 1, size.rows - 1)
        case "\u{07}": break
        default:
            let width = TerminalColumns.width(of: character)
            guard width > 0 else { return }
            guard cursorRow < size.rows, cursorCol + width <= size.cols else { return }
            cells[cursorRow][cursorCol] = Cell(character: character, style: style)
            if width == 2 {
                cells[cursorRow][cursorCol + 1] = Cell(character: " ", style: style, continuation: true)
            }
            cursorCol += width
        }
    }

    // How many characters the sequence at `index` used, or nil when it is not all here.
    private mutating func escape(at index: Int) -> Int? {
        guard index + 1 < pending.count else { return nil }
        switch pending[index + 1] {
        case "[":
            var end = index + 2
            while end < pending.count, !("@"..."~").contains(pending[end]) { end += 1 }
            guard end < pending.count else { return nil }
            control(String(pending[(index + 2)..<end]), final: pending[end])
            return end - index + 1
        case "]":
            // OSC, ended by BEL or ST. A notification or the clipboard: nothing drawn.
            var end = index + 2
            while end < pending.count {
                if pending[end] == "\u{07}" { return end - index + 1 }
                if pending[end] == "\u{1B}", end + 1 < pending.count, pending[end + 1] == "\\" {
                    return end - index + 2
                }
                end += 1
            }
            return nil
        default:
            return 2
        }
    }

    private mutating func control(_ body: String, final: Character) {
        if body.hasPrefix("?") {
            let modes = body.dropFirst().split(separator: ";").compactMap { Int($0) }
            let on = final == "h"
            for mode in modes {
                if mode == 25 { cursorVisible = on }
                if mode == 1049 { alternateScreen = on }
            }
            return
        }
        let numbers = body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        func number(_ at: Int, _ fallback: Int) -> Int {
            at < numbers.count ? (numbers[at] ?? fallback) : fallback
        }
        switch final {
        case "H", "f":
            cursorRow = min(max(number(0, 1) - 1, 0), size.rows - 1)
            cursorCol = min(max(number(1, 1) - 1, 0), size.cols - 1)
        case "J":
            if number(0, 0) == 2 {
                cells = Array(repeating: Array(repeating: Cell(), count: size.cols), count: size.rows)
            }
        case "K":
            guard cursorRow < size.rows else { return }
            for col in cursorCol..<size.cols { cells[cursorRow][col] = Cell() }
        case "m":
            sgr(numbers.map { $0 ?? 0 })
        default:
            break
        }
    }

    private mutating func sgr(_ codes: [Int]) {
        var codes = codes.isEmpty ? [0] : codes
        while !codes.isEmpty {
            let code = codes.removeFirst()
            switch code {
            case 0: style = .plain
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37, 90...97: style.foreground = .basic(code)
            case 39: style.foreground = nil
            case 40...47, 100...107: style.background = .basic(code - 10)
            case 49: style.background = nil
            case 38, 48:
                let colour: Style.Colour?
                if codes.first == 5, codes.count >= 2 {
                    colour = .palette(codes[1])
                    codes.removeFirst(2)
                } else if codes.first == 2, codes.count >= 4 {
                    colour = .rgb(codes[1], codes[2], codes[3])
                    codes.removeFirst(4)
                } else {
                    colour = nil
                }
                if code == 38 { style.foreground = colour } else { style.background = colour }
            default: break
            }
        }
    }
}
