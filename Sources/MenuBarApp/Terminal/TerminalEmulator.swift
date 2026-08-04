import Foundation

// The eight ANSI colours plus their bright forms. Actual colour values are chosen by
// the view so the terminal sits in the same palette as the rest of the app.
enum TerminalColor: Equatable {
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite

    static func standard(_ index: Int) -> TerminalColor? {
        switch index {
        case 0: .black
        case 1: .red
        case 2: .green
        case 3: .yellow
        case 4: .blue
        case 5: .magenta
        case 6: .cyan
        case 7: .white
        default: nil
        }
    }

    static func bright(_ index: Int) -> TerminalColor? {
        switch index {
        case 0: .brightBlack
        case 1: .brightRed
        case 2: .brightGreen
        case 3: .brightYellow
        case 4: .brightBlue
        case 5: .brightMagenta
        case 6: .brightCyan
        case 7: .brightWhite
        default: nil
        }
    }

    // xterm's 256 colour cube, folded down to the 16 we draw. Close enough for build
    // output, and it keeps the palette consistent.
    static func extended(_ index: Int) -> TerminalColor? {
        if index < 8 { return standard(index) }
        if index < 16 { return bright(index - 8) }
        if index >= 232 { return index < 244 ? .brightBlack : .white }
        let level = (index - 16) % 6
        let base = (index - 16) / 6
        let red = base / 6, green = base % 6
        if red > 2 && green < 2 && level < 2 { return .red }
        if green > 2 && red < 2 && level < 2 { return .green }
        if level > 2 && red < 2 && green < 2 { return .blue }
        if red > 2 && green > 2 { return .yellow }
        if green > 2 && level > 2 { return .cyan }
        if red > 2 && level > 2 { return .magenta }
        return .white
    }
}

struct TerminalStyle: Equatable {
    var color: TerminalColor?
    var background: TerminalColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
}

// A run of characters that share one style; what the view actually draws.
struct TerminalSpan: Identifiable, Equatable {
    let id: Int
    var text: String
    var style: TerminalStyle
}

struct TerminalLine: Identifiable, Equatable {
    let id: Int
    var spans: [TerminalSpan]

    var isEmpty: Bool { spans.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
    var text: String { spans.map(\.text).joined() }
}

// Turns a shell's byte stream into styled lines.
//
// This is a scrollback terminal, not a full screen one: it understands the sequences
// that ordinary command output uses - colours, carriage returns, line erases, cursor
// moves within a line - which covers shells, builds, git and package managers. Full
// screen programs that paint with absolute cursor positions (vim, htop) are not
// emulated; they are the reason the app still opens a real terminal on request.
struct TerminalEmulator {
    // One drawn character and how it looks.
    private struct Cell: Equatable {
        var character: Character
        var style: TerminalStyle
    }

    private var grid: [[Cell]] = [[]]
    private var row = 0
    private var column = 0
    private var style = TerminalStyle()
    private var savedRow = 0
    private var savedColumn = 0

    // Bytes held back because they are the start of a sequence, or of a character that
    // straddles two reads.
    private var pending: [UInt8] = []
    private var revision = 0

    // Old output is dropped rather than kept forever; this is roughly what a terminal
    // keeps in its scrollback.
    private let maximumLines = 5000

    var lineCount: Int { grid.count }

    mutating func reset() {
        grid = [[]]
        row = 0
        column = 0
        style = TerminalStyle()
        pending = []
    }

    // MARK: - Feeding bytes

    mutating func feed(_ data: Data) {
        var bytes = pending + Array(data)
        pending = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == 0x1B {
                guard let consumed = handleEscape(bytes, from: index) else {
                    // The sequence is cut in half by the end of this read; wait for more.
                    pending = Array(bytes[index...])
                    return
                }
                index += consumed
                continue
            }

            switch byte {
            case 0x0A: // newline
                lineFeed()
                index += 1
            case 0x0D: // carriage return
                column = 0
                index += 1
            case 0x08: // backspace
                column = max(0, column - 1)
                index += 1
            case 0x09: // tab
                let next = ((column / 8) + 1) * 8
                while column < next { put(" ") }
                index += 1
            case 0x07: // bell
                index += 1
            default:
                // Decode one character, which may be several bytes.
                guard let (character, size) = decodeCharacter(bytes, from: index) else {
                    pending = Array(bytes[index...])
                    return
                }
                put(character)
                index += size
            }
        }
        bytes = []
        trimScrollback()
    }

