import Foundation

enum MarkdownEditorMode: String, CaseIterable {
    case edit = "Edit", source = "Source", preview = "Preview"
}

// Source stays authoritative. Only syntax that the editor can express is admitted
// to Edit; everything else remains editable in Source without a lossy conversion.
struct MarkdownWritingDocument {
    let source: String
    let document: NoteDocument
    private let original: Original?

    // The source text behind each block of the document, so an edit rewrites only the
    // blocks it touched and the rest keep their wrapping and spelling exactly.
    private struct Original {
        var generated: [String] = []
        var texts: [String] = []
        // The line breaks before the first block, between each pair, and after the last.
        var gaps: [String] = []
    }

    init(source: String, document: NoteDocument) {
        self.source = source
        self.document = document
        original = Self.parse(source)?.original
    }

    init?(_ source: String) {
        guard let parsed = Self.parse(source) else { return nil }
        self.source = source
        document = parsed.document
        original = parsed.original
    }

    private static func parse(_ source: String) -> (document: NoteDocument, original: Original?)? {
        // "\r\n" is one Character, so look at scalars to find every carriage return.
        guard !source.unicodeScalars.contains("\r") else { return nil }
        let lines = source.components(separatedBy: "\n")
        var reader = Reader(lines: lines)
        // Where the block being read began, and the reader as it was before it. When a line
        // of that block cannot be read, the block is read again as literal source.
        var checkpoint = (line: 0, reader: reader)
        func fallBack() {
            reader = checkpoint.reader
            reader.appendLiteral(checkpoint.line..<Self.literalEnd(from: checkpoint.line, in: lines))
        }
        while true {
            if reader.index == lines.count {
                if reader.close() { break }
                fallBack()
            } else if lines[reader.index].isEmpty {
                if reader.close() { reader.index += 1 } else { fallBack() }
            } else {
                if reader.open == nil { checkpoint = (reader.index, reader) }
                if !reader.readLine() { fallBack() }
            }
        }
        let runs = reader.runs
        let spans = reader.spans
        let document = NoteDocument(runs: Self.normalized(NoteDocument(runs: runs)))
        let generated = document.markdownBlocks.map(\.text)
        guard let first = spans.first, let last = spans.last, generated.count == spans.count else {
            return (document, nil)
        }
        var original = Original(generated: generated)
        original.texts = spans.map { lines[$0].joined(separator: "\n") }
        original.gaps = [String(repeating: "\n", count: first.lowerBound)]
        original.gaps += zip(spans, spans.dropFirst()).map { String(repeating: "\n", count: $1.lowerBound - $0.upperBound + 1) }
        original.gaps.append(String(repeating: "\n", count: lines.count - last.upperBound))
        return (document, original)
    }

    private struct Reader {
        let lines: [String]
        var index = 0
        var runs: [NoteDocument.Run] = []
        // The source lines of each block. Code blocks that follow each other become one
        // block in the editor, so they share one span, and so do literal blocks.
        var spans: [Range<Int>] = []
        var lastMerging: NoteDocument.Block?
        // A paragraph stays open while its lines wrap, and is read as one line of text.
        var open: (block: NoteDocument.Block, marker: String, depth: Int, text: String, lines: Range<Int>)?
        // The start column and text column of each open list item, outermost first.
        var lists: [(start: Int, content: Int)] = []

        mutating func close() -> Bool {
            guard let paragraph = open else { return true }
            open = nil
            guard let inline = MarkdownWritingDocument.inline(paragraph.text, block: paragraph.block) else { return false }
            if !runs.isEmpty { runs.append(.init(text: "\n")) }
            if !paragraph.marker.isEmpty {
                runs.append(.init(text: paragraph.marker, block: paragraph.block, indent: paragraph.depth))
            }
            runs.append(contentsOf: inline.map { var run = $0; run.indent = paragraph.depth; return run })
            spans.append(paragraph.lines)
            lastMerging = nil
            return true
        }

        // Source lines the editor cannot show as formatting stay as they are written.
        mutating func appendLiteral(_ range: Range<Int>) {
            if lastMerging == .literal, let last = spans.last, let run = runs.indices.last {
                spans[spans.count - 1] = last.lowerBound..<range.upperBound
                runs[run].text = lines[spans[spans.count - 1]].joined(separator: "\n")
            } else {
                if !runs.isEmpty { runs.append(.init(text: "\n")) }
                runs.append(.init(text: lines[range].joined(separator: "\n"), block: .literal))
                spans.append(range)
            }
            lastMerging = .literal
            lists = []
            index = range.upperBound
        }

