import Markdown
import SwiftUI
import UniformTypeIdentifiers

// Block-level markdown for chat prose: headings, tables, lists, quotes and rules.
// Fenced code is split out before this runs (see MessageSegment). swift-markdown reads
// the structure; each block keeps its inline Markdown as written, for the views to draw.
struct MarkdownBlock: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: Kind

    enum Kind: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case table(MarkdownTable)
        case list([MarkdownListItem])
        case quote(String)
        case rule
        case htmlPreview(HTMLPreviewReference)
        // A paragraph or heading that HTML asked to be centred.
        indirect case centered(Kind)
    }

    // `html` reads HTML blocks as the page they describe. A document asks for it; a
    // transcript does not, so a tag Claude writes on a line of its own stays visible.
    static func parse(_ text: String, html: Bool = false) -> [MarkdownBlock] {
        var reader: MarkdownHTML.Reader? = html ? MarkdownHTML.Reader() : nil
        return parse(text, reader: &reader)
    }

    // A prose segment that a fence has closed off is the same text on every flush of a
    // streaming reply, so its blocks are kept rather than read again. The segment still
    // growing at the end must not come here: it would leave a new entry on every flush.
    static func parse(settled text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let kept = settled.object(forKey: key) { return kept.blocks }
        let blocks = parse(text)
        settled.setObject(Parsed(blocks: blocks), forKey: key, cost: text.utf8.count)
        return blocks
    }

    // NSCache is safe to share across threads.
    nonisolated(unsafe) private static let settled: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    private final class Parsed: Sendable {
        let blocks: [MarkdownBlock]
        init(blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    // The prose of a whole document, read with one HTML reader, so a container opened
    // before a code fence still holds what follows it. Keyed by segment.
    static func parse(document segments: [MessageSegment]) -> [Int: [MarkdownBlock]] {
        var reader: MarkdownHTML.Reader? = MarkdownHTML.Reader()
        var result: [Int: [MarkdownBlock]] = [:]
        for segment in segments where !segment.isCode {
            result[segment.id] = parse(segment.text, reader: &reader)
        }
        return result
    }

    // Reads HTML blocks when given a reader, carrying its open containers in and out.
    static func parse(_ text: String, reader: inout MarkdownHTML.Reader?) -> [MarkdownBlock] {
        let source = MarkdownSource(text)
        var kinds: [Kind] = []
        // Where Markdown began inside an HTML container that centres it.
        var centeredFrom: Int? = reader?.centered == true ? 0 : nil
        func centerMarkdown(upTo end: Int) {
            guard let start = centeredFrom, start < end else { return }
            for index in start..<end {
                switch kinds[index] {
                case .paragraph, .heading: kinds[index] = .centered(kinds[index])
                default: break
                }
            }
        }

        for block in source.document.children {
            if reader != nil, let html = html(of: block, in: source) {
                centerMarkdown(upTo: kinds.count)
                kinds += reader!.read(html)
                centeredFrom = reader!.centered ? kinds.count : nil
            } else {
                kinds += Self.kinds(of: block, in: source)
            }
        }
        centerMarkdown(upTo: kinds.count)
        return kinds.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    // An HTML block, or a paragraph of nothing but tags, such as a row of linked badges.
    private static func html(of block: Markup, in source: MarkdownSource) -> String? {
        if let html = block as? HTMLBlock { return html.rawHTML }
        guard block is Paragraph, block.children.contains(where: { $0 is InlineHTML }),
              block.children.allSatisfy({ child in
                  child is InlineHTML || child is SoftBreak || child is LineBreak
                      || (child as? Markdown.Text)?.string.allSatisfy(\.isWhitespace) == true
              }) else { return nil }
        return source.content(of: block)
    }

    private static func kinds(of block: Markup, in source: MarkdownSource) -> [Kind] {
        switch block {
        case let heading as Heading:
            return [.heading(level: heading.level, text: source.title(of: heading))]
        case is ThematicBreak:
            return [.rule]
        case let table as Markdown.Table:
            if let read = MarkdownTable(table, in: source) { return [.table(read)] }
        case let list as ListItemContainer:
            return [.list(listItems(list, depth: 0, in: source))]
        case is BlockQuote:
            return [.quote(source.content(of: block))]
        case is Paragraph:
            return paragraphs(source.content(of: block))
        default:
            break
        }
        // Anything else, such as indented code or HTML in a transcript, shows as written.
        let text = source.content(of: block)
        return text.isEmpty ? [] : [.paragraph(text)]
    }

    // A line that asks for an HTML preview stands as a block of its own, even when
    // Markdown reads it as part of the paragraph around it.
    private static func paragraphs(_ text: String) -> [Kind] {
        guard text.contains(TranscriptMarker.open) else { return [.paragraph(text)] }
        var kinds: [Kind] = []
        var lines: [String] = []
        func flush() {
            let joined = lines.joined(separator: "\n").trimmed
            if !joined.isEmpty { kinds.append(.paragraph(joined)) }
            lines = []
        }
        for line in text.lines {
            if let reference = HTMLPreviewReference.parse(line.trimmedSpaces) {
                flush()
                kinds.append(.htmlPreview(reference))
            } else {
                lines.append(line)
            }
        }
        flush()
        return kinds
    }

    static let bullets = ["•", "◦", "▪"]

    // Every item of a list and of the lists inside it, in reading order. A paragraph
    // after the first in an item carries on that item, so it has no marker of its own.
    private static func listItems(_ list: ListItemContainer, depth: Int,
                                  in source: MarkdownSource) -> [MarkdownListItem] {
        let level = min(depth, bullets.count - 1)
        var items: [MarkdownListItem] = []
        for (offset, item) in list.listItems.enumerated() {
            var marker: String
            if let ordered = list as? OrderedList {
                marker = "\(Int(ordered.startIndex) + offset)\(delimiter(of: item, in: source))"
            } else {
                marker = switch item.checkbox {
                case .checked: "☑"
                case .unchecked: "☐"
                case nil: bullets[level]
                }
            }
            for child in item.children {
                if let nested = child as? ListItemContainer {
                    // An item that opens with a list still shows its own marker first.
                    if !marker.isEmpty {
                        items.append(MarkdownListItem(depth: level, marker: marker, text: ""))
                        marker = ""
                    }
                    items += listItems(nested, depth: depth + 1, in: source)
                } else {
                    items.append(MarkdownListItem(depth: level, marker: marker, text: source.content(of: child)))
                    marker = ""
                }
            }
            if !marker.isEmpty { items.append(MarkdownListItem(depth: level, marker: marker, text: "")) }
        }
        return items
    }

    // "." or ")", as the item was written.
    private static func delimiter(of item: ListItem, in source: MarkdownSource) -> String {
        guard let start = item.range?.lowerBound else { return "." }
        let written = source.text[source.index(start)...].drop(while: { $0 == " " || $0.isNumber })
        return written.first == ")" ? ")" : "."
    }
}

// How an image asks to be drawn. The size is in points, and a side left out follows the
// picture's own shape. An image from HTML shows no caption, as a browser shows none:
// its alt text stays its tooltip and what VoiceOver reads.
struct MarkdownImageAttributes: Equatable, Hashable {
    var width: CGFloat?
    var height: CGFloat?
    var captioned = true
    // Where the image links to, for an HTML `<img>` inside an `<a>`. When the image
    // cannot be drawn, the link is what is left of it.
    var link: String?

    // Marks an image that came from an HTML `<img>`.
    static let htmlClass = ".html"
    // No sensible page asks for more; anything larger is capped rather than trusted.
    static let largest: CGFloat = 4096

    // The block this reads back from, or nothing when there is nothing to say.
    var markdown: String {
        let tokens = [captioned ? nil : Self.htmlClass,
                      width.map { "width=\(Self.number($0))" },
                      height.map { "height=\(Self.number($0))" },
                      link.map { "link=\(Self.encoded($0))" }].compactMap { $0 }
        return tokens.isEmpty ? "" : "{\(tokens.joined(separator: " "))}"
    }

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(Double(value))
    }

    // A destination that survives being a Markdown link or an attribute value: nothing
    // in it may end the parentheses, the braces or the token early.
    static func encoded(_ destination: String) -> String {
        var result = ""
        for character in destination {
            switch character {
            case " ": result += "%20"
            case "(": result += "%28"
            case ")": result += "%29"
            case "{": result += "%7B"
            case "}": result += "%7D"
            case "\"": result += "%22"
            case "'": result += "%27"
            default: result.append(character)
            }
        }
        return result
    }

    // Pandoc's attribute block after an image, `{width=96 height=96}`, which is also how
    // an HTML `<img>` passes its size on. Other attributes such as `.class` or `#id` are
    // allowed and ignored; anything that is not an attribute list is not one.
    static func attributes(_ text: Substring) -> (attributes: MarkdownImageAttributes, length: Int)? {
        guard text.first == "{", let close = text.firstIndex(of: "}") else { return nil }
        let body = text[text.index(after: text.startIndex)..<close]
        guard !body.contains(where: \.isNewline) else { return nil }
        var size = MarkdownImageAttributes()
        for token in body.split(separator: " ") {
            if token == htmlClass { size.captioned = false; continue }
            if token.first == "." || token.first == "#" { continue }
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, !pair[0].isEmpty else { return nil }
            let value = points(String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            switch pair[0].lowercased() {
            case "width": size.width = value
            case "height": size.height = value
            case "link": size.link = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            default: break
            }
        }
        guard size.width != nil || size.height != nil || !size.captioned || size.link != nil else { return nil }
        return (size, text.distance(from: text.startIndex, to: close) + 1)
    }

    // "96" or "96px". A percentage or any other unit has no fixed size, so it is ignored.
    static func points(_ value: String) -> CGFloat? {
        let number = value.lowercased().hasSuffix("px") ? String(value.dropLast(2)) : value
        guard let parsed = Double(number), parsed.isFinite, parsed > 0 else { return nil }
        return min(CGFloat(parsed), largest)
    }
}

// Local image links and Markdown images share the same preview.
extension MarkdownBlock {
    enum ParagraphPart: Equatable {
        case text(String)
        case image(alt: String, source: String, attributes: MarkdownImageAttributes? = nil)
        case link(label: String, source: String)
    }

    static func paragraphParts(_ text: String) -> [ParagraphPart] {
        writtenParts(text).map(\.part)
    }

    // Each part with the text it was written as. Labels and alt text stay Markdown,
    // while a source is the destination Markdown reads out of the link.
    private static func writtenParts(_ text: String) -> [(part: ParagraphPart, written: Substring)] {
        // Nothing can be a link or an image without this, and most paragraphs lack it.
        guard text.contains("](") else { return text.isEmpty ? [] : [(.text(text), text[...])] }
        let source = MarkdownSource(text)
        var parts: [(part: ParagraphPart, written: Substring)] = []
        var cursor = text.startIndex

        // The label as written, from just inside its opening bracket to its closing one.
        func label(of node: Markup, from start: String.Index) -> String {
            let opened = text.index(start, offsetBy: node is Markdown.Image ? 2 : 1)
            let lastChild = node.children.compactMap(\.range).last.map { source.index($0.upperBound) } ?? opened
            let close = text[lastChild...].firstIndex(of: "]") ?? lastChild
            return String(text[opened..<close])
        }

        for node in linksAndImages(in: source.document) {
            guard let range = node.range else { continue }
            let start = source.index(range.lowerBound)
            let end = source.index(range.upperBound)
            // An autolink has no label to show, and one that starts inside text already
            // taken, such as an image's size, is not a part of its own.
            guard start >= cursor, start < end, text[start] == "[" || text[start] == "!" else { continue }

            let part: ParagraphPart
            var attributes: (attributes: MarkdownImageAttributes, length: Int)?
            if let image = node as? Markdown.Image, let path = image.source, !path.isEmpty {
                attributes = MarkdownImageAttributes.attributes(text[end...])
                part = .image(alt: label(of: image, from: start), source: path, attributes: attributes?.attributes)
            } else if let link = node as? Markdown.Link, let destination = link.destination, !destination.isEmpty {
                // A picture that links somewhere, such as a badge, is drawn as the picture
                // and keeps the link for when it cannot be.
                if link.childCount == 1, let image = link.child(at: 0) as? Markdown.Image, let path = image.source,
                   !path.isEmpty, let imageStart = image.range.map({ source.index($0.lowerBound) }) {
                    part = .image(alt: label(of: image, from: imageStart), source: path,
                                  attributes: MarkdownImageAttributes(link: destination))
                } else {
                    part = .link(label: label(of: link, from: start), source: destination)
                }
            } else {
                continue
            }
            if cursor < start { parts.append((.text(String(text[cursor..<start])), text[cursor..<start])) }
            parts.append((part, text[start..<end]))
            cursor = attributes.map { text.index(end, offsetBy: $0.length) } ?? end
        }
        if cursor < text.endIndex { parts.append((.text(String(text[cursor...])), text[cursor...])) }
        return parts
    }

    // In reading order, leaving out anything inside a link or an image.
    private static func linksAndImages(in markup: Markup) -> [Markup] {
        markup.children.flatMap { child -> [Markup] in
            child is Markdown.Link || child is Markdown.Image ? [child] : linksAndImages(in: child)
        }
    }

    // What an image that cannot be drawn leaves behind: its link when it had one, and
    // otherwise the image as written, without the attributes that had nothing to size.
    private static func fallback(alt: String, attributes: MarkdownImageAttributes?, written: Substring) -> String {
        guard let link = attributes?.link else { return String(written) }
        return "[\(alt.trimmed.isEmpty ? NoteDocument.escape(link) : alt)](\(MarkdownImageAttributes.encoded(link)))"
    }

    // The text as it reads with no image drawn: the same text, with each image's
    // attribute block taken off, so a paragraph shown as plain text never prints one.
    static func displayText(_ text: String) -> String {
        guard text.contains("){") else { return text }
        return writtenParts(text).map { part, written in
            guard case .image(let alt, _, let attributes) = part else { return String(written) }
            return fallback(alt: alt, attributes: attributes, written: written)
        }.joined()
    }

    // Alt text is written as Markdown, so its escapes and emphasis are not part of what
    // a caption or a tooltip says.
    static func plainText(_ markdown: String) -> String {
        String(AttributedString.inlineMarkdown(markdown).characters)
    }

    enum ResolvedPart: Equatable {
        case text(String)
        case image(alt: String, url: URL, attributes: MarkdownImageAttributes? = nil)
    }

    // Splits a paragraph around the images that resolve to a file. One that does not
    // rejoins the surrounding text as written, so the paragraph then renders the way
    // it would have without image support.
    static func resolvedParts(_ text: String,
                              resolve: (String) -> URL?) -> [ResolvedPart] {
        var resolved: [ResolvedPart] = []

        func appendText(_ piece: String) {
            if case .text(let existing) = resolved.last {
                resolved[resolved.count - 1] = .text(existing + piece)
            } else {
                resolved.append(.text(piece))
            }
        }

        for (part, written) in writtenParts(text) {
            switch part {
            case .text(let piece):
                appendText(piece)
            case .link(let label, let source):
                if let url = resolve(source) {
                    resolved.append(.image(alt: plainText(label), url: url))
                } else {
                    appendText(String(written))
                }
            case .image(let alt, let source, let attributes):
                if let url = resolve(source) {
                    resolved.append(.image(alt: plainText(alt), url: url, attributes: attributes))
                } else {
                    appendText(fallback(alt: alt, attributes: attributes, written: written))
                }
            }
        }
        return resolved
    }
}

extension MarkdownBlock {
    // The gap between two blocks of prose.
    static let proseGap: CGFloat = 12

    // Sizes step down the way the app's own headers do: serif for the two big levels,
    // plain semibold below.
    static func headingStyle(_ level: Int) -> (size: CGFloat, design: TranscriptFontDesign) {
        switch level {
        case 1: (18, .serif)
        case 2: (15.5, .serif)
        case 3: (14, .standard)
        default: (13, .standard)
        }
    }

    // Whether this is worth drawing in a text view shared with its neighbours. Only prose
    // and headings are: everything else owns sibling views it cannot give up, such as a
    // list's markers, a table's cells or a code block's own scroller.
    var sharesATextView: Bool {
        switch kind {
        case .paragraph, .heading: true
        default: false
        }
    }

    // A run of blocks as one string for one text view. Each block keeps the type it had
    // and the air above it, so the page reads exactly as it did when every block was a
    // view of its own.
    static func sharedProse(_ blocks: [MarkdownBlock]) -> AttributedString {
        var result = AttributedString()
        for (offset, block) in blocks.enumerated() {
            let text: String
            var style: TranscriptBlockStyle
            switch block.kind {
            case .paragraph(let body):
                text = displayText(body)
                style = TranscriptBlockStyle(size: 13.5,
                                             weight: NSFont.Weight.regular.rawValue,
                                             design: .standard,
                                             spacingBefore: proseGap)
            case .heading(let level, let title):
                let heading = headingStyle(level)
                text = displayText(title)
                style = TranscriptBlockStyle(size: heading.size,
                                             weight: NSFont.Weight.semibold.rawValue,
                                             design: heading.design,
                                             spacingBefore: proseGap + (level <= 2 ? 6 : 2))
            default:
                continue
            }
            // Nothing sits above the first block, so it takes no gap.
            if offset == 0 { style.spacingBefore = 0 }

            if offset > 0 {
                var separator = AttributedString("\n")
                separator[TranscriptBlockBreakAttribute.self] = true
                result += separator
            }

            var piece = AttributedString.inlineMarkdown(text)
            let opening = piece.characters.firstIndex(of: "\n") ?? piece.endIndex
            piece[piece.startIndex..<opening][TranscriptBlockStyleAttribute.self] = style
            if opening < piece.endIndex {
                var continued = style
                continued.spacingBefore = 0
                piece[opening..<piece.endIndex][TranscriptBlockStyleAttribute.self] = continued
            }
            result += piece
        }
        return result
    }
}

// Only local image files render here. Web links stay links without fetching them.
enum TranscriptImage {
    static func resolve(_ source: String, projectPath: String) -> URL? {
        var path = source.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("<"), path.hasSuffix(">") {
            path = String(path.dropFirst().dropLast())
        }
        guard !path.isEmpty, let parsed = URL(string: path),
              parsed.host?.isEmpty != false || (parsed.isFileURL && parsed.host == "localhost"),
              parsed.scheme == nil || parsed.isFileURL else { return nil }

        let url: URL
        if parsed.isFileURL {
            url = parsed
        } else {
            path = ((path.removingPercentEncoding ?? path) as NSString).expandingTildeInPath
            url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: projectPath).appendingPathComponent(path)
        }
        let file = url.standardizedFileURL
        guard let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .image) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return file
    }
}

