import CodeStationCore

// Markdown in a reply, laid out as terminal lines. It reads the same blocks the GUI's
// chat does (MarkdownBlock and MessageSegment in the app target): fenced code, headings,
// lists, quotes, tables, rules and paragraphs, with inline code, emphasis and links
// inside. A small hand-rolled reader covers what agents write, like the GUI's, and keeps
// the terminal free of a Markdown dependency.
enum TerminalMarkdown {

    enum Block: Equatable {
        // Lines as they were written, breaks kept: agents break lines on purpose.
        case paragraph(String)
        case heading(level: Int, text: String)
        case list([ListItem])
        case quote(String)
        case rule
        case table(header: [String], rows: [[String]])
        // An unclosed fence still reads as code, since a streaming reply is drawn while
        // its block is half written.
        case code(language: String?, text: String)
    }

    struct ListItem: Equatable {
        var depth: Int
        var marker: String
        var text: String
    }

    // MARK: - Lines

    static func lines(_ text: String, width: Int, source: LineSource) -> [StyledLine] {
        var out: [StyledLine] = []
        var codeBlocks = 0
        // Made safe before it is read, so a carriage return breaks a line here as it does
        // everywhere else.
        for block in blocks(TerminalText.sanitized(text)) {
            var blockSource = source
            if case .code = block {
                blockSource.code = codeBlocks
                codeBlocks += 1
            }
            let drawn = lines(for: block, width: width, source: blockSource)
            guard !drawn.isEmpty else { continue }
            if !out.isEmpty { out.append(StyledLine(source: source)) }
            out += drawn
        }
        return out
    }

    private static func lines(for block: Block, width: Int, source: LineSource) -> [StyledLine] {
        func line(_ text: StyledText) -> StyledLine {
            StyledLine(text.spans, source: source)
        }
        switch block {
        case .paragraph(let text):
            return inline(text, base: .plain).wrapped(width: width).map(line)

        case .heading(let level, let text):
            let style = LineStyle.heading(level)
            let plain = StyledText(inline(text, base: style).text, style)
            return plain.wrapped(width: width).map(line)

        case .list(let items):
            return items.flatMap { item -> [StyledLine] in
                let lead = String(repeating: "  ", count: item.depth)
                var marker = StyledText(lead)
                marker.append(item.marker, .listMarker)
                marker.append(" ", .plain)
                let indent = StyledText(String(repeating: " ", count: TerminalColumns.width(of: marker.text)))
                return hanging(inline(item.text, base: .plain), lead: marker, indent: indent, width: width)
                    .map(line)
            }

        case .quote(let text):
            let bar = StyledText("│ ", .quote)
            return hanging(inline(text, base: .plain), lead: bar, indent: bar, width: width).map(line)

        case .rule:
            return [line(StyledText(String(repeating: "─", count: width), .rule))]

        case .table(let header, let rows):
            return table(header: header, rows: rows, width: width).map(line)

        case .code(let language, let text):
            return code(text, language: language, width: width).map(line)
        }
    }

    // Text behind a lead on its first line and an indent on the rest. A lead that leaves
    // less than two columns for text is dropped, since a wide character needs two.
    static func hanging(_ body: StyledText, lead: StyledText, indent: StyledText,
                        width: Int) -> [StyledText] {
        let leadWidth = TerminalColumns.width(of: lead.text)
        guard width - leadWidth >= 2 else { return body.wrapped(width: width) }
        return body.wrapped(width: width - leadWidth).enumerated().map { index, row in
            var out = index == 0 ? lead : indent
            if row.isEmpty { return index == 0 ? lead.trimmingTrailingWhitespace() : StyledText() }
            out.append(row)
            return out
        }
    }

    // MARK: - Code

    // Code keeps its spaces and is cut at the width rather than wrapped at words. It sits
    // two columns in, where there is room, so it reads apart from the prose around it.
    static func code(_ text: String, language: String?, width: Int) -> [StyledText] {
        let indent = width > 4 ? 2 : 0
        return highlighted(text, language: language).broken(width: width - indent).map { row in
            let row = row.trimmingTrailingWhitespace()
            guard indent > 0, !row.isEmpty else { return row }
            var out = StyledText(String(repeating: " ", count: indent))
            out.append(row)
            return out
        }
    }

