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

// Inline markdown only: `code`, bold, italics and links render, newlines stay as
// they are. Block structure is the parser's job, so none of it reaches here.
extension AttributedString {
    static func inlineMarkdown(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }

        // Markdown keeps filesystem paths as scheme-less URLs, which Launch Services
        // cannot open. Turn only filesystem-shaped links into file URLs and leave web,
        // mail, and relative links to SwiftUI's normal handling.
        for run in Array(attributed.runs) {
            guard let link = run.link else { continue }
            if link.scheme == nil, link.host == nil {
                let path = link.path
                if path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") {
                    attributed[run.range].link = URL(
                        fileURLWithPath: (path as NSString).expandingTildeInPath)
                }
            }
        }
        return attributed
    }

    var hasLocalFileLink: Bool {
        runs.contains { $0.link?.isFileURL == true }
    }

    // Markdown leaves an address in backticks unlinked. A code span is linked only when
    // it holds the address alone, so a command that mentions one still reads as code.
    func linkingLocalServers() -> AttributedString {
        let rendered = String(characters)
        let addresses = TranscriptLink.localServers(in: rendered)
        guard !addresses.isEmpty else { return self }

        let code = runs[\.inlinePresentationIntent].compactMap { intent, range in
            intent?.contains(.code) == true ? Range(range, in: rendered) : nil
        }
        var linked = self
        for (span, url) in addresses {
            guard code.allSatisfy({ !$0.overlaps(span) || $0 == span }),
                  let start = AttributedString.Index(span.lowerBound, within: linked),
                  let end = AttributedString.Index(span.upperBound, within: linked),
                  linked[start..<end].runs.allSatisfy({ $0.link == nil }) else { continue }
            linked[start..<end].link = url
        }
        return linked
    }
}

struct LinkHoverAction {
    let perform: (URL?) -> Void

    func callAsFunction(_ url: URL?) { perform(url) }
}

extension EnvironmentValues {
    // The folders whose files a transcript link opens in the explorer. Empty wherever
    // there is no explorer to send them to, so those links keep going to Finder.
    @Entry var explorerRoots: [String] = []
    // Off where there is no preview, so text and its links stay as they were.
    @Entry var previewsLocalServers = false
    // Told which link the pointer is over, and nil when it leaves, where a screen lights
    // what a link points at before it is clicked.
    @Entry var linkHovered: LinkHoverAction? = nil
}

enum TranscriptLink {
    static let finderToolTip = "Open in Finder"
    static let explorerToolTip = "Show in Explorer"
    static let previewToolTip = "Open in preview"

    struct ExplorerTarget: Equatable {
        let root: String
        let path: String
        let line: Int?
    }

    struct Hovered: Equatable {
        let url: URL
        let frame: CGRect
    }

    // File links can carry a source line after the path. Finder needs the real path,
    // while web and mail links keep SwiftUI's normal system action.
    static func finderTarget(
        for url: URL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        guard url.isFileURL else { return nil }
        guard !fileExists(url.path),
              let suffix = url.path.range(of: #":\d+(?::\d+)?$"#,
                                          options: .regularExpression) else { return url }

        let file = URL(fileURLWithPath: String(url.path[..<suffix.lowerBound]))
        return fileExists(file.path) ? file : url
    }

    // A file inside one of the session's folders is shown in the app's own explorer
    // instead of Finder. When folders nest, the deepest one wins, so a worktree inside
    // its project opens as itself.
    static func explorerTarget(
        for url: URL,
        roots: [String],
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> ExplorerTarget? {
        guard let file = finderTarget(for: url, fileExists: fileExists),
              fileExists(file.path) else { return nil }
        let root = roots
            .filter { root in file.path.pathRelative(to: root).map { !$0.isEmpty } ?? false }
            .max { $0.count < $1.count }
        guard let root else { return nil }

        let line = file.path == url.path
            ? nil
            : Int(url.path.dropFirst(file.path.count + 1).prefix(while: \.isNumber))
        return ExplorerTarget(root: root, path: file.path, line: line)
    }

    // The hosts the sign-in callback trusts. A name such as app.localhost is left out,
    // as it goes through the resolver like any other host.
    static let localServerHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    static func isLocalServer(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host
        else { return false }
        return localServerHosts.contains(host.lowercased())
    }

    static func localServers(in text: String) -> [(span: Range<String.Index>, url: URL)] {
        guard mentionsLocalServer(text) else { return [] }
        return text.matches(of: localServerAddress).compactMap { match in
            let address = trimmingSentence(from: match.output)
            guard let url = URL(string: String(address)), isLocalServer(url) else { return nil }
            return (address.startIndex..<address.endIndex, url)
        }
    }

    static func latestLocalServer(in messages: [ChatMessage]) -> URL? {
        messages.reversed().lazy.compactMap { lastLocalServer(in: $0) }.first
    }

    // Read as the transcript draws it, so only an address shown as a link counts.
    private static func lastLocalServer(in message: ChatMessage) -> URL? {
        guard mentionsLocalServer(message.text) else { return nil }
        let prose: [AttributedString]
        switch message.role {
        case .assistant:
            prose = MessageSegment.split(message.text).filter { !$0.isCode }
                .map { AttributedString.inlineMarkdown($0.text).linkingLocalServers() }
        case .user:
            prose = SentPrompt.segments(message.text).filter { !$0.isCode }
                .map { SentPrompt.inline($0.text, commands: SlashCommandNames()) }
        case .system, .instructions:
            return nil
        }
        return prose.flatMap { $0.runs[\.link].compactMap { link, _ in link } }
            .last(where: isLocalServer)
    }

    private static func mentionsLocalServer(_ text: String) -> Bool {
        ["://localhost", "://127.0.0.1", "://[::1]"].contains(where: {
            text.range(of: $0, options: .caseInsensitive) != nil
        })
    }

    private static var localServerAddress: Regex<Substring> {
        #/https?://[A-Za-z0-9\-._~:\/?#\[\]@!$&()*+,;=%]+/#
    }

    private static func trimmingSentence(from match: Substring) -> Substring {
        var address = match
        func count(_ character: Character) -> Int { address.filter { $0 == character }.count }
        while let last = address.last,
              ".,:;!?".contains(last)
                || (last == ")" && count(")") > count("("))
                || (last == "]" && count("]") > count("[")) {
            address = address.dropLast()
        }
        return address
    }

    // NSTextView fills the available row even when its link is only a few words. Use
    // the link's glyphs so its hint follows the text instead of the edge of that row.
    @MainActor
    static func hoveredLink(in textView: NSTextView, at point: CGPoint) -> Hovered? {
        guard let storage = textView.textStorage,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager,
              storage.length > 0 else { return nil }

        layoutManager.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let containerPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: containerPoint,
            in: container,
            fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }

        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: container)
        guard glyphRect.insetBy(dx: -1, dy: -1).contains(containerPoint) else { return nil }

        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        var linkCharacters = NSRange()
        guard let value = storage.attribute(.link,
                                            at: character,
                                            effectiveRange: &linkCharacters),
              let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        else { return nil }

