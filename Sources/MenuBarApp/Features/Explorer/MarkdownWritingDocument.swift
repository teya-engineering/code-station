import Foundation
import Markdown

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
        let markdown = MarkdownSource(source)
        var reader = Reader(lines: source.components(separatedBy: "\n"), source: markdown)
        for block in markdown.document.children {
            reader.read(block)
        }
        reader.appendLiteral(upTo: reader.lines.count)
        let lines = reader.lines
        let spans = reader.spans
        let document = NoteDocument(runs: Self.normalized(NoteDocument(runs: reader.runs)))
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

    // Turns each block swift-markdown read into runs, when the editor would write that
    // block back the way it is written. Any other block stays as literal source.
    private struct Reader {
        let lines: [String]
        let source: MarkdownSource
        var runs: [NoteDocument.Run] = []
        // The source lines of each block. Code blocks that follow each other become one
        // block in the editor, so they share one span, and so do literal blocks.
        var spans: [Range<Int>] = []
        var lastMerging: NoteDocument.Block?
        // The lines before this one have been read.
        var covered = 0

        mutating func read(_ block: Markup) {
            guard var span = source.lines(of: block) else { return }
            span = max(span.lowerBound, covered)..<min(max(span.upperBound, covered), lines.count)
            while span.count > 1, lines[span.upperBound - 1].isEmpty { span = span.dropLast() }
            guard !span.isEmpty else { return }
            appendLiteral(upTo: span.lowerBound)
            var attempt = self
            // Only empty lines may fall between the blocks it read, as those are all the
            // gaps between blocks can write back.
            if attempt.admit(block, span), span.allSatisfy({ line in
                lines[line].isEmpty || attempt.spans.contains { $0.contains(line) }
            }) {
                self = attempt
            } else {
                appendLiteral(span)
            }
            covered = span.upperBound
        }

        // Written lines that make no block, such as a link reference definition, stay as
        // they are.
        mutating func appendLiteral(upTo end: Int) {
            guard covered < end,
                  let first = lines[covered..<end].firstIndex(where: { !$0.isEmpty }),
                  let last = lines[covered..<end].lastIndex(where: { !$0.isEmpty }) else { return }
            appendLiteral(first..<(last + 1))
            covered = end
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
        }

        private mutating func append(_ newRuns: [NoteDocument.Run], span: Range<Int>, merging: NoteDocument.Block? = nil) {
            if !runs.isEmpty { runs.append(.init(text: "\n")) }
            runs += newRuns
            if let merging, lastMerging == merging, let last = spans.last {
                spans[spans.count - 1] = last.lowerBound..<span.upperBound
            } else {
                spans.append(span)
            }
            lastMerging = merging
        }

        private mutating func admit(_ block: Markup, _ span: Range<Int>) -> Bool {
            switch block {
            case let paragraph as Paragraph:
                guard lines[span.lowerBound].first?.isWhitespace == false else { return false }
                return appendParagraph(paragraph, block: .text, span: span)
            case let heading as Heading:
                guard (1...3).contains(heading.level), span.count == 1 else { return false }
                let title = source.title(of: heading)
                // A heading closed with hashes, or written any other way, would change on an edit.
                guard lines[span.lowerBound] == String(repeating: "#", count: heading.level) + " " + title,
                      let inline = MarkdownWritingDocument.inline(title, block: Self.headings[heading.level - 1]) else { return false }
                append(inline, span: span)
                return true
            case let quote as BlockQuote:
                guard quote.childCount == 1, let paragraph = quote.child(at: 0) as? Paragraph,
                      lines[span.lowerBound].hasPrefix("> "),
                      lines[span].allSatisfy({ !$0.hasPrefix(">") || $0.hasPrefix("> ") }) else { return false }
                return appendParagraph(paragraph, block: .quote, span: span)
            case let list as ListItemContainer:
                return appendList(list, depth: 0, column: 0)
            case is CodeBlock:
                guard span.count > 2, lines[span.lowerBound] == "```", lines[span.upperBound - 1] == "```" else { return false }
                let code = lines[(span.lowerBound + 1)..<(span.upperBound - 1)].joined(separator: "\n")
                append([.init(text: code, block: .code)], span: span, merging: .code)
                return true
            case is Table:
                // A table must start its own block and run to a blank line. One that carries
                // on from a paragraph, or runs into the text below it, reads differently in
                // other Markdown readers, so it stays as source.
                guard span.lowerBound == 0 || lines[span.lowerBound - 1].isEmpty,
                      span.upperBound == lines.count || lines[span.upperBound].isEmpty,
                      lines[span].allSatisfy({ $0.hasPrefix("|") }) else { return false }
                append([.init(text: lines[span].joined(separator: "\n"), block: .table)], span: span)
                return true
            default:
                return false
            }
        }

        private static let headings: [NoteDocument.Block] = [.title, .heading, .subheading]

        // Each item must sit where the editor would put it: a "- " or "1. " marker at the
        // column where the item above it starts its text, and the text one space after it.
        private mutating func appendList(_ list: ListItemContainer, depth: Int, column: Int) -> Bool {
            if let ordered = list as? OrderedList, ordered.startIndex != 1 { return false }
            for item in list.listItems {
                let children = Array(item.children)
                guard let start = item.range?.lowerBound, start.column - 1 == column,
                      let paragraph = children.first as? Paragraph,
                      let text = paragraph.range?.lowerBound,
                      children.count == 1 || children.count == 2 && children[1] is ListItemContainer else { return false }
                let line = lines[start.line - 1].dropFirst(column)
                let shape: (prefix: String, block: NoteDocument.Block, marker: String)? = switch (list is OrderedList, item.checkbox) {
                case (true, nil): ("1. ", .numbered, "1. ")
                case (false, nil): ("- ", .bullet, "• ")
                case (false, .unchecked): ("- [ ] ", .checklist, "☐ ")
                case (false, .checked): ("- [x] ", .checklist, "☑ ")
                case (true, _): nil
                }
                guard let shape, line.hasPrefix(shape.prefix), text.column - 1 == column + shape.prefix.count,
                      let paragraphLines = source.lines(of: paragraph),
                      appendParagraph(paragraph, block: shape.block, marker: shape.marker, depth: depth,
                                      span: (start.line - 1)..<paragraphLines.upperBound) else { return false }
                if children.count == 2, let nested = children[1] as? ListItemContainer {
                    let width = shape.block == .numbered ? 3 : 2
                    guard appendList(nested, depth: depth + 1, column: column + width) else { return false }
                }
            }
            return true
        }

        // A paragraph is read as one line of text, its wraps read as spaces. Indentation
        // inside it, a hard break or a line that starts like another block carries
        // meaning that a paragraph-only rich editor cannot safely reconstruct.
        private mutating func appendParagraph(_ paragraph: Paragraph, block: NoteDocument.Block, marker: String = "",
                                              depth: Int = 0, span: Range<Int>) -> Bool {
            for (offset, line) in lines[span].enumerated() {
                guard !line.contains("\t"), line.last?.isWhitespace != true else { return false }
                guard offset > 0 else { continue }
                let carried = MarkdownSource.unquoted(Substring(line), depth: block == .quote ? 1 : 0)
                guard !["---", "===", "+++", "~~~", "```"].contains(where: carried.hasPrefix),
                      carried.range(of: #"^(\d+[.)] |[+*>-] |#{1,6}( |$))"#, options: .regularExpression) == nil
                else { return false }
            }
            guard let inline = MarkdownWritingDocument.inline(source.content(of: paragraph), block: block) else { return false }
            var runs = inline.map { var run = $0; run.indent = depth; return run }
            if !marker.isEmpty { runs.insert(.init(text: marker, block: block, indent: depth), at: 0) }
            append(runs, span: span)
            return true
        }
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
            if var last = result.last, run.block != .table, last.bold == run.bold, last.italic == run.italic,
               last.block == run.block, last.link == run.link, last.code == run.code, last.indent == run.indent {
                last.text += run.text; result[result.count - 1] = last
            } else { result.append(run) }
        }
        return result
    }


    // The runs of one paragraph of inline Markdown, or nil when it holds anything the
    // editor would write back differently: an image, inline HTML, a hard break, emphasis
    // with underscores, a link with a title, or a mark written without its escape.
    static func inline(_ text: String, block: NoteDocument.Block) -> [NoteDocument.Run]? {
        let source = MarkdownSource(text)
        guard source.document.childCount > 0 else { return [] }
        guard source.document.childCount == 1, let paragraph = source.document.child(at: 0) as? Paragraph,
              let runs = Self.runs(paragraph.children, in: source, template: .init(text: "", block: block))
        else { return nil }
        return normalized(NoteDocument(runs: runs))
    }

    private static func runs(_ nodes: some Sequence<Markup>, in source: MarkdownSource,
                             template: NoteDocument.Run) -> [NoteDocument.Run]? {
        var runs: [NoteDocument.Run] = []
        func written(_ node: Markup) -> Substring? { node.range.map(source.slice) }
        for node in nodes {
            var run = template
            switch node {
            case let text as Text:
                guard let written = written(text), writesBackAsWritten(written) else { return nil }
                run.text = text.string
                runs.append(run)
            case is SoftBreak:
                run.text = " "
                runs.append(run)
            case let code as InlineCode:
                run.text = code.code
                run.code = true
                runs.append(run)
            case is Strong, is Emphasis:
                guard written(node)?.first == "*" else { return nil }
                if node is Strong { run.bold = true } else { run.italic = true }
                guard let nested = Self.runs(node.children, in: source, template: run) else { return nil }
                runs += nested
            case let link as Link:
                guard written(link)?.first == "[", link.title == nil,
                      let destination = link.destination, !destination.contains(where: \.isWhitespace),
                      let kept = NoteDocument.keptLink(destination) else { return nil }
                run.link = kept
                guard let nested = Self.runs(link.children, in: source, template: run) else { return nil }
                runs += nested
            default:
                return nil
            }
        }
        return runs
    }

    // The editor escapes Markdown's marks when it writes text, so text that holds one
    // unescaped, or an entity, would change on an edit.
    private static func writesBackAsWritten(_ written: Substring) -> Bool {
        var index = written.startIndex
        while index < written.endIndex {
            let character = written[index]
            if character == "\\" {
                let next = written.index(after: index)
                guard next < written.endIndex, #"\`*_{}[]<>#!|-+.=~&"#.contains(written[next]) else { return false }
                index = written.index(after: next)
                continue
            }
            if "*_`[]<>!|~".contains(character) || character == "&" && NoteDocument.startsEntity(written[index...]) {
                return false
            }
            index = written.index(after: index)
        }
        return true
    }
}

struct MarkdownHeading: Identifiable {
    let line: Int
    let title: String
    var id: Int { line }

    static func read(_ source: String) -> [Self] {
        Document(parsing: source, options: .disableSmartOpts).children.compactMap { block in
            guard let heading = block as? Heading, let line = heading.range?.lowerBound.line else { return nil }
            return Self(line: line, title: heading.plainText)
        }
    }
}