        // Reads the non-empty line at `index`. False when the block it belongs to has
        // syntax the editor cannot show.
        mutating func readLine() -> Bool {
            var line = lines[index]
            let number = index
            index += 1
            if line == "```" {
                guard close() else { return false }
                var code: [String] = []
                while index < lines.count && lines[index] != "```" {
                    code.append(lines[index]); index += 1
                }
                guard index < lines.count, !code.isEmpty else { return false }
                index += 1
                if !runs.isEmpty { runs.append(.init(text: "\n")) }
                runs.append(.init(text: code.joined(separator: "\n"), block: .code))
                if lastMerging == .code, let last = spans.last { spans[spans.count - 1] = last.lowerBound..<index }
                else { spans.append(number..<index) }
                lastMerging = .code
                lists = []
                return true
            }
            let leading = line.prefix(while: { $0 == " " }).count
            line.removeFirst(leading)
            let prefixes: [(String, NoteDocument.Block, String)] = [
                ("### ", .subheading, ""), ("## ", .heading, ""), ("# ", .title, ""),
                ("- [ ] ", .checklist, "☐ "), ("- [x] ", .checklist, "☑ "),
                ("- ", .bullet, "• "), ("> ", .quote, "")
            ]
            var block = NoteDocument.Block.text
            var marker = ""
            if let prefix = prefixes.first(where: { line.hasPrefix($0.0) }) {
                line.removeFirst(prefix.0.count); block = prefix.1; marker = prefix.2
            } else if let range = line.range(of: #"^1\. "#, options: .regularExpression) {
                line.removeSubrange(range); block = .numbered; marker = "1. "
            }
            // Indentation, hard breaks and block extensions carry meaning that a
            // paragraph-only rich editor cannot safely reconstruct.
            guard !line.isEmpty, line == line.trimmingCharacters(in: .whitespaces),
                  !line.contains("\t"), !line.hasPrefix("---"), !line.hasPrefix("==="),
                  !line.hasPrefix("+++"), !line.hasPrefix("~~~"), !line.hasPrefix("```"),
                  !([.title, .heading, .subheading].contains(block)
                    && line.range(of: #"\s+#+$"#, options: .regularExpression) != nil),
                  !([.bullet, .numbered, .checklist, .quote].contains(block) && line.hasPrefix("#")),
                  !(block == .text && line.range(of: #"^(\d+[.)] |[+*>-] |#{1,6}( |$))"#, options: .regularExpression) != nil)
            else { return false }
            // A plain line straight after a paragraph, a list item or a quote carries on
            // that paragraph, as does a quote line after a quote. The wrap reads as a space.
            if let paragraph = open,
               block == .text || block == .quote && paragraph.block == .quote && leading == 0 {
                open?.text += " " + line
                open?.lines = paragraph.lines.lowerBound..<index
                return true
            }
            guard close() else { return false }
            var depth = 0
            if NoteDocument.Block.lists.contains(block) {
                let width = block == .numbered ? 3 : 2
                while let last = lists.last, last.start > leading { lists.removeLast() }
                if let last = lists.last, last.start == leading {
                    lists[lists.count - 1] = (leading, leading + width)
                } else if leading == (lists.last?.content ?? 0) {
                    lists.append((leading, leading + width))
                } else { return false }
                depth = lists.count - 1
            } else {
                // An indented line that does not carry on a paragraph starts indented
                // code, which has no place in the rich editor.
                guard leading == 0 else { return false }
                lists = []
            }
            open = (block, marker, depth, line, number..<index)
            // A heading is one line, so the next line starts a new block.
            if [.title, .heading, .subheading].contains(block) { return close() }
            return true
        }
    }

    // A literal block runs to the next blank line, and a fenced block to its closing
    // fence, so a blank line inside the fence does not split it.
    private static func literalEnd(from start: Int, in lines: [String]) -> Int {
        func fence(_ line: String) -> String? {
            let trimmed = line.drop { $0 == " " }
            guard let mark = trimmed.first, mark == "`" || mark == "~" else { return nil }
            let run = trimmed.prefix { $0 == mark }
            return run.count >= 3 ? String(run) : nil
        }
        var end = start
        var openFence: String?
        while end < lines.count {
            let line = lines[end]
            end += 1
            if let current = openFence {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(current), trimmed.allSatisfy({ $0 == current.first }) {
                    openFence = nil
                    if fence(lines[start]) != nil { break }
                }
            } else if line.isEmpty {
                end -= 1
                break
            } else if let opened = fence(line) {
                openFence = opened
            }
        }
        while end > start + 1, lines[end - 1].isEmpty { end -= 1 }
        return end
    }

    func markdown(afterEditing edited: NoteDocument) -> String {
        // AppKit coalesces adjacent runs, so compare their styled contents, not their
        // incidental run boundaries, before deciding whether anything was edited.
        if Self.normalized(edited) == Self.normalized(document) { return source }
        guard let original else { return edited.markdown + (source.hasSuffix("\n") ? "\n" : "") }
        let blocks = NoteDocument(runs: Self.normalized(edited)).markdownBlocks
        let matches = Self.matches(original.generated, blocks.map(\.text))
        var result = original.gaps[0]
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                if let current = matches[index], let previous = matches[index - 1], current == previous + 1 {
                    result += original.gaps[current]
                } else {
                    result += NoteDocument.separator(blocks[index - 1].block, block.block)
                }
            }
            result += matches[index].map { original.texts[$0] } ?? block.text
        }
        return result + original.gaps[original.gaps.count - 1]
    }

    // For each new block, the unchanged original block it lines up with, found as the
    // longest run of blocks the two versions share in order.
    private static func matches(_ old: [String], _ new: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: new.count)
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { result[head] = head; head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] {
            result[new.count - 1 - tail] = old.count - 1 - tail; tail += 1
        }
        let a = Array(old[head..<(old.count - tail)]), b = Array(new[head..<(new.count - tail)])
        guard !a.isEmpty, !b.isEmpty else { return result }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { result[head + j] = head + i; i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return result
    }

    private static func normalized(_ document: NoteDocument) -> [NoteDocument.Run] {
        var result: [NoteDocument.Run] = []
        for run in document.runs where !run.text.isEmpty {
            if var last = result.last, last.bold == run.bold, last.italic == run.italic,
               last.block == run.block, last.link == run.link, last.code == run.code, last.indent == run.indent {
                last.text += run.text; result[result.count - 1] = last
            } else { result.append(run) }
        }
        return result
    }

    fileprivate static func inline(_ text: String, block: NoteDocument.Block,
                               bold: Bool = false, italic: Bool = false) -> [NoteDocument.Run]? {
        var rest = text[...]
        var runs: [NoteDocument.Run] = []
        while let first = rest.first {
            if first == "\\" {
                rest.removeFirst()
                guard let escaped = rest.first, #"\`*_{}[]<>#!|-+.=~&"#.contains(escaped) else { return nil }
                runs.append(.init(text: String(escaped), bold: bold, italic: italic, block: block))
                rest.removeFirst()
            } else if first == "*" {
                let delimiter = rest.hasPrefix("***") ? "***" : rest.hasPrefix("**") ? "**" : "*"
                rest.removeFirst(delimiter.count)
                guard let end = rest.range(of: delimiter), end.lowerBound != rest.startIndex,
                      rest.first?.isWhitespace == false,
                      rest[rest.index(before: end.lowerBound)].isWhitespace == false,
                      let nested = inline(String(rest[..<end.lowerBound]), block: block,
                                          bold: bold || delimiter.count >= 2, italic: italic || delimiter.count != 2) else { return nil }
                runs += nested; rest = rest[end.upperBound...]
            } else if first == "`" {
                let fence = String(rest.prefix { $0 == "`" })
                rest.removeFirst(fence.count)
                var search = rest.startIndex
                var close: Range<Substring.Index>?
                while let found = rest[search...].range(of: fence) {
                    let longer = found.upperBound < rest.endIndex && rest[found.upperBound] == "`"
                    if !longer { close = found; break }
                    search = rest[found.lowerBound...].firstIndex { $0 != "`" } ?? rest.endIndex
                }
                guard let close, close.lowerBound != rest.startIndex else { return nil }
                var content = String(rest[..<close.lowerBound])
                if content.count > 2, content.hasPrefix(" "), content.hasSuffix(" "),
                   content.contains(where: { $0 != " " }) {
                    content = String(content.dropFirst().dropLast())
                }
                runs.append(.init(text: content, bold: bold, italic: italic, block: block, code: true))
                rest = rest[close.upperBound...]
            } else if first == "[" {
                guard let close = rest.range(of: "]("), let end = rest[close.upperBound...].firstIndex(of: ")") else { return nil }
                let label = String(rest[rest.index(after: rest.startIndex)..<close.lowerBound])
                var destination = String(rest[close.upperBound..<end])
                if destination.hasPrefix("<"), destination.hasSuffix(">") { destination = String(destination.dropFirst().dropLast()) }
                guard let kept = NoteDocument.keptLink(destination),
                      !destination.contains(where: \.isWhitespace),
                      let nested = inline(label, block: block, bold: bold, italic: italic),
                      nested.allSatisfy({ $0.link == nil }) else { return nil }
                runs += nested.map { var run = $0; run.link = kept; return run }
                rest = rest[rest.index(after: end)...]
            } else {
                guard !"_`[]<>!|~&".contains(first) else { return nil }
                let plain = rest.prefix { !"\\*_`[]<>!|~&".contains($0) }
                runs.append(.init(text: String(plain), bold: bold, italic: italic, block: block))
                rest.removeFirst(plain.count)
            }
        }
        return normalized(NoteDocument(runs: runs))
    }
}

struct MarkdownHeading: Identifiable {
    let line: Int
    let title: String
    var id: Int { line }

    static func read(_ source: String) -> [Self] {
        var fence: String?
        return source.components(separatedBy: "\n").enumerated().compactMap { index, line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                fence = fence == nil ? marker : fence == marker ? nil : fence
                return nil
            }
            guard fence == nil, let range = line.range(of: #"^#{1,6} "#, options: .regularExpression) else { return nil }
            return Self(line: index + 1, title: String(line[range.upperBound...]))
        }
    }
}
