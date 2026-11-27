import AppKit

// What a copy out of the transcript puts on the clipboard. Plain text for anything that
// only reads text, and HTML for anything that keeps formatting, such as a chat, a mail
// or a document, so lists, emphasis, code and links paste the way they were read.
struct TranscriptClipboard {
    struct Piece {
        let role: TranscriptTextRole
        let text: NSAttributedString
    }

    // The text to paste, with each list item's marker in front of it.
    let plain: String
    // The words as they appear in the transcript, with no markers added.
    let text: String
    private let groups: [Group]

    // Built only when the copy is made, since a search or a menu needs just the text.
    var html: String { "<meta charset=\"utf-8\">" + Self.html(groups) }

    init(_ pieces: [Piece]) {
        // Words picked from inside one list item are a run of its text, not a list.
        var pieces = pieces
        if pieces.count == 1, case .listItem = pieces[0].role {
            pieces[0] = Piece(role: .block, text: pieces[0].text)
        }
        groups = Self.grouped(pieces)
        plain = Self.plain(groups, markers: true)
        text = Self.plain(groups, markers: false)
    }

    // Every cell taken from one table is a single group, so the table reads as a grid.
    private enum Group {
        case piece(Piece)
        case table(rows: [(row: Int, cells: [NSAttributedString])])
    }

    private static func grouped(_ pieces: [Piece]) -> [Group] {
        var groups: [Group] = []
        var index = 0
        while index < pieces.count {
            guard case .tableCell(let table, _) = pieces[index].role else {
                groups.append(.piece(pieces[index]))
                index += 1
                continue
            }
            var rows: [(row: Int, cells: [NSAttributedString])] = []
            while index < pieces.count,
                  case .tableCell(let next, let row) = pieces[index].role,
                  next == table {
                if rows.last?.row != row { rows.append((row, [])) }
                rows[rows.count - 1].cells.append(pieces[index].text)
                index += 1
            }
            groups.append(.table(rows: rows))
        }
        return groups
    }

    // MARK: - Plain text

    // Blocks are joined by a blank line because that is the gap the transcript draws
    // between them. The items of a list sit on lines of their own, as they are drawn.
    private static func plain(_ groups: [Group], markers: Bool) -> String {
        var result = ""
        var previousWasItem = false
        for group in groups {
            var text: String
            var isItem = false
            var startsItem = false
            switch group {
            case .table(let rows):
                // A tab between cells and a newline between rows is what a spreadsheet
                // reads back as a grid.
                text = rows.map { $0.cells.map(\.string).joined(separator: "\t") }
                    .joined(separator: "\n")
            case .piece(let piece):
                text = withBlankLines(piece.text)
                if text.isBlank { continue }
                if case .listItem(let depth, let marker) = piece.role {
                    isItem = true
                    startsItem = !marker.isEmpty
                    if markers {
                        let indent = String(repeating: "  ", count: depth)
                        let prefix = marker.isEmpty ? "  " : plainMarker(marker) + " "
                        // Later lines line up under the text, not under the marker.
                        let hanging = "\n" + indent + String(repeating: " ", count: prefix.count)
                        text = indent + prefix + text.replacingOccurrences(of: "\n", with: hanging)
                    }
                }
            }
            // A further paragraph of an item is a block of its own, after a blank line.
            if !result.isEmpty { result += previousWasItem && startsItem ? "\n" : "\n\n" }
            result += text
            previousWasItem = isItem
        }
        return result
    }

    private static func plainMarker(_ marker: String) -> String {
        MarkdownListItem.plainBullets.contains(marker) ? "-" : marker
    }

    // Blocks sharing one text view are separated by a single newline, with the gap on
    // screen drawn rather than typed. The blank line a reader sees between them has to
    // be put back on the way to the clipboard.
    private static func withBlankLines(_ piece: NSAttributedString) -> String {
        let string = piece.string as NSString
        return paragraphs(of: piece).map { string.substring(with: $0) }
            .joined(separator: "\n\n")
    }

    // MARK: - HTML

    private static func html(_ groups: [Group]) -> String {
        var result = ""
        var lists = ListNesting()
        for group in groups {
            guard case .piece(let piece) = group,
                  case .listItem(let depth, let marker) = piece.role else {
                result += lists.closeAll()
                result += html(group)
                continue
            }
            let paragraphs = paragraphs(of: piece.text)
            guard !paragraphs.isEmpty else { continue }
            result += lists.item(depth: depth, marker: marker)
            result += paragraphs
                .map { inline(piece.text, in: $0) }
                .joined(separator: "<br><br>")
        }
        return result + lists.closeAll()
    }