struct MarkdownTable: Equatable, Sendable {
    enum ColumnAlignment: Equatable {
        case leading, center, trailing
    }

    let header: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]

    init(header: [String], alignments: [ColumnAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    // The table that `markdown` holds, when it opens with one.
    init?(markdown: String) {
        let source = MarkdownSource(markdown)
        guard let table = source.document.child(at: 0) as? Markdown.Table else { return nil }
        self.init(table, in: source)
    }

    // The cells are read from the lines themselves, so each keeps its Markdown as written.
    // swift-markdown says which lines make the table, though not always where its header
    // is: it loses that when the table cuts a paragraph short. The header is the line above
    // the row of dashes, and the body rows follow that row one to a line.
    init?(_ table: Markdown.Table, in source: MarkdownSource) {
        let delimiter: Int
        if let firstRow = table.body.child(at: 0)?.range {
            delimiter = firstRow.lowerBound.line - 1
        } else if let lines = source.lines(of: table) {
            delimiter = lines.upperBound
        } else {
            return nil
        }
        let columns = table.maxColumnCount
        let quotes = MarkdownSource.quoteDepth(table)
        func row(_ line: Int) -> [String] {
            Self.sized(Self.cells(String(MarkdownSource.unquoted(source.line(line), depth: quotes))), to: columns)
        }
        header = row(delimiter - 1)
        rows = (0..<table.body.childCount).map { row(delimiter + 1 + $0) }
        alignments = (0..<columns).map { column in
            switch column < table.columnAlignments.count ? table.columnAlignments[column] : nil {
            case .center: .center
            case .right: .trailing
            default: .leading
            }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var content = Substring(line.trimmedSpaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        // One pass over the row. A pipe inside a cell arrives escaped and stays in the cell.
        var cells: [String] = []
        var cell = ""
        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            index = content.index(after: index)
            if character == "\\", index < content.endIndex, content[index] == "|" {
                cell.append("|")
                index = content.index(after: index)
            } else if character == "|" {
                cells.append(cell.trimmedSpaces)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmedSpaces)
        return cells
    }

    private static func sized(_ row: [String], to count: Int) -> [String] {
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }
}

struct MarkdownListItem: Equatable, Sendable {
    // The markers that carry no meaning of their own, so the view can draw a shape
    // instead. A number or a tick box says something the shape would lose.
    static let plainBullets: Set<String> = ["•", "◦", "▪"]

    let depth: Int
    // Empty for a paragraph that carries on the item above it.
    let marker: String
    let text: String
}