    // The code with each token in the style of its kind. The core finds the tokens; this
    // is the terminal's colouring step. A block with no language tag, or one too big to
    // colour, stays plain.
    static func highlighted(_ text: String, language tag: String?) -> StyledText {
        let code = TerminalText.sanitized(text)
        guard let language = CodeLanguage(tag: tag), code.utf8.count <= CodeHighlight.sizeLimit else {
            return StyledText(code)
        }
        var out = StyledText()
        for (index, line) in CodeHighlight.lines(of: code, language: language).enumerated() {
            if index > 0 { out.append("\n", .plain) }
            var tokens = line.tokens[...]
            var position = line.text.startIndex
            while position < line.text.endIndex {
                while let token = tokens.first, token.range.upperBound <= position { tokens.removeFirst() }
                let style: LineStyle
                let end: String.Index
                if let token = tokens.first, token.range.lowerBound <= position {
                    style = .syntax(token.kind)
                    end = min(token.range.upperBound, line.text.endIndex)
                } else {
                    style = .plain
                    end = min(tokens.first?.range.lowerBound ?? line.text.endIndex, line.text.endIndex)
                }
                out.append(code[position..<end], style)
                position = end
            }
        }
        return out
    }

    // MARK: - Tables

    // Columns padded to their widest cell, with the header in bold. A table too wide for
    // the screen falls back to one wrapped line per row.
    private static func table(header: [String], rows: [[String]], width: Int) -> [StyledText] {
        let cells = ([header] + rows).map { $0.map { inline($0, base: .plain) } }
        let widths = header.indices.map { column in
            cells.map { TerminalColumns.width(of: $0[column].text) }.max() ?? 0
        }
        let separator = StyledText(" │ ", .rule)
        let total = widths.reduce(0, +) + 3 * max(widths.count - 1, 0)

        func row(_ row: [StyledText], bold: Bool, padded: Bool) -> StyledText {
            var out = StyledText()
            for (column, cell) in row.enumerated() {
                if column > 0 { out.append(separator) }
                var cell = cell
                if bold { cell = StyledText(cell.text, .strong) }
                out.append(cell)
                if padded, column < row.count - 1 {
                    let pad = widths[column] - TerminalColumns.width(of: cell.text)
                    out.append(String(repeating: " ", count: max(pad, 0)), .plain)
                }
            }
            return out.trimmingTrailingWhitespace()
        }

        guard total <= width else {
            return cells.enumerated().flatMap { index, cells in
                row(cells, bold: index == 0, padded: false).wrapped(width: width)
            }
        }
        let rule = StyledText(widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─"), .rule)
        return [row(cells[0], bold: true, padded: true), rule]
            + cells.dropFirst().map { row($0, bold: false, padded: true) }
    }

    // MARK: - Blocks

    static func blocks(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            while let last = paragraph.last, last.allSatisfy(\.isWhitespace) { paragraph.removeLast() }
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = Fence(line), fence.opens {
                flushParagraph()
                var body: [String] = []
                index += 1
                while index < lines.count {
                    if let closing = Fence(lines[index]), fence.isClosed(by: closing) { index += 1; break }
                    body.append(lines[index])
                    index += 1
                }
                while let first = body.first, first.allSatisfy(\.isWhitespace) { body.removeFirst() }
                while let last = body.last, last.allSatisfy(\.isWhitespace) { body.removeLast() }
                if !body.isEmpty { out.append(.code(language: fence.language, text: body.joined(separator: "\n"))) }
            } else if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let level = headingLevel(trimmed) {
                flushParagraph()
                var title = String(trimmed.drop(while: { $0 == "#" }))
                // "## Title ##" closes with hashes that are decoration, not content.
                while title.hasSuffix("#") { title.removeLast() }
                out.append(.heading(level: level, text: title.trimmingCharacters(in: .whitespaces)))
                index += 1
            } else if isRule(trimmed) {
                flushParagraph()
                out.append(.rule)
                index += 1
            } else if trimmed.hasPrefix("|"), index + 1 < lines.count,
                      isSeparator(lines[index + 1], columns: cells(trimmed).count) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(sized(cells(row), to: header.count))
                    index += 1
                }
                out.append(.table(header: header, rows: rows))
            } else if listItem(line) != nil {
                flushParagraph()
                var items: [ListItem] = []
                while index < lines.count {
                    if let item = listItem(lines[index]) {
                        items.append(item)
                    } else if !items.isEmpty, lines[index].hasPrefix("  "),
                              !lines[index].allSatisfy(\.isWhitespace) {
                        // A line indented under an item carries on that item.
                        items[items.count - 1].text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                out.append(.list(items))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoted.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                out.append(.quote(quoted.joined(separator: "\n")))
            } else {
                var kept = line
                while kept.last?.isWhitespace == true { kept.removeLast() }
                paragraph.append(kept)
                index += 1
            }
        }
        flushParagraph()
        return out
    }