        let linkGlyphs = layoutManager.glyphRange(
            forCharacterRange: linkCharacters,
            actualCharacterRange: nil)
        var lineGlyphs = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let visibleLinkGlyphs = NSIntersectionRange(linkGlyphs, lineGlyphs)
        guard visibleLinkGlyphs.length > 0 else { return nil }

        let rect = layoutManager.boundingRect(forGlyphRange: visibleLinkGlyphs, in: container)
            .offsetBy(dx: origin.x, dy: origin.y)
        return Hovered(url: url, frame: rect)
    }
}

// How a block works out how wide it is.
enum TextWidth {
    // Fills the width it is offered and wraps to it. What page prose wants.
    case fills
    // Wraps to the width it is offered but claims only the width it used, so a short
    // line leaves the rest of the row alone. What a bubble drawn around text wants.
    case hugs
    // Keeps the line breaks it came with and lets the longest of them set the width,
    // running off the side into a scroller rather than folding. What code wants.
    case fixed
}

// Which typeface family a run asks for. Its own type rather than SwiftUI's Font.Design,
// because a style has to travel inside an attributed string, which stays a value.
enum TranscriptFontDesign: String, Codable, Hashable, Sendable {
    case standard, serif, monospaced
}

// One place that turns type choices into a font, so a block inside a shared text view and
// a whole text view of its own resolve theirs the same way.
func transcriptNSFont(size: CGFloat, weight: NSFont.Weight,
                      design: TranscriptFontDesign, italic: Bool) -> NSFont {
    let base: NSFont = switch design {
    case .serif:
        NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            .withDesign(.serif)
            .flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    case .monospaced:
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    case .standard:
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    guard italic else { return base }
    let slanted = base.fontDescriptor.withSymbolicTraits(.italic)
    return NSFont(descriptor: slanted, size: size) ?? base
}

// How one line of a shared text view is set. Several blocks draw in one view, so each
// block's type and the gap above it travel with the text rather than with a view.
struct TranscriptBlockStyle: Codable, Hashable, Sendable {
    // Before the text scale, so one setting still moves the whole page.
    var size: CGFloat
    var weight: CGFloat
    var design: TranscriptFontDesign
    // The air above this line. A paragraph style belongs to a whole paragraph, so only
    // the opening line of a block carries it: the newlines inside one are line breaks
    // rather than new blocks, and must not be pushed down as well.
    var spacingBefore: CGFloat
}

enum TranscriptBlockStyleAttribute: CodableAttributedStringKey {
    typealias Value = TranscriptBlockStyle
    static let name = "transcriptBlockStyle"
}

// Marks the newline standing between two blocks that share a text view. On screen it is
// one line break and a gap; copied, it has to become the blank line it looks like.
enum TranscriptBlockBreakAttribute: CodableAttributedStringKey {
    typealias Value = Bool
    static let name = "transcriptBlockBreak"
}

extension NSAttributedString.Key {
    static let transcriptBlockBreak = NSAttributedString.Key("transcriptBlockBreak")
}

// Every run of text in the transcript, prose and code alike, is drawn by a text view
// rather than by SwiftUI's Text. A Text owns a selection that stops at its own edge, so
// a page built from one per block could only ever be selected a block at a time. A text
// view reports the character under a point and takes a selected range back, which is
// what lets TranscriptSelection run one selection across the whole page.
struct SelectableText: View {
    @Environment(\.openURL) private var openURL
    @Environment(TooltipPresenter.self) private var tooltipPresenter
    @Environment(\.textScale) private var textScale
    @Environment(\.transcriptSelection) private var transcriptSelection
    @Environment(\.transcriptFind) private var transcriptFind
    @Environment(\.transcriptMessageID) private var transcriptMessageID
    @Environment(\.transcriptReply) private var transcriptReply
    @Environment(\.explorerRoots) private var explorerRoots
    @Environment(\.previewsLocalServers) private var previewsLocalServers
    @Environment(\.linkHovered) private var linkHovered
    // Optional because a text view can sit in a sheet that has no menu layer of its own.
    @Environment(MenuPresenter.self) private var menus: MenuPresenter?
    @Environment(\.showExternalNote) private var showExternalNote

    private let attributed: AttributedString
    private let size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design
    private let secondary: Bool
    private let lineSpacing: CGFloat
    private let alignment: TextAlignment
    private let width: TextWidth
    private let italic: Bool
    private let role: TranscriptTextRole
    // Off for a sent prompt, since SentPrompt already decides its links.
    private let linksLocalServers: Bool

    @State private var tooltipOwner = UUID()
    @State private var tooltipURL: URL?
    @State private var pendingTooltip: Task<Void, Never>?

    init(_ text: String,
         size: CGFloat,
         weight: Font.Weight = .regular,
         design: Font.Design = .default,
         secondary: Bool = false,
         lineSpacing: CGFloat = 0,
         alignment: TextAlignment = .leading,
         role: TranscriptTextRole = .block) {
        self.init(attributed: .inlineMarkdown(text),
                  size: size,
                  weight: weight,
                  design: design,
                  secondary: secondary,
                  lineSpacing: lineSpacing,
                  alignment: alignment,
                  width: .fills,
                  italic: false,
                  role: role,
                  linksLocalServers: true)
    }

    // Code arrives already coloured by token, and its own line breaks are the only ones
    // it should have, so it is handed over whole rather than read as markdown.
    init(code: AttributedString, size: CGFloat) {
        self.init(attributed: code,
                  size: size,
                  weight: .regular,
                  design: .monospaced,
                  secondary: false,
                  lineSpacing: 0,
                  alignment: .leading,
                  width: .fixed,
                  italic: false,
                  role: .block,
                  linksLocalServers: false)
    }

    // Several blocks drawn as one text view. Each block's type and the gap above it
    // travel in the string, so the size and weight here are only what a run that carries
    // none of its own falls back to.
    init(prose: AttributedString, lineSpacing: CGFloat = 0, width: TextWidth = .fills,
         linksLocalServers: Bool = true) {
        self.init(attributed: prose,
                  size: 13.5,
                  weight: .regular,
                  design: .default,
                  secondary: false,
                  lineSpacing: lineSpacing,
                  alignment: .leading,
                  width: width,
                  italic: false,
                  role: .block,
                  linksLocalServers: linksLocalServers)
    }

    // Text that is shown exactly as it arrived. A model's reasoning is not markdown, so
    // the asterisks and backticks it happens to contain are characters, not formatting.
    init(plain text: String,
         size: CGFloat,
         design: Font.Design = .default,
         secondary: Bool = false,
         italic: Bool = false,
         lineSpacing: CGFloat = 0,
         width: TextWidth = .fills) {
        self.init(attributed: AttributedString(text),
                  size: size,
                  weight: .regular,
                  design: design,
                  secondary: secondary,
                  lineSpacing: lineSpacing,
                  alignment: .leading,
                  width: width,
                  italic: italic,
                  role: .block,
                  linksLocalServers: false)
    }

    private init(attributed: AttributedString,
                 size: CGFloat,
                 weight: Font.Weight,
                 design: Font.Design,
                 secondary: Bool,
                 lineSpacing: CGFloat,
                 alignment: TextAlignment,
                 width: TextWidth,
                 italic: Bool,
                 role: TranscriptTextRole,
                 linksLocalServers: Bool) {
        self.attributed = attributed
        self.size = size
        self.weight = weight
        self.design = design
        self.secondary = secondary
        self.lineSpacing = lineSpacing
        self.alignment = alignment
        self.width = width
        self.italic = italic
        self.role = role
        self.linksLocalServers = linksLocalServers
    }

    var body: some View {
        let font = resolvedNSFont
        let firstBaseline = font.ascender.rounded()
        LinkAwareText(
            attributed: attributed,
            linksLocalServers: linksLocalServers && previewsLocalServers,
            font: font,
            textScale: textScale,
            color: secondary ? .secondaryLabelColor : .labelColor,
            lineSpacing: lineSpacing,
            alignment: alignment,
            width: width,
            role: role,
            selection: transcriptSelection,
            find: transcriptFind,
            messageID: transcriptMessageID,
            openLink: openLink,
            linkHoverChanged: linkHoverChanged,
            showMenu: menus.map { menus in { entries, point in menus.show(entries, at: point) } },
            reply: transcriptReply?.action,
            note: showExternalNote.show)
            // NSViewRepresentable does not pass NSTextView's baseline to SwiftUI.
            // The font metric keeps this text on the baseline of whatever it sits
            // beside, such as the marker on a list row.
            .alignmentGuide(.firstTextBaseline) { _ in
                firstBaseline
            }
            .onDisappear(perform: hideLinkTooltip)
    }

    private func linkHoverChanged(_ hovered: TranscriptLink.Hovered?) {
        pendingTooltip?.cancel()
        linkHovered?(hovered?.url)
        guard let hovered, hovered.url.isFileURL
                || (previewsLocalServers && TranscriptLink.isLocalServer(hovered.url)) else {
            tooltipPresenter.hide(owner: tooltipOwner)
            return
        }

        if tooltipURL != hovered.url {
            tooltipPresenter.hide(owner: tooltipOwner)
            tooltipOwner = UUID()
            tooltipURL = hovered.url
        }
        guard !tooltipPresenter.sourceEntered(owner: tooltipOwner) else { return }

        let owner = tooltipOwner
        pendingTooltip = Task {
            try? await Task.sleep(for: TooltipPresenter.hoverDelay)
            guard !Task.isCancelled else { return }
            tooltipPresenter.show(
                Tooltip(title: linkToolTip(for: hovered.url)) { openLink(hovered.url) },
                from: hovered.frame,
                owner: owner)
        }
    }

    private func linkToolTip(for url: URL) -> String {
        guard url.isFileURL else { return TranscriptLink.previewToolTip }
        return TranscriptLink.explorerTarget(for: url, roots: explorerRoots) == nil
            ? TranscriptLink.finderToolTip
            : TranscriptLink.explorerToolTip
    }

    private func hideLinkTooltip() {
        pendingTooltip?.cancel()
        tooltipPresenter.hide(owner: tooltipOwner)
    }

    private func openLink(_ url: URL) {
        pendingTooltip?.cancel()
        tooltipPresenter.hideAll()
        openURL(url)
    }

    private var resolvedNSFont: NSFont {
        let resolved: TranscriptFontDesign = switch design {
        case .serif: .serif
        case .monospaced: .monospaced
        default: .standard
        }
        return transcriptNSFont(size: size * textScale,
                                weight: SelectableText.nsWeight(from: weight),
                                design: resolved,
                                italic: italic)
    }

    private static func nsWeight(from weight: Font.Weight) -> NSFont.Weight {
        if weight == .ultraLight { return .ultraLight }
        if weight == .thin { return .thin }
        if weight == .light { return .light }
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        if weight == .heavy { return .heavy }
        if weight == .black { return .black }
        return .regular
    }
}

// NSTextView keeps the pointing-hand cursor over link ranges and the I-beam elsewhere,
// which SwiftUI's Text cannot do, since it exposes no per-run hover geometry.
private final class LinkTextView: NSTextView {
    var openLink: ((URL) -> Void)?
    var linkHoverChanged: ((TranscriptLink.Hovered?) -> Void)?
    var showMenu: (([MenuEntry], CGPoint) -> Void)?
    var reply: ((String) -> Void)?
    // A copy changes nothing on screen, so this is how the click shows.
    var note: ((_ text: String, _ icon: String) -> Void)?
    // Absent for a text view outside a transcript, such as one in a file preview,
    // which selects on its own exactly as AppKit intends.
    var selection: TranscriptSelection?
    weak var find: TranscriptFind?
    var reflows = true

    private var linkTrackingArea: NSTrackingArea?
    private var hoveredLink: TranscriptLink.Hovered?
    private var pressedLink: URL?
    private var linkMouseDown: NSEvent?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), showMenu != nil {
            openMenu(for: event)
            return
        }
        pressedLink = nil
        linkMouseDown = nil
        let point = convert(event.locationInWindow, from: nil)

        // A plain press on a link might still turn into a drag, so nothing is decided
        // until the pointer either moves or comes back up.
        if event.clickCount == 1,
           event.modifierFlags.intersection([.shift, .control, .option]).isEmpty,
           let link = TranscriptLink.hoveredLink(in: self, at: point) {
            pressedLink = link.url
            linkMouseDown = event
            return
        }

        guard let selection else {
            super.mouseDown(with: event)
            return
        }

        // A double or triple click takes a word or a line, which AppKit already does
        // inside one block and which no sweep across blocks would improve.
        guard event.clickCount == 1 else {
            selection.clear()
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.shift) {
            selection.extend(toWindowPoint: event.locationInWindow)
        } else {
            selection.begin(in: self, at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressedLink else {
            // A selection drag has already consumed its own press, so only a text view
            // left to AppKit still needs the release passed on.
            if selection == nil { super.mouseUp(with: event) }
            return
        }
        self.pressedLink = nil
        linkMouseDown = nil
        let point = convert(event.locationInWindow, from: nil)
        guard TranscriptLink.hoveredLink(in: self, at: point)?.url == pressedLink else { return }
        openLink?(pressedLink)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let selection else {
            linkDragForOneTextView(event)
            return
        }

        // The press landed on a link and has now moved far enough to be a drag, so the
        // selection starts from where the press was rather than from here.
        if let down = linkMouseDown {
            guard dragBegan(from: down, to: event) else { return }
            pressedLink = nil
            linkMouseDown = nil
            window?.makeFirstResponder(self)
            selection.begin(in: self, at: convert(down.locationInWindow, from: nil))
        }

        selection.extend(toWindowPoint: event.locationInWindow)
        scrollTranscript(with: event)
    }

    // A drag that runs past the edge of the transcript keeps going, so a selection can
    // reach a message that was not on screen when it started. It has to be the
    // transcript that moves: a code block sits in a scroller of its own, and letting
    // the nearest one win would shunt that block sideways instead.
    private func scrollTranscript(with event: NSEvent) {
        var outermost: NSScrollView?
        var view: NSView? = self
        while let current = view {
            if let scrollView = current as? NSScrollView { outermost = scrollView }
            view = current.superview
        }
        outermost?.documentView?.autoscroll(with: event)
    }

    // A text view that selects only within itself hands the drag straight to AppKit
    // once the press is no longer a link click.
    private func linkDragForOneTextView(_ event: NSEvent) {
        guard let down = linkMouseDown else {
            super.mouseDragged(with: event)
            return
        }
        guard dragBegan(from: down, to: event) else { return }
        pressedLink = nil
        linkMouseDown = nil
        // Replay the press and drag together so NSTextView can select from the
        // original character without treating the drag as a link click.
        NSApp.postEvent(event, atStart: true)
        super.mouseDown(with: down)
    }

    private func dragBegan(from down: NSEvent, to event: NSEvent) -> Bool {
        hypot(event.locationInWindow.x - down.locationInWindow.x,
              event.locationInWindow.y - down.locationInWindow.y) >= 4
    }

    // AppKit asks a text view for a menu on right-click and would put up its own, which
    // is a piece of another program in the middle of the page. The app's own menu takes
    // its place. A row with a menu of its own, such as a sent prompt, lays a catcher
    // over this view and still gets the click first.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func rightMouseDown(with event: NSEvent) {
        guard showMenu != nil else { return super.rightMouseDown(with: event) }
        openMenu(for: event)
    }

    // The click leaves the selection alone, so text picked out before the menu opened
    // is still what Copy takes.
    private func openMenu(for event: NSEvent) {
        guard let showMenu, let content = window?.contentView else { return }
        var entries: [MenuEntry] = []
        let point = convert(event.locationInWindow, from: nil)
        if let link = TranscriptLink.hoveredLink(in: self, at: point) {
            let isFile = link.url.isFileURL
            let address = isFile ? link.url.path : link.url.absoluteString
            entries.append(.item(isFile ? "Copy path" : "Copy link", icon: "link") { [note] in
                Pasteboard.copy(address)
                note?(isFile ? "Copied the path" : "Copied the link", "checkmark")
            })
        }
        if let text = selectedTextForMenu {
            entries.append(.item("Copy", icon: "doc.on.doc") { [note] in
                Pasteboard.copy(text)
                note?("Copied", "checkmark")
            })
            if let reply {
                entries.append(.item("Reply", icon: "arrowshape.turn.up.left") { reply(text) })
            }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item("Select all", icon: "text.cursor") { [weak self] in
            self?.window?.makeFirstResponder(self)
            self?.selectAll(nil)
        })
        showMenu(entries, FrameAnchor.fromTop(content.convert(event.locationInWindow, from: nil),
                                              in: content))
    }

    private var selectedTextForMenu: String? {
        if let selection { return selection.selectedText }
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage,
              NSMaxRange(range) <= storage.length else { return nil }
        return storage.attributedSubstring(from: range).string
    }

    // MARK: - Selection

    override func copy(_ sender: Any?) {
        guard let text = selection?.selectedText else {
            super.copy(sender)
            return
        }
        Pasteboard.copy(text)
    }

    override func selectAll(_ sender: Any?) {
        guard let selection else {
            super.selectAll(sender)
            return
        }
        selection.selectAll()
    }

    // The selection is painted here rather than left to AppKit, which draws a dimmed
    // highlight in every text view that is not the first responder. Only one block of a
    // transcript can hold that, so a selection over several would otherwise fade
    // everywhere but the block the drag started in.
    override func draw(_ dirtyRect: NSRect) {
        drawFindHighlights()
        drawSelectionHighlight()
        super.draw(dirtyRect)
    }

    private func drawFindHighlights() {
        guard let find else { return }
        let highlights = find.highlights(in: self)
        for range in highlights.all {
            fill(range, with: range == highlights.current
                    ? CodeEditorStyle.currentMatch : CodeEditorStyle.match)
        }
    }

    private func drawSelectionHighlight() {
        let characters = selectedRange()
        guard selection != nil, characters.length > 0 else { return }
        fill(characters, with: Theme.accentNSColor.withAlphaComponent(0.28))
    }

    private func fill(_ characters: NSRange, with color: NSColor) {
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        color.setFill()
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters,
                                              actualCharacterRange: nil)
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                              withinSelectedGlyphRange: glyphs,
                                              in: textContainer) { box, _ in
            box.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

    // The text container reflows when its width changes, so SwiftUI must measure its
    // new height before laying out the next block.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        // Only text that reflows has a new height to report when its width changes.
        if widthChanged, reflows { invalidateIntrinsicContentSize() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        linkTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoveredLink(with: event)
    }

    // The tracking area reports moves even where a SwiftUI control, such as the copy
    // pill, sits on top of the text. Over that control the text gives up its I-beam
    // and link hover, so the pointer reads as a click target and not as text.
    override func mouseMoved(with event: NSEvent) {
        if isCovered(at: event) {
            NSCursor.arrow.set()
            setHoveredLink(nil)
            return
        }
        super.mouseMoved(with: event)
        updateHoveredLink(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if isCovered(at: event) {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    private func isCovered(at event: NSEvent) -> Bool {
        guard let frameView = window?.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { return false }
        return !hit.isDescendant(of: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredLink(nil)
    }

    private func updateHoveredLink(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = TranscriptLink.hoveredLink(in: self, at: point).flatMap { link in
            windowFrame(for: link.frame).map { TranscriptLink.Hovered(url: link.url, frame: $0) }
        }
        setHoveredLink(hovered)
    }

    private func setHoveredLink(_ hovered: TranscriptLink.Hovered?) {
        guard hovered != hoveredLink else { return }
        hoveredLink = hovered
        ScrollActivity.shared.whenRested { [weak self] in
            guard let self, self.hoveredLink == hovered else { return }
            self.linkHoverChanged?(hovered)
        }
    }

    private func windowFrame(for rect: CGRect) -> CGRect? {
        guard let content = window?.contentView else { return nil }
        let converted = convert(rect, to: content)
        guard !content.isFlipped else { return converted }
        return CGRect(x: converted.minX,
                      y: content.bounds.height - converted.maxY,
                      width: converted.width,
                      height: converted.height)
    }
}

private struct LinkAwareText: NSViewRepresentable {
    let attributed: AttributedString
    let linksLocalServers: Bool
    let font: NSFont
    // Only for the block styles inside the string: the fallback font arrives scaled.
    let textScale: CGFloat
    let color: NSColor
    let lineSpacing: CGFloat
    let alignment: TextAlignment
    let width: TextWidth
    let role: TranscriptTextRole
    let selection: TranscriptSelection?
    let find: TranscriptFind?
    let messageID: UUID?
    let openLink: (URL) -> Void
    let linkHoverChanged: (TranscriptLink.Hovered?) -> Void
    let showMenu: (([MenuEntry], CGPoint) -> Void)?
    let reply: ((String) -> Void)?
    let note: ((_ text: String, _ icon: String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink) }

    func makeNSView(context: Context) -> NSTextView {
        let view = LinkTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        // Per-link hints belong to TooltipPresenter, including their Finder action.
        view.displaysLinkToolTips = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = width != .fixed
        view.textContainer?.heightTracksTextView = false
        // SwiftUI owns the frame. A text view that sized itself would grow or shrink
        // every time it is measured at a width it is never placed at, and then its frame
        // no longer matches where SwiftUI thinks it is, so clicks miss it.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.reflows = width != .fixed
        if width == .fixed {
            view.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        }
        view.delegate = context.coordinator
        view.linkTextAttributes = [
            .foregroundColor: Theme.accentNSColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        // The highlight is drawn by the view itself, in one colour for every block a
        // selection reaches. AppKit would instead dim it everywhere but the block the
        // drag started in, since only that one is the first responder.
        view.selectedTextAttributes = [.backgroundColor: NSColor.clear]
        view.openLink = openLink
        view.linkHoverChanged = linkHoverChanged
        view.showMenu = showMenu
        view.reply = reply
        view.note = note
        view.selection = selection
        selection?.register(view, role: role)
        view.find = find
        if let messageID { find?.register(view, messageID: messageID) }
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openLink = openLink
        (view as? LinkTextView)?.openLink = openLink
        (view as? LinkTextView)?.linkHoverChanged = linkHoverChanged
        (view as? LinkTextView)?.showMenu = showMenu
        (view as? LinkTextView)?.reply = reply
        (view as? LinkTextView)?.note = note
        (view as? LinkTextView)?.selection = selection
        // Unconditional: this is how a block joins the selection that runs across the
        // page, and a view that stopped re-registering would drop out of it.
        selection?.register(view, role: role)
        (view as? LinkTextView)?.find = find
        if let messageID { find?.register(view, messageID: messageID) }

        // Handing the view a new string throws away the layout it has already done and
        // the range it is holding, and every block in the transcript is asked to update
        // whenever anything in the pane changes. Only the blocks whose text really moved
        // pay for it.
        let content = Coordinator.Content(attributed: attributed,
                                          linksLocalServers: linksLocalServers,
                                          font: font,
                                          textScale: textScale,
                                          color: color,
                                          lineSpacing: lineSpacing,
                                          alignment: alignment)
        guard context.coordinator.applied != content else { return }
        context.coordinator.applied = content
        view.textStorage?.setAttributedString(makeNSAttributedString())
        view.invalidateIntrinsicContentSize()
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: Coordinator) {
        (view as? LinkTextView)?.selection?.unregister(view)
        (view as? LinkTextView)?.find?.unregister(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layoutManager = view.layoutManager else { return nil }

        guard width != .fixed else {
            // The width on offer says nothing here: the longest line decides how wide
            // the block is, and its scroller deals with the overflow.
            container.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            return CGSize(width: ceil(used.width), height: ceil(used.height))
        }

        guard let offered = proposal.width, offered.isFinite, offered > 0 else { return nil }
        container.containerSize = CGSize(width: offered, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height)
        guard width == .hugs else { return CGSize(width: offered, height: height) }

        // The used rect reports the width of the container rather than of the words in
        // it, so the glyphs are measured to find how much room the text really takes.
        // Claiming that re-wraps at exactly the longest line, which is the same layout,
        // so the size settles rather than shrinking away over repeated passes.
        let glyphs = layoutManager.glyphRange(for: container)
        let laidOut = ceil(layoutManager.boundingRect(forGlyphRange: glyphs, in: container).width)
        return CGSize(width: laidOut > 0 ? min(offered, laidOut) : offered, height: height)
    }

    private func makeNSAttributedString() -> NSAttributedString {
        let attributed = linksLocalServers ? self.attributed.linkingLocalServers() : self.attributed
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }

        // A run of blocks sharing this view repeats the same handful of styles, so each
        // one is built once rather than per run of text.
        var paragraphs: [TranscriptBlockStyle: NSParagraphStyle] = [:]
        func paragraphStyle(for block: TranscriptBlockStyle) -> NSParagraphStyle {
            if let known = paragraphs[block] { return known }
            let made = NSMutableParagraphStyle()
            made.setParagraphStyle(paragraph)
            made.paragraphSpacingBefore = block.spacingBefore
            paragraphs[block] = made
            return made
        }

        let result = NSMutableAttributedString()
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            // A block that brought its own type sets the run; anything else is the one
            // font this whole view was made with.
            let block = run[TranscriptBlockStyleAttribute.self]
            let blockFont = block.map {
                transcriptNSFont(size: $0.size * textScale,
                                 weight: NSFont.Weight(rawValue: $0.weight),
                                 design: $0.design,
                                 italic: false)
            } ?? font
            var runFont = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: blockFont.pointSize, weight: .regular)
                : blockFont
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits)
                runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .paragraphStyle: block.map(paragraphStyle(for:)) ?? paragraph,
            ]
            if run[TranscriptBlockBreakAttribute.self] == true {
                attrs[.transcriptBlockBreak] = true
            }
            if let link = run.link {
                attrs[.link] = link
            } else {
                // Highlighted code arrives with a colour per token. Anything that does
                // not ask for one reads as body text.
                attrs[.foregroundColor] = run.appKit.foregroundColor
                    ?? run.swiftUI.foregroundColor.map(NSColor.init)
                    ?? color
            }
            result.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return result
    }

    // A click inside an AppKit view never reaches SwiftUI's openURL environment, so the
    // link is handed back to it by hand. That is what keeps a "path:line" link opening
    // the enclosing folder in Finder rather than whatever app owns the file type.
    final class Coordinator: NSObject, NSTextViewDelegate {
        // Everything makeNSAttributedString reads. The other stored properties reach the
        // string through the font and the colour, which are resolved before they arrive.
        struct Content: Equatable {
            let attributed: AttributedString
            let linksLocalServers: Bool
            let font: NSFont
            let textScale: CGFloat
            let color: NSColor
            let lineSpacing: CGFloat
            let alignment: TextAlignment
        }

        var openLink: (URL) -> Void
        // What the view's storage was last built from. Nil until the first update, so a
        // freshly made view always gets its text.
        var applied: Content?

        init(openLink: @escaping (URL) -> Void) {
            self.openLink = openLink
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            openLink(url)
            return true
        }
    }
}

// Blocks that draw together in one text view. Most runs are several paragraphs; a block
// that keeps sibling views of its own stands alone in a run of one.
struct ProseRun: Identifiable, Equatable, Sendable {
    let id: Int
    let blocks: [MarkdownBlock]
}

// A run of prose as one text view, or a single block drawn on its own.
//
// A transcript is mostly paragraphs, so a text view for each block would run a long
// conversation to hundreds of them. Views are what scrolling costs: AppKit walks the
// whole view tree for tracking areas and SwiftUI walks the whole display list, on every
// frame, however little of it is on screen.
struct ProseRunView: View, Equatable {
    let run: ProseRun
    let projectPath: String
    let textScale: CGFloat

    nonisolated static func == (a: ProseRunView, b: ProseRunView) -> Bool {
        a.run == b.run && a.projectPath == b.projectPath && a.textScale == b.textScale
    }

    var body: some View {
        if run.blocks.count == 1, let block = run.blocks.first {
            MarkdownBlockView(block: block, projectPath: projectPath, textScale: textScale)
        } else {
            SelectableText(prose: MarkdownBlock.sharedProse(run.blocks))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Draws one parsed block in the transcript's type and palette.
// A streaming reply is re-parsed on every flush, but only its last block is still growing.
// Comparing the block lets SwiftUI leave the settled ones alone instead of rebuilding every
// attributed string in the answer several times a second.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let projectPath: String
    let textScale: CGFloat
    var centered = false

    private var textAlignment: TextAlignment { centered ? .center : .leading }
    private var frameAlignment: Alignment { centered ? .center : .leading }

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            paragraph(text)
        case .centered(let inner):
            MarkdownBlockView(block: MarkdownBlock(id: block.id, kind: inner),
                              projectPath: projectPath, textScale: textScale, centered: true)
        case .htmlPreview(let reference):
            HTMLPreview(reference: reference, projectPath: projectPath)
        case .heading(let level, let text):
            let heading = headingSpec(level)
            SelectableText(MarkdownBlock.displayText(text),
                               size: heading.size,
                               weight: heading.weight,
                               design: heading.design,
                               alignment: textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .padding(.top, level <= 2 ? 6 : 2)
        case .table(let table):
            MarkdownTableView(table: table, textScale: textScale)
        case .list(let items):
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                        marker(item)
                            .frame(minWidth: 14, alignment: .trailing)
                        paragraph(item.text, lineSpacing: 2)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16 * textScale)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let text):
            SelectableText(MarkdownBlock.displayText(text), size: 13, secondary: true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Space.lg)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent.opacity(0.35))
                        .frame(width: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    // A paragraph that holds images renders as text runs with each image between them
    // at reading size; without any it stays one piece of text.
    @ViewBuilder private func paragraph(_ text: String, lineSpacing: CGFloat = 0) -> some View {
        let parts = MarkdownBlock.resolvedParts(text) {
            TranscriptImage.resolve($0, projectPath: projectPath)
        }
        if parts.contains(where: { if case .image = $0 { true } else { false } }) {
            if parts.allSatisfy({ part in
                guard case .text(let text) = part else { return true }
                return text.allSatisfy { $0.isWhitespace || "·|".contains($0) }
            }) {
                let previews = ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if case .image(let alt, let url, let attributes) = part {
                        imagePreview(url: url, label: alt, attributes: attributes)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Space.lg) { previews }
                        .fixedSize()
                    VStack(alignment: centered ? .center : .leading, spacing: Space.lg) { previews }
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            } else {
                VStack(alignment: centered ? .center : .leading, spacing: Space.md) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let piece):
                            let trimmed = piece.trimmed
                            if !trimmed.isEmpty {
                                paragraphText(trimmed, lineSpacing: lineSpacing)
                            }
                        case .image(let alt, let url, let attributes):
                            imagePreview(url: url, label: alt, attributes: attributes)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        } else {
            paragraphText(MarkdownBlock.displayText(text), lineSpacing: lineSpacing)
        }
    }

    private func imagePreview(url: URL, label: String, attributes: MarkdownImageAttributes?) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: Space.xs) {
            InlineImageView(url: url, label: label.isEmpty ? nil : label, size: attributes)
            if !label.isEmpty, attributes?.captioned ?? true {
                Text(label)
                    .scaledText(Typography.Size.caption)
                    .multilineTextAlignment(textAlignment)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func paragraphText(_ text: String, lineSpacing: CGFloat) -> some View {
        SelectableText(text, size: 13.5, lineSpacing: lineSpacing, alignment: textAlignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    // A plain bullet is a small green disc rather than a glyph, so a list of findings
    // reads as part of the app instead of as typed punctuation. Numbers and tick boxes
    // still say what they say, so those keep their marker.
    @ViewBuilder private func marker(_ item: MarkdownListItem) -> some View {
        if item.marker.isEmpty {
            Color.clear.frame(width: 0, height: 0)
        } else if MarkdownListItem.plainBullets.contains(item.marker) {
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 5, height: 5)
                .offset(y: -3)
        } else {
            Text(item.marker)
                .scaledText(Typography.Size.body)
                .foregroundStyle(.secondary)
        }
    }

    // Sizes step down the way the app's own headers do: serif for the two big
    // levels, plain semibold below.
    private func headingSpec(_ level: Int) -> (size: CGFloat, weight: Font.Weight, design: Font.Design) {
        let heading = MarkdownBlock.headingStyle(level)
        return (heading.size, .semibold, heading.design == .serif ? .serif : .default)
    }
}

// Markdown drawn as a page. Fenced blocks are split out first, since the block parser
// deliberately handles prose only, and everything between the fences is parsed into
// blocks. A fence tagged as a chart, a trace or log lines is drawn rather than printed.
// The transcript and the file preview both draw with this, and differ only in
// what they hang on a code block and whether a long page is built as it scrolls.
struct MarkdownProse<Code: View>: View {
    let text: String
    let projectPath: String
    let textScale: CGFloat
    var lazy = false
    // Draws HTML blocks rather than printing their tags. See MarkdownBlock.parse.
    var html = false
    let codeBlock: (MessageSegment) -> Code

    init(text: String, projectPath: String, textScale: CGFloat, lazy: Bool = false, html: Bool = false,
         @ViewBuilder codeBlock: @escaping (MessageSegment) -> Code) {
        self.text = text
        self.projectPath = projectPath
        self.textScale = textScale
        self.lazy = lazy
        self.html = html
        self.codeBlock = codeBlock
    }

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: Space.lg) { blocks }
        } else {
            VStack(alignment: .leading, spacing: Space.lg) { blocks }
        }
    }

    // Adjacent prose and headings share a text view. The last block is always left on
    // its own: a streaming turn rewrites it many times a second, and a shared view would
    // rebuild - and drop the selection in - every paragraph above it each time.
    private func proseRuns(_ parsed: [MarkdownBlock]) -> [ProseRun] {
        var runs: [ProseRun] = []
        var shared: [MarkdownBlock] = []

        func flush() {
            guard let first = shared.first else { return }
            runs.append(ProseRun(id: first.id, blocks: shared))
            shared = []
        }

        for (offset, block) in parsed.enumerated() {
            let isLast = offset == parsed.count - 1
            if block.sharesATextView, !isLast, !holdsImages(block) {
                shared.append(block)
            } else {
                flush()
                runs.append(ProseRun(id: block.id, blocks: [block]))
            }
        }
        flush()
        return runs
    }

    // A paragraph with pictures in it is laid out as text around images, so it keeps the
    // views that needs. Resolving one reads the disk, so only a paragraph that could hold
    // a link is asked.
    private func holdsImages(_ block: MarkdownBlock) -> Bool {
        guard case .paragraph(let text) = block.kind, text.contains("](") else { return false }
        return MarkdownBlock.resolvedParts(text) {
            TranscriptImage.resolve($0, projectPath: projectPath)
        }
        .contains { if case .image = $0 { true } else { false } }
    }

    private var blocks: some View {
        // A document drops its HTML comments first, so a fence inside one stays hidden
        // rather than splitting the comment in two.
        let segments = html
            ? MessageSegment.split(MarkdownHTML.removingComments(text))
            : MessageSegment.split(text, resuming: true)
        let document = html ? MarkdownBlock.parse(document: segments) : [:]
        return ForEach(segments) { segment in
            if segment.isChart {
                TranscriptChartBlock(segment: segment)
                    .equatable()
                    .transition(.fadeIn)
            } else if segment.isTrace {
                TranscriptTraceBlock(segment: segment)
                    .equatable()
                    .transition(.fadeIn)
            } else if segment.isLogs {
                TranscriptLogsBlock(segment: segment)
                    .equatable()
                    .transition(.fadeIn)
            } else if segment.isCode {
                codeBlock(segment)
                    .transition(.fadeIn)
            } else {
                let settled = segment.id != segments.last?.id
                let blocks = document[segment.id]
                    ?? (settled ? MarkdownBlock.parse(settled: segment.text) : MarkdownBlock.parse(segment.text))
                ForEach(proseRuns(blocks)) { run in
                    ProseRunView(run: run,
                                 projectPath: projectPath,
                                 textScale: textScale)
                        .equatable()
                        .transition(.fadeIn)
                }
            }
        }
    }
}

// A chart in place of the block that carried it. A chart still arriving is left out
// rather than drawn from half its data, and one that arrived broken says so: dropping it
// would lose the evidence the agent gathered without admitting that it had.
struct TranscriptChartBlock: View, Equatable {
    let segment: MessageSegment

    var body: some View {
        if segment.isOpen {
            EmptyView()
        } else {
            switch TranscriptChartSpec.parse(segment.text) {
            case .success(let spec):
                TranscriptChartView(spec: spec)
            case .failure:
                Text(TranscriptChartSpec.Failure.unreadable.localizedDescription)
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(Theme.warningText)
                    .padding(.vertical, Space.xxs)
            }
        }
    }
}

// A whole file rendered for the preview pane. Built lazily, since a document can run to
// far more blocks than a message and only the part on screen needs drawing.
struct MarkdownDocumentView: View, Equatable {
    let text: String
    let basePath: String
    let textScale: CGFloat

    var body: some View {
        MarkdownProse(text: text, projectPath: basePath, textScale: textScale, lazy: true, html: true) {
            MarkdownCodeBlock(segment: $0)
                .equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Highlighting walks the whole block and builds an attributed string from it, so the
// segment is compared for the same reason a prose block is: a settled code block in an
// answer that is still streaming is rebuilt many times a second otherwise.
struct MarkdownCodeBlock: View, Equatable {
    let segment: MessageSegment

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let language = segment.language {
                Text(language.uppercased())
                    .scaledText(Typography.Size.micro, .semibold)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
            }
            if segment.isDeletion {
                Text("Deletes the commented lines")
                    .scaledText(Typography.Size.detail)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    SelectableText(code: CodeHighlight.highlight(segment.text, tag: segment.language),
                                   size: 12)
                        .padding(.trailing, 32)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fieldSurface(cornerRadius: Radius.card)
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let textScale: CGFloat
    // Tells the cells of this table apart from those of the next one, so a selection
    // running over both does not read as one grid.
    @State private var id = UUID()

    var body: some View {
        let columnWidths = preferredColumnWidths
        VStack(alignment: .leading, spacing: 0) {
            MarkdownTableRowLayout(preferredWidths: columnWidths) {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, row: 0, header: true)
                }
            }
            .background(Theme.field)
            ForEach(table.rows.indices, id: \.self) { row in
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                MarkdownTableRowLayout(preferredWidths: columnWidths) {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, row: row + 1, header: false)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .cardSurface(cornerRadius: Radius.control)
    }

    // Every row uses the same preferred widths, so columns stay aligned while wider
    // content gets more room than a short number or label.
    private func cell(_ text: String, column: Int, row: Int, header: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column)
            ? table.alignments[column] : .leading
        return SelectableText(text,
                                  size: 12.5,
                                  weight: header ? .semibold : .regular,
                                  alignment: textAlignment(alignment),
                                  role: .tableCell(table: id, row: row))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
    }

    private var preferredColumnWidths: [CGFloat] {
        table.header.indices.map { column in
            let values = [table.header[column]] + table.rows.compactMap { row in
                row.indices.contains(column) ? row[column] : nil
            }
            let longest = values.map {
                AttributedString.inlineMarkdown($0).characters.count
            }.max() ?? 0
            let contentWidth = CGFloat(longest) * 6.5 * textScale
            return min(180, max(MarkdownTableRowLayout.minimumColumnWidth, contentWidth + 20))
        }
    }

    private func textAlignment(_ alignment: MarkdownTable.ColumnAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ alignment: MarkdownTable.ColumnAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct MarkdownTableRowLayout: Layout {
    static let minimumColumnWidth: CGFloat = 52

    let preferredWidths: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let widths = columnWidths(availableWidth: proposal.width, count: subviews.count)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: widths.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let widths = columnWidths(availableWidth: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    private func columnWidths(availableWidth: CGFloat?, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let preferred = (0..<count).map { column in
            preferredWidths.indices.contains(column)
                ? max(Self.minimumColumnWidth, preferredWidths[column])
                : Self.minimumColumnWidth
        }
        guard let availableWidth, availableWidth.isFinite, availableWidth > 0 else {
            return preferred
        }

        let preferredTotal = preferred.reduce(0, +)
        if availableWidth >= preferredTotal {
            let extra = (availableWidth - preferredTotal) / CGFloat(count)
            return preferred.map { $0 + extra }
        }

        let minimumTotal = Self.minimumColumnWidth * CGFloat(count)
        guard availableWidth > minimumTotal else {
            return Array(repeating: availableWidth / CGFloat(count), count: count)
        }

        let shrinkableTotal = preferredTotal - minimumTotal
        guard shrinkableTotal > 0 else {
            return Array(repeating: availableWidth / CGFloat(count), count: count)
        }
        let scale = (availableWidth - minimumTotal) / shrinkableTotal
        return preferred.map { Self.minimumColumnWidth + ($0 - Self.minimumColumnWidth) * scale }
    }
}