    private static func html(_ group: Group) -> String {
        switch group {
        case .table(let rows):
            let body = rows.map { row in
                let tag = row.row == 0 ? "th" : "td"
                let cells = row.cells.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined()
                return "<tr>\(cells)</tr>"
            }.joined()
            return "<table>\(body)</table>"
        case .piece(let piece):
            switch piece.role {
            case .code:
                return "<pre><code>\(piece.text.string.htmlEscaped)</code></pre>"
            case .plain(let monospaced):
                // Text shown as it arrived keeps its runs of spaces and its line breaks,
                // which HTML would otherwise fold away, and still wraps like a paragraph.
                guard !piece.text.string.isEmpty else { return "" }
                let font = monospaced ? ";font-family:ui-monospace,Menlo,monospace" : ""
                return "<p style=\"white-space:pre-wrap\(font)\">\(piece.text.string.htmlEscaped)</p>"
            case .quote:
                return "<blockquote>\(blocks(piece.text, heading: nil))</blockquote>"
            case .heading(let level):
                return blocks(piece.text, heading: level)
            default:
                return blocks(piece.text, heading: nil)
            }
        }
    }

    // A shared text view holds several paragraphs and headings. Each one is told apart
    // by the heading level its opening character carries.
    private static func blocks(_ text: NSAttributedString, heading: Int?) -> String {
        paragraphs(of: text).map { range in
            let level = heading
                ?? text.attribute(.transcriptHeading, at: range.location, effectiveRange: nil) as? Int
            let tag = level.map { "h\(min(max($0, 1), 6))" } ?? "p"
            return "<\(tag)>\(inline(text, in: range))</\(tag)>"
        }.joined()
    }

    private static func inline(_ text: NSAttributedString) -> String {
        inline(text, in: NSRange(location: 0, length: text.length))
    }

    // Runs that share their emphasis and link are written as one, since text drawn in
    // several colours still reads as one piece of bold.
    private static func inline(_ text: NSAttributedString, in range: NSRange) -> String {
        struct Run {
            var text: String
            let intent: InlinePresentationIntent
            let link: String?
        }
        var runs: [Run] = []
        text.enumerateAttributes(in: range) { attributes, subrange, _ in
            let piece = (text.string as NSString).substring(with: subrange)
            let intent = InlinePresentationIntent(rawValue: attributes[.transcriptInline] as? UInt ?? 0)
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            if let last = runs.last, last.intent == intent, last.link == link {
                runs[runs.count - 1].text += piece
            } else {
                runs.append(Run(text: piece, intent: intent, link: link))
            }
        }

        return runs.map { run in
            var html = run.text.htmlEscaped.replacingOccurrences(of: "\n", with: "<br>")
            if run.intent.contains(.code) { html = "<code>\(html)</code>" }
            if run.intent.contains(.emphasized) { html = "<em>\(html)</em>" }
            if run.intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
            if run.intent.contains(.strikethrough) { html = "<s>\(html)</s>" }
            if let link = run.link { html = "<a href=\"\(link.htmlEscaped)\">\(html)</a>" }
            return html
        }.joined()
    }

    // MARK: - Paragraphs

    // The ranges between the newlines that separate blocks sharing a text view. A
    // selection that starts or ends on one of those newlines leaves an empty range at
    // its edge, which holds nothing to copy and is left out.
    private static func paragraphs(of text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        text.enumerateAttribute(.transcriptBlockBreak,
                                in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            for location in range.location..<NSMaxRange(range) {
                ranges.append(NSRange(location: start, length: location - start))
                start = location + 1
            }
        }
        ranges.append(NSRange(location: start, length: text.length - start))
        return ranges.filter { $0.length > 0 }
    }
}

// The lists open around the item being written. An item deeper than the one before it
// opens a list inside that item, and a shallower one closes the lists it has left.
private struct ListNesting {
    private var open: [(depth: Int, tag: String)] = []

    mutating func item(depth: Int, marker: String) -> String {
        // A paragraph that carries on an item stays inside that item. Lists nested in
        // it close first, so the paragraph does not land in their last item.
        if marker.isEmpty, open.contains(where: { $0.depth == depth }) {
            var html = ""
            while let last = open.last, last.depth > depth {
                html += "</li></\(last.tag)>"
                open.removeLast()
            }
            return html.isEmpty ? "<br><br>" : html
        }

        let number = Int(marker.prefix { $0.isNumber })
        let tag = number == nil ? "ul" : "ol"
        var html = ""
        while let last = open.last, last.depth > depth || (last.depth == depth && last.tag != tag) {
            html += "</li></\(last.tag)>"
            open.removeLast()
        }
        if open.last?.depth == depth {
            html += "</li>"
        } else {
            let start = number.map { $0 == 1 ? "" : " start=\"\($0)\"" } ?? ""
            html += "<\(tag)\(start)>"
            open.append((depth, tag))
        }
        html += "<li>"
        // A tick box says something a bullet would lose, so it stays in the text.
        if number == nil, !marker.isEmpty, !MarkdownListItem.plainBullets.contains(marker) {
            html += marker + " "
        }
        return html
    }

    mutating func closeAll() -> String {
        defer { open.removeAll() }
        return open.reversed().map { "</li></\($0.tag)>" }.joined()
    }
}