    // A run of three or more backticks or tildes, up to three spaces in. Backticks open
    // with an info string whose first word is the language.
    private struct Fence {
        let character: Character
        let count: Int
        let info: String

        init?(_ line: String) {
            let indent = line.prefix { $0 == " " }.count
            guard indent <= 3 else { return nil }
            let rest = line.dropFirst(indent)
            guard let first = rest.first, first == "`" || first == "~" else { return nil }
            let count = rest.prefix { $0 == first }.count
            guard count >= 3 else { return nil }
            character = first
            self.count = count
            info = rest.dropFirst(count).trimmingCharacters(in: .whitespaces)
        }

        var opens: Bool { character == "~" || !info.contains("`") }

        var language: String? {
            info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }

        func isClosed(by other: Fence) -> Bool {
            other.character == character && other.count >= count && other.info.isEmpty
        }
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func cells(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        // A pipe inside a cell arrives escaped; hide it from the split and put it back after.
        let hidden = "\u{0}"
        content = content.replacingOccurrences(of: "\\|", with: hidden)
        return content.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: hidden, with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    // The row of dashes under a header is what makes the pipes above it a table.
    private static func isSeparator(_ line: String, columns: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        let parts = cells(trimmed)
        guard parts.count == columns, !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            var part = Substring(part)
            if part.first == ":" { part = part.dropFirst() }
            if part.last == ":" { part = part.dropLast() }
            return !part.isEmpty && part.allSatisfy { $0 == "-" }
        }
    }

    private static func sized(_ row: [String], to count: Int) -> [String] {
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }

    private static let bullets = ["•", "◦", "▪"]

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " }).count
        let depth = min(indent / 2, bullets.count - 1)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // "* * *" is a rule, not a one-item list.
        guard !isRule(trimmed), let first = trimmed.first else { return nil }
        if "-*+".contains(first), trimmed.dropFirst().first == " " {
            var body = trimmed.dropFirst().drop { $0 == " " }
            var marker = bullets[depth]
            if body.hasPrefix("[ ] ") {
                marker = "☐"
                body = body.dropFirst(4)
            } else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                marker = "☑"
                body = body.dropFirst(4)
            }
            return ListItem(depth: depth, marker: marker, text: String(body))
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
        return ListItem(depth: depth, marker: String(digits) + String(dot),
                        text: String(after.dropFirst().drop { $0 == " " }))
    }

    // MARK: - Inline

    private struct Emphasis {
        var strong = false
        var emphasis = false
        var struck = false

        func style(over base: LineStyle) -> LineStyle {
            if strong && emphasis { return .strongEmphasis }
            if strong { return .strong }
            if emphasis { return .emphasis }
            if struck { return .strikethrough }
            return base
        }
    }

