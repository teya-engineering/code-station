// Text where every character carries its style, so it can be wrapped like plain text
// and turned back into runs afterwards. Markdown, highlighted code and plain prose all
// pass through here on their way to lines.
struct StyledText {
    struct Cell {
        var character: Character
        var style: LineStyle
    }

    var cells: [Cell]

    init(_ cells: [Cell] = []) {
        self.cells = cells
    }

    // Text is made safe to draw on the way in (see TerminalText), so every width the
    // wrapper counts is a width the terminal draws.
    init(_ text: some StringProtocol, _ style: LineStyle = .plain) {
        cells = TerminalText.sanitized(text).map { Cell(character: $0, style: style) }
    }

    var isEmpty: Bool { cells.isEmpty }

    var text: String { String(cells.map(\.character)) }

    mutating func append(_ text: some StringProtocol, _ style: LineStyle) {
        cells += TerminalText.sanitized(text).map { Cell(character: $0, style: style) }
    }

    mutating func append(_ other: StyledText) {
        cells += other.cells
    }

    // Neighbouring characters of one style joined into a run.
    var spans: [Span] {
        var out: [Span] = []
        for cell in cells {
            if let last = out.last, last.style == cell.style {
                out[out.count - 1].text.append(cell.character)
            } else {
                out.append(Span(String(cell.character), cell.style))
            }
        }
        return out
    }

    // The text split at line breaks.
    var lines: [StyledText] {
        var out: [StyledText] = [StyledText()]
        for cell in cells {
            if cell.character == "\n" { out.append(StyledText()) } else { out[out.count - 1].cells.append(cell) }
        }
        return out
    }

    func trimmingTrailingWhitespace() -> StyledText {
        var copy = self
        while copy.cells.last?.character.isWhitespace == true { copy.cells.removeLast() }
        return copy
    }

    // MARK: - Wrapping

    // Lines at most `width` columns wide. Breaks at spaces, keeps a paragraph's leading
    // indent on its first line, and breaks a word that is wider than a whole line. Blank
    // lines are kept. Tabs are four spaces.
    func wrapped(width: Int) -> [StyledText] {
        let width = max(width, 1)
        return expandingTabs().lines.flatMap { $0.wrappedParagraph(width: width) }
    }

    // Lines cut at exactly `width` columns, with no regard for words, so code keeps every
    // space it had.
    func broken(width: Int) -> [StyledText] {
        let width = max(width, 1)
        return expandingTabs().lines.flatMap { line -> [StyledText] in
            var out: [StyledText] = []
            var current = StyledText()
            var used = 0
            for cell in line.cells {
                let next = TerminalColumns.width(of: cell.character)
                if used + next > width, !current.isEmpty {
                    out.append(current)
                    current = StyledText()
                    used = 0
                }
                current.cells.append(cell)
                used += next
            }
            out.append(current)
            return out
        }
    }

    private func expandingTabs() -> StyledText {
        guard cells.contains(where: { $0.character == "\t" }) else { return self }
        return StyledText(cells.flatMap { cell in
            cell.character == "\t" ? Array(repeating: Cell(character: " ", style: cell.style), count: 4) : [cell]
        })
    }

    private func wrappedParagraph(width: Int) -> [StyledText] {
        let indentCount = cells.prefix { $0.character == " " }.count
        // Each word with the space that came before it, which keeps its style when the
        // two land on the same line.
        var words: [(space: Cell?, word: [Cell])] = []
        var space: Cell?
        var word: [Cell] = []
        for cell in cells {
            if cell.character == " " {
                if !word.isEmpty { words.append((space, word)); word = []; space = nil }
                if space == nil { space = cell }
            } else {
                word.append(cell)
            }
        }
        if !word.isEmpty { words.append((space, word)) }
        guard !words.isEmpty else { return [StyledText()] }

        var out: [StyledText] = []
        var line = StyledText(indentCount < width ? String(repeating: " ", count: indentCount) : "")
        var used = line.cells.count
        var lineHasWord = false

        func place(_ word: ArraySlice<Cell>) {
            var rest = word
            while !rest.isEmpty {
                var chunk: [Cell] = []
                var chunkWidth = 0
                for cell in rest {
                    let next = TerminalColumns.width(of: cell.character)
                    if used + chunkWidth + next > width, !(chunk.isEmpty && used == 0) { break }
                    chunk.append(cell)
                    chunkWidth += next
                }
                if chunk.isEmpty {
                    out.append(line)
                    line = StyledText()
                    used = 0
                    continue
                }
                line.cells += chunk
                used += chunkWidth
                lineHasWord = true
                rest = rest.dropFirst(chunk.count)
                if !rest.isEmpty {
                    out.append(line)
                    line = StyledText()
                    used = 0
                }
            }
        }

        for (space, word) in words {
            let wordWidth = word.reduce(0) { $0 + TerminalColumns.width(of: $1.character) }
            if !lineHasWord {
                if used + wordWidth > width, used > 0, wordWidth <= width {
                    // An indent that leaves no room for the first word is let go.
                    line = StyledText()
                    used = 0
                }
                place(word[...])
            } else if used + 1 + wordWidth <= width {
                line.cells.append(space ?? Cell(character: " ", style: .plain))
                used += 1
                place(word[...])
            } else {
                out.append(line)
                line = StyledText()
                used = 0
                place(word[...])
            }
        }
        out.append(line)
        return out
    }
}