    // A multi-byte character can be split across reads, so the length is checked
    // against what the leading byte promises before decoding.
    private func decodeCharacter(_ bytes: [UInt8], from index: Int) -> (Character, Int)? {
        let first = bytes[index]
        let width: Int
        switch first {
        case 0x00...0x7F: width = 1
        case 0xC0...0xDF: width = 2
        case 0xE0...0xEF: width = 3
        case 0xF0...0xF7: width = 4
        default: return (Character(UnicodeScalar(first)), 1) // stray byte, draw it as-is
        }
        guard index + width <= bytes.count else { return nil }
        let slice = Array(bytes[index..<(index + width)])
        guard let text = String(bytes: slice, encoding: .utf8), let character = text.first else {
            return (".", width)
        }
        return (character, width)
    }

    // MARK: - Escape sequences

    // Returns how many bytes were consumed, or nil when the sequence is incomplete.
    private mutating func handleEscape(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start + 1 < bytes.count else { return nil }
        switch bytes[start + 1] {
        case UInt8(ascii: "["):
            return handleCSI(bytes, from: start)
        case UInt8(ascii: "]"):
            return skipOSC(bytes, from: start)
        case UInt8(ascii: "("), UInt8(ascii: ")"):
            // Character set selection; two bytes of payload we do not need.
            return start + 2 < bytes.count ? 3 : nil
        case UInt8(ascii: "7"):
            savedRow = row; savedColumn = column
            return 2
        case UInt8(ascii: "8"):
            row = min(savedRow, grid.count - 1); column = savedColumn
            return 2
        case UInt8(ascii: "="), UInt8(ascii: ">"):
            return 2
        case UInt8(ascii: "M"):
            row = max(0, row - 1)
            return 2
        default:
            return 2
        }
    }

    private mutating func handleCSI(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 2
        var parameters: [UInt8] = []
        // Parameter and intermediate bytes come before the final letter.
        while index < bytes.count, bytes[index] >= 0x20, bytes[index] <= 0x3F {
            parameters.append(bytes[index])
            index += 1
        }
        guard index < bytes.count else { return nil }
        let final = bytes[index]
        let consumed = index - start + 1

        let text = String(decoding: parameters, as: UTF8.self)
        let isPrivate = text.hasPrefix("?")
        let numbers = text.drop { $0 == "?" }
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let first = numbers.first ?? 0

        switch final {
        case UInt8(ascii: "m"):
            applySGR(numbers.isEmpty ? [0] : numbers)
        case UInt8(ascii: "K"):
            eraseInLine(first)
        case UInt8(ascii: "J"):
            eraseInDisplay(first)
        case UInt8(ascii: "C"):
            column += max(first, 1)
        case UInt8(ascii: "D"):
            column = max(0, column - max(first, 1))
        case UInt8(ascii: "G"):
            column = max(0, max(first, 1) - 1)
        case UInt8(ascii: "A"):
            row = max(0, row - max(first, 1))
        case UInt8(ascii: "B"):
            row = min(grid.count - 1, row + max(first, 1))
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            // Absolute positioning belongs to full screen programs; the closest honest
            // thing in a scrollback view is the start of the current line.
            column = numbers.count > 1 ? max(0, numbers[1] - 1) : 0
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            // Mode changes, including the alternate screen buffer. Clearing on the way
            // in stops a full screen program's leftovers from mixing with the shell.
            if isPrivate, first == 1049 || first == 47 { reset() }
        default:
            break
        }
        return consumed
    }