    // Inline code, emphasis, strikethrough and links, with their markers taken out.
    // A marker that opens nothing stays as it was written.
    static func inline(_ text: String, base: LineStyle) -> StyledText {
        var out = StyledText()
        let characters = Array(text)
        parse(characters, characters.indices, Emphasis(), base: base, into: &out)
        return out
    }

    private static func parse(_ chars: [Character], _ range: Range<Int>, _ emphasis: Emphasis,
                              base: LineStyle, into out: inout StyledText) {
        let end = range.upperBound
        var index = range.lowerBound

        func run(of character: Character, at position: Int) -> Int {
            var count = 0
            while position + count < end, chars[position + count] == character { count += 1 }
            return count
        }

        while index < end {
            let character = chars[index]

            // An escaped marker is the marker itself.
            if character == "\\", index + 1 < end, chars[index + 1].isASCII, chars[index + 1].isPunctuation
                || chars[index + 1].isSymbol {
                out.append(String(chars[index + 1]), emphasis.style(over: base))
                index += 2
                continue
            }

            if character == "`" {
                let count = run(of: "`", at: index)
                if let close = closingTicks(chars, count: count, from: index + count, end: end) {
                    var content = chars[(index + count)..<close]
                    if content.count >= 2, content.first == " ", content.last == " ",
                       !content.allSatisfy({ $0 == " " }) {
                        content = content.dropFirst().dropLast()
                    }
                    out.append(String(content).replacingOccurrences(of: "\n", with: " "), .code)
                    index = close + count
                } else {
                    out.append(String(repeating: "`", count: count), emphasis.style(over: base))
                    index += count
                }
                continue
            }

            if character == "*" || character == "_" {
                let count = run(of: character, at: index)
                var matched = false
                for length in stride(from: min(count, 3), through: 1, by: -1) {
                    guard canOpen(chars, at: index, length: length, run: count, end: end, range: range),
                          let close = closing(chars, character, length: length, from: index + length,
                                              end: end, range: range) else { continue }
                    // The markers beyond the ones that matched are text.
                    if count > length {
                        out.append(String(repeating: character, count: count - length), emphasis.style(over: base))
                    }
                    var inner = emphasis
                    if length >= 2 { inner.strong = true }
                    if length != 2 { inner.emphasis = true }
                    parse(chars, (index + count)..<close, inner, base: base, into: &out)
                    index = close + length
                    matched = true
                    break
                }
                if !matched {
                    out.append(String(repeating: character, count: count), emphasis.style(over: base))
                    index += count
                }
                continue
            }

            if character == "~", run(of: "~", at: index) == 2, index + 2 < end, !chars[index + 2].isWhitespace,
               let close = closingPair(chars, "~", from: index + 2, end: end) {
                var inner = emphasis
                inner.struck = true
                parse(chars, (index + 2)..<close, inner, base: base, into: &out)
                index = close + 2
                continue
            }

            if character == "[" || (character == "!" && index + 1 < end && chars[index + 1] == "["),
               let link = link(chars, at: character == "!" ? index + 1 : index, end: end) {
                let label = link.label.isEmpty ? (character == "!" ? "image" : link.target) : link.label
                out.append(label, .link)
                if link.target != label, !link.target.isEmpty {
                    out.append(" (\(link.target))", .linkTarget)
                }
                index = link.end
                continue
            }

            if character == "<", let close = chars[index..<end].firstIndex(of: ">") {
                let inside = String(chars[(index + 1)..<close])
                if isURL(inside), !inside.contains(" ") {
                    out.append(inside, .link)
                    index = close + 1
                    continue
                }
            }

            if character == "h", index == range.lowerBound || !(chars[index - 1].isLetter || chars[index - 1].isNumber),
               let length = bareURL(chars, at: index, end: end) {
                out.append(String(chars[index..<(index + length)]), .link)
                index += length
                continue
            }

            out.append(String(character), emphasis.style(over: base))
            index += 1
        }
    }

