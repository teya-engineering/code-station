import Foundation
import Markdown

// Markdown read by swift-markdown, with a way back from its tree to the text it came
// from. The app keeps each block as the Markdown it was written in rather than as a
// tree: the views draw inline Markdown themselves, and the notes editor writes back
// untouched blocks exactly as they were.
struct MarkdownSource {
    let text: String
    let document: Document
    // Where each line starts, in UTF-8 bytes. swift-markdown counts lines and columns
    // from 1, and a column in bytes.
    private let lineStarts: [Int]

    init(_ text: String) {
        self.text = text
        // Smart quotes and dashes would change the text the app reads back out.
        document = Document(parsing: text, options: .disableSmartOpts)
        var starts = [0]
        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") {
            starts.append(offset + 1)
        }
        lineStarts = starts
    }

    func index(_ location: SourceLocation) -> String.Index {
        let line = min(max(location.line, 1), lineStarts.count) - 1
        let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : text.utf8.count
        let offset = min(lineStarts[line] + max(location.column - 1, 0), lineEnd)
        return text.utf8.index(text.utf8.startIndex, offsetBy: offset)
    }

    func slice(_ range: SourceRange) -> Substring {
        text[index(range.lowerBound)..<index(range.upperBound)]
    }

    // Line `number`, counted from 1.
    func line(_ number: Int) -> Substring {
        let start = SourceLocation(line: number, column: 1, source: nil)
        let end = SourceLocation(line: number, column: Int.max / 2, source: nil)
        return text[index(start)..<index(end)]
    }

    // The lines a block covers, counted from 0. cmark ends some blocks at the start of
    // the line after them, and an HTML block that closes on a mark such as `-->` on the
    // line it started, so those are counted again.
    func lines(of markup: Markup) -> Range<Int>? {
        guard let range = markup.range else { return nil }
        var end = range.upperBound.line
        if range.upperBound.column <= 1, end > range.lowerBound.line { end -= 1 }
        if let html = markup as? HTMLBlock {
            var raw = Substring(html.rawHTML)
            while raw.last == "\n" { raw.removeLast() }
            end = range.lowerBound.line + raw.utf8.count(where: { $0 == UInt8(ascii: "\n") })
        }
        return (range.lowerBound.line - 1)..<end
    }

    // The Markdown a block holds, without the quote marks and indentation that the
    // containers around it put at the start of each line.
    func content(of markup: Markup) -> String {
        if let html = markup as? HTMLBlock { return html.rawHTML.trimmed }
        // cmark loses the place of a paragraph that a table cut short.
        guard let range = markup.range else { return markup.format().trimmed }
        var end = range.upperBound
        if let lines = lines(of: markup) {
            end = min(end, SourceLocation(line: lines.upperBound, column: Int.max / 2, source: nil))
        }
        return content(range.lowerBound..<end, quotes: Self.quoteDepth(markup))
    }

    func content(_ range: SourceRange, quotes: Int) -> String {
        slice(range).split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.unquoted($0, depth: quotes) }
            .joined(separator: "\n")
            .trimmed
    }

    // A line with up to `depth` quote marks and the indentation around them taken off.
    static func unquoted(_ line: Substring, depth: Int) -> Substring {
        var rest = line.drop(while: { $0 == " " || $0 == "\t" })
        for _ in 0..<depth where rest.first == ">" {
            rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        }
        return rest
    }

    // How many block quotes hold this block, counting itself.
    static func quoteDepth(_ markup: Markup) -> Int {
        var depth = 0
        var node: Markup? = markup
        while let current = node {
            if current is BlockQuote { depth += 1 }
            node = current.parent
        }
        return depth
    }

    // A heading's title as written: the text between its hashes, or above its underline.
    func title(of heading: Heading) -> String {
        let ranges = heading.children.compactMap(\.range)
        guard let first = ranges.first, let last = ranges.last else { return "" }
        return content(first.lowerBound..<last.upperBound, quotes: Self.quoteDepth(heading))
    }
}