    // Window titles and similar; skipped so they never appear as text.
    private func skipOSC(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 2
        while index < bytes.count {
            if bytes[index] == 0x07 { return index - start + 1 }
            if bytes[index] == 0x1B, index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\") {
                return index - start + 2
            }
            index += 1
        }
        return nil
    }

    private mutating func applySGR(_ codes: [Int]) {
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = TerminalStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 21, 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.color = TerminalColor.standard(code - 30)
            case 39: style.color = nil
            case 40...47: style.background = TerminalColor.standard(code - 40)
            case 49: style.background = nil
            case 90...97: style.color = TerminalColor.bright(code - 90)
            case 100...107: style.background = TerminalColor.bright(code - 100)
            case 38, 48:
                // 38;5;n is a palette colour, 38;2;r;g;b a true colour one.
                guard index + 1 < codes.count else { index = codes.count; break }
                let mode = codes[index + 1]
                let colour: TerminalColor?
                if mode == 5, index + 2 < codes.count {
                    colour = TerminalColor.extended(codes[index + 2])
                    index += 2
                } else if mode == 2, index + 4 < codes.count {
                    colour = TerminalEmulator.nearest(red: codes[index + 2],
                                                      green: codes[index + 3],
                                                      blue: codes[index + 4])
                    index += 4
                } else {
                    colour = nil
                    index = codes.count
                }
                if code == 38 { style.color = colour } else { style.background = colour }
            default:
                break
            }
            index += 1
        }
    }

    private static func nearest(red: Int, green: Int, blue: Int) -> TerminalColor {
        let high = 128
        switch (red > high, green > high, blue > high) {
        case (true, true, true): return .white
        case (true, false, false): return .red
        case (false, true, false): return .green
        case (false, false, true): return .blue
        case (true, true, false): return .yellow
        case (true, false, true): return .magenta
        case (false, true, true): return .cyan
        case (false, false, false): return .brightBlack
        }
    }

    // MARK: - Writing into the grid

    private mutating func put(_ character: Character) {
        while grid.count <= row { grid.append([]) }
        // Writing past the end of a line pads it, which is what a cursor move followed
        // by text does.
        while grid[row].count < column {
            grid[row].append(Cell(character: " ", style: TerminalStyle()))
        }
        let cell = Cell(character: character, style: style)
        if column < grid[row].count {
            grid[row][column] = cell
        } else {
            grid[row].append(cell)
        }
        column += 1
    }

    private mutating func lineFeed() {
        row += 1
        column = 0
        while grid.count <= row { grid.append([]) }
    }

    private mutating func eraseInLine(_ mode: Int) {
        guard row < grid.count else { return }
        switch mode {
        case 0:
            if column < grid[row].count { grid[row].removeSubrange(column...) }
        case 1:
            let blank = Cell(character: " ", style: TerminalStyle())
            for index in 0..<min(column, grid[row].count) { grid[row][index] = blank }
        default:
            grid[row] = []
        }
    }

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            if row < grid.count {
                eraseInLine(0)
                if row + 1 < grid.count { grid.removeSubrange((row + 1)...) }
            }
        case 1:
            for index in 0..<min(row, grid.count) { grid[index] = [] }
            eraseInLine(1)
        default:
            // A full clear starts a new screen; the prompt that follows lands at the top.
            grid = [[]]
            row = 0
            column = 0
        }
    }

    private mutating func trimScrollback() {
        guard grid.count > maximumLines else { return }
        let excess = grid.count - maximumLines
        grid.removeFirst(excess)
        row = max(0, row - excess)
    }

    // MARK: - Reading out

    // Cells are grouped into the longest runs that share a style, so a line of output
    // is a handful of views rather than one per character.
    func lines() -> [TerminalLine] {
        var result: [TerminalLine] = []
        result.reserveCapacity(grid.count)
        for (index, cells) in grid.enumerated() {
            var spans: [TerminalSpan] = []
            var current = ""
            var currentStyle: TerminalStyle?
            for cell in cells {
                if let open = currentStyle, open != cell.style {
                    spans.append(TerminalSpan(id: spans.count, text: current, style: open))
                    current = ""
                }
                currentStyle = cell.style
                current.append(cell.character)
            }
            if let open = currentStyle, !current.isEmpty {
                spans.append(TerminalSpan(id: spans.count, text: current, style: open))
            }
            result.append(TerminalLine(id: index, spans: spans))
        }
        return result
    }
}