    private static func closingTicks(_ chars: [Character], count: Int, from start: Int, end: Int) -> Int? {
        var index = start
        while index < end {
            guard chars[index] == "`" else { index += 1; continue }
            var length = 0
            while index + length < end, chars[index + length] == "`" { length += 1 }
            if length == count { return index }
            index += length
        }
        return nil
    }

    private static func canOpen(_ chars: [Character], at index: Int, length: Int, run: Int, end: Int,
                                range: Range<Int>) -> Bool {
        let after = index + run
        guard after < end, !chars[after].isWhitespace else { return false }
        // An underscore inside a word, as in snake_case, is part of the word.
        if chars[index] == "_", index > range.lowerBound,
           chars[index - 1].isLetter || chars[index - 1].isNumber { return false }
        return true
    }

    // Where the markers that close a run of `length` start: the end of a later run at
    // least that long, with no space just inside it.
    private static func closing(_ chars: [Character], _ character: Character, length: Int, from start: Int,
                                end: Int, range: Range<Int>) -> Int? {
        var index = start
        while index < end {
            if chars[index] == "`", let close = closingTicks(chars, count: 1, from: index + 1, end: end) {
                index = close + 1
                continue
            }
            guard chars[index] == character else { index += 1; continue }
            var count = 0
            while index + count < end, chars[index + count] == character { count += 1 }
            let close = index + count - length
            if count >= length, close > start,
               !chars[close - 1].isWhitespace,
               character != "_" || index + count >= end
                || !(chars[index + count].isLetter || chars[index + count].isNumber) {
                return close
            }
            index += count
        }
        return nil
    }

    private static func closingPair(_ chars: [Character], _ character: Character, from start: Int,
                                    end: Int) -> Int? {
        var index = start + 1
        while index + 1 < end {
            if chars[index] == character, chars[index + 1] == character, !chars[index - 1].isWhitespace {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func link(_ chars: [Character], at open: Int, end: Int)
        -> (label: String, target: String, end: Int)? {
        var depth = 0
        var index = open
        var labelEnd: Int?
        while index < end {
            if chars[index] == "[" { depth += 1 }
            if chars[index] == "]" {
                depth -= 1
                if depth == 0 { labelEnd = index; break }
            }
            index += 1
        }
        guard let labelEnd, labelEnd + 1 < end, chars[labelEnd + 1] == "(" else { return nil }
        var parens = 0
        index = labelEnd + 1
        var targetEnd: Int?
        while index < end {
            if chars[index] == "(" { parens += 1 }
            if chars[index] == ")" {
                parens -= 1
                if parens == 0 { targetEnd = index; break }
            }
            if chars[index] == "\n" { return nil }
            index += 1
        }
        guard let targetEnd else { return nil }
        let label = inline(String(chars[(open + 1)..<labelEnd]), base: .plain).text
        var target = String(chars[(labelEnd + 2)..<targetEnd]).trimmingCharacters(in: .whitespaces)
        // A title after the address is for a tooltip, which a terminal does not have.
        if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        return (label, target, targetEnd + 1)
    }

    private static func isURL(_ text: String) -> Bool {
        text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("mailto:")
    }

    // The length of a web address starting here, without the punctuation that ends the
    // sentence it sits in.
    private static func bareURL(_ chars: [Character], at index: Int, end: Int) -> Int? {
        let rest = chars[index..<min(index + 8, end)]
        guard String(rest).hasPrefix("http://") || String(rest).hasPrefix("https://") else { return nil }
        var length = 0
        while index + length < end, !chars[index + length].isWhitespace { length += 1 }
        let opened = chars[index..<(index + length)].filter { $0 == "(" }.count
        while length > 0 {
            let last = chars[index + length - 1]
            if ".,;:!?'\"".contains(last) { length -= 1; continue }
            if last == ")" {
                let closed = chars[index..<(index + length)].filter { $0 == ")" }.count
                if closed > opened { length -= 1; continue }
            }
            break
        }
        let scheme = String(chars[index..<(index + length)]).hasPrefix("https://") ? 8 : 7
        return length > scheme ? length : nil
    }
}
