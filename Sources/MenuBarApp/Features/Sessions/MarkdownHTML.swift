import Foundation

// HTML that a Markdown document carries as blocks of its own, the way a README opens
// with a centred logo and title. A document preview draws it instead of printing the
// tags. Only what has a Markdown equivalent comes through: images, links, headings,
// paragraphs, lists, line breaks, emphasis and centring. Any other tag gives up its
// markup and keeps its text, and comments, scripts and styles go entirely.
//
// Block boundaries follow CommonMark: a block tag opens an HTML block anywhere, an
// inline tag only on a line that holds nothing but tags, and either runs to the next
// blank line. A comment, a script or a style runs to its closing mark instead.
enum MarkdownHTML {
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "center", "dd",
        "details", "dialog", "div", "dl", "dt", "figcaption", "figure", "footer",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "html", "li", "main", "nav",
        "ol", "p", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
        "tr", "ul",
    ]
    private static let inlineTags: Set<String> = [
        "a", "b", "br", "code", "em", "i", "img", "kbd", "picture", "small", "source",
        "span", "strong", "sub", "sup",
    ]
    // Their content is never shown, and they run to their closing tag.
    private static let hiddenTags: Set<String> = ["script", "style"]
    // Containers that cannot hold Markdown, so a blank line closes them even when the
    // closing tag never came.
    private static let leafTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "summary", "dt", "td", "th"]

    // The line after the last one of the HTML block that starts at `start`, or nil when
    // that line does not open one. A block made of inline tags cannot interrupt a paragraph.
    static func blockEnd(_ lines: [String], from start: Int, inParagraph: Bool) -> Int? {
        let line = lines[start]
        guard line.prefix(while: { $0 == " " }).count < 4 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<") else { return nil }

        func through(_ closing: String, searchingFrom offset: Int) -> Int {
            var index = start
            var from = trimmed.index(trimmed.startIndex, offsetBy: offset)
            var text = trimmed
            while index < lines.count {
                if text.range(of: closing, options: .caseInsensitive, range: from..<text.endIndex) != nil {
                    return index + 1
                }
                index += 1
                if index < lines.count { text = lines[index]; from = text.startIndex }
            }
            return lines.count
        }
        func toBlankLine() -> Int {
            var index = start + 1
            while index < lines.count, !lines[index].trimmed.isEmpty { index += 1 }
            return index
        }

        if trimmed.hasPrefix("<!--") { return through("-->", searchingFrom: 4) }
        guard let name = tagName(at: trimmed) else { return nil }
        if hiddenTags.contains(name), !trimmed.hasPrefix("</") { return through("</\(name)>", searchingFrom: 1) }
        if blockTags.contains(name) { return toBlankLine() }
        if inlineTags.contains(name), !inParagraph, holdsOnlyTags(trimmed) { return toBlankLine() }
        return nil
    }

    // The lowercased name of the tag that `text` opens with, if it is written as one.
    private static func tagName(at text: String) -> String? {
        var rest = text.dropFirst()
        if rest.first == "/" { rest = rest.dropFirst() }
        guard let first = rest.first, first.isASCII, first.isLetter else { return nil }
        let name = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let after = rest.dropFirst(name.count)
        guard after.isEmpty || after.first == ">" || after.first!.isWhitespace || after.hasPrefix("/>") else { return nil }
        return name.lowercased()
    }

    private static func holdsOnlyTags(_ line: String) -> Bool {
        tokens(line).allSatisfy { token in
            if case .text(let text) = token { return text.allSatisfy(\.isWhitespace) }
            return true
        }
    }

    // MARK: - Reading

    enum Token: Equatable {
        case text(String)
        case open(String, [String: String])
        case close(String)
    }

    static func tokens(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var index = html.startIndex
        func flush() {
            if !text.isEmpty { tokens.append(.text(decodeEntities(text))); text = "" }
        }
        while index < html.endIndex {
            let rest = html[index...]
            if rest.hasPrefix("<!--") {
                flush()
                index = rest.range(of: "-->")?.upperBound ?? html.endIndex
                continue
            }
            if rest.hasPrefix("<!") || rest.hasPrefix("<?"), let end = rest.firstIndex(of: ">") {
                flush()
                index = html.index(after: end)
                continue
            }
            if rest.first == "<", let tag = readTag(rest) {
                flush()
                index = tag.end
                switch tag.token {
                case .open(let name, _) where hiddenTags.contains(name):
                    tokens.append(tag.token)
                    let closing = html[index...].range(of: "</\(name)", options: .caseInsensitive)
                    index = closing.flatMap { html[$0.upperBound...].firstIndex(of: ">") }
                        .map { html.index(after: $0) } ?? html.endIndex
                    tokens.append(.close(name))
                default:
                    tokens.append(tag.token)
                }
                continue
            }
            text.append(html[index])
            index = html.index(after: index)
        }
        flush()
        return tokens
    }

    private static func readTag(_ text: Substring) -> (token: Token, end: String.Index)? {
        guard let name = tagName(at: String(text.prefix(64))) else { return nil }
        let closing = text.dropFirst().first == "/"
        var index = text.index(text.startIndex, offsetBy: (closing ? 2 : 1) + name.count)
        var attributes: [String: String] = [:]
        while index < text.endIndex {
            let character = text[index]
            if character == ">" {
                return (closing ? .close(name) : .open(name, attributes), text.index(after: index))
            }
            if character.isWhitespace || character == "/" { index = text.index(after: index); continue }
            let key = text[index...].prefix { !$0.isWhitespace && !"=>/".contains($0) }
            guard !key.isEmpty else { return nil }
            index = key.endIndex
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            var value = ""
            if index < text.endIndex, text[index] == "=" {
                index = text.index(after: index)
                while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
                guard index < text.endIndex else { return nil }
                if text[index] == "\"" || text[index] == "'" {
                    let quote = text[index]
                    let start = text.index(after: index)
                    guard let end = text[start...].firstIndex(of: quote) else { return nil }
                    value = String(text[start..<end])
                    index = text.index(after: end)
                } else {
                    let bare = text[index...].prefix { !$0.isWhitespace && $0 != ">" }
                    value = String(bare)
                    index = bare.endIndex
                }
            }
            attributes[key.lowercased()] = decodeEntities(value)
        }
        return nil
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…",
        "middot": "·", "bull": "•", "rarr": "→", "larr": "←", "times": "×",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            rest = rest[amp...]
            guard let semicolon = rest.prefix(34).firstIndex(of: ";") else {
                result.append("&"); rest = rest.dropFirst(); continue
            }
            let body = rest[rest.index(after: rest.startIndex)..<semicolon]
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = namedEntities[String(body)]
            }
            if let decoded {
                result += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result.append("&"); rest = rest.dropFirst()
            }
        }
        return result + rest
    }

    // MARK: - Building blocks

    // The text with its HTML comment blocks blanked out, leaving code fences alone. It
    // runs before the text is split at its fences, so a fence inside a comment, such as
    // code commented out, stays hidden with the rest of the comment. A blank line takes
    // each comment's place, so the paragraphs either side stay apart.
    static func removingComments(_ text: String) -> String {
        guard text.contains("<!--") else { return text }
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var fence: Fence?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let open = fence {
                if let close = Fence(line), open.isClosed(by: close) { fence = nil }
            } else if let opened = Fence(line), opened.opens {
                fence = opened
            } else if line.prefix(while: { $0 == " " }).count < 4,
                      line.trimmingCharacters(in: .whitespaces).hasPrefix("<!--"),
                      let end = blockEnd(lines, from: index, inParagraph: false) {
                kept.append("")
                index = end
                continue
            }
            kept.append(line)
            index += 1
        }
        return kept.joined(separator: "\n")
    }

    // Reads the HTML blocks of one document in order. Containers stay open from one
    // block to the next, so a `<div align="center">` on its own, Markdown, then `</div>`
    // centres the Markdown between them.
    struct Reader {
        // An inline element still open, and where its content starts in `text`. Its
        // Markdown is written when it closes, once its content is known.
        private enum Span: Equatable {
            case strong, emphasis, code
            case link(String?)
        }

        private var containers: [(name: String, centered: Bool)] = []
        private var heading: Int?
        private var text = ""
        private var spans: [(span: Span, start: Int)] = []
        private var lists: [(ordered: Bool, next: Int)] = []
        private var items: [MarkdownListItem] = []
        private var itemMarker: String?
        private var kinds: [MarkdownBlock.Kind] = []

        var centered: Bool { containers.contains(where: \.centered) }
        private var inCode: Bool { spans.contains { $0.span == .code } }

        mutating func read(_ html: String) -> [MarkdownBlock.Kind] {
            for token in MarkdownHTML.tokens(html) { take(token) }
            flushText()
            flushList()
            while let last = containers.last, MarkdownHTML.leafTags.contains(last.name) { containers.removeLast() }
            heading = nil
            defer { kinds = [] }
            return kinds
        }

        private mutating func take(_ token: Token) {
            switch token {
            case .text(let piece):
                var collapsed = piece.replacing(/\s+/, with: " ")
                // HTML shows one space where two runs of text meet with space on both sides.
                if collapsed.first == " ", text.last?.isWhitespace ?? true { collapsed.removeFirst() }
                // A code span shows its content as it is; an escape there would print.
                text += inCode ? collapsed : MarkdownHTML.escape(collapsed)
            case .open(let name, let attributes):
                open(name, attributes)
            case .close(let name):
                close(name)
            }
        }

        private static func span(for name: String) -> Span? {
            switch name {
            case "b", "strong": .strong
            case "i", "em": .emphasis
            case "code", "kbd": .code
            default: nil
            }
        }

        private mutating func open(_ name: String, _ attributes: [String: String]) {
            if let span = Self.span(for: name) {
                spans.append((span, text.count))
                return
            }
            switch name {
            case "br":
                text += "\n"
            case "hr":
                flushText(); flushList()
                kinds.append(.rule)
            case "img":
                guard let source = attributes["src"]?.trimmed, !source.isEmpty else { return }
                let alt = MarkdownHTML.escape(attributes["alt"] ?? attributes["title"] ?? "")
                let image = MarkdownImageAttributes(width: attributes["width"].flatMap(MarkdownImageAttributes.points),
                                                    height: attributes["height"].flatMap(MarkdownImageAttributes.points),
                                                    captioned: false)
                text += "![\(alt)](\(MarkdownImageAttributes.encoded(source)))\(image.markdown)"
            case "a":
                spans.append((.link(attributes["href"]?.trimmed), text.count))
            case "ul", "ol":
                flushText()
                lists.append((name == "ol", Int(attributes["start"] ?? "") ?? 1))
            case "li":
                flushText()
                guard let list = lists.last else { return }
                if list.ordered {
                    itemMarker = "\(list.next)."
                    lists[lists.count - 1].next += 1
                } else {
                    itemMarker = MarkdownBlock.bullets[min(lists.count - 1, MarkdownBlock.bullets.count - 1)]
                }
            case _ where MarkdownHTML.blockTags.contains(name):
                flushText()
                // A paragraph closes when another block opens, as it does in a browser.
                if containers.last?.name == "p" { containers.removeLast() }
                let align = attributes["align"]?.lowercased()
                let style = (attributes["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
                containers.append((name, name == "center" || align == "center" || style.contains("text-align:center")))
                if name.count == 2, name.first == "h", let level = name.last?.wholeNumberValue {
                    heading = level
                }
            default:
                break
            }
        }

        private mutating func close(_ name: String) {
            let closing: Span? = name == "a" ? .link(nil) : Self.span(for: name)
            if let closing {
                // The innermost element of this kind closes. Any left open inside it end
                // with it and keep their text without markup, as a browser would show it.
                guard let index = spans.lastIndex(where: { open in
                    if case .link = open.span, case .link = closing { return true }
                    return open.span == closing
                }) else { return }
                let open = spans[index]
                spans.removeSubrange(index...)
                wrap(open.span, from: open.start)
                return
            }
            switch name {
            case "ul", "ol":
                flushText()
                if !lists.isEmpty { lists.removeLast() }
                if lists.isEmpty { flushList() }
            case "li":
                flushText()
                itemMarker = nil
            case _ where MarkdownHTML.blockTags.contains(name):
                flushText()
                if let index = containers.lastIndex(where: { $0.name == name }) {
                    containers.removeSubrange(index...)
                }
                if name.count == 2, name.first == "h", name.last?.isNumber == true { heading = nil }
            default:
                break
            }
        }

        // Writes the Markdown for an inline element around the content it gathered.
        private mutating func wrap(_ span: Span, from offset: Int) {
            let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
            let content = String(text[start...])
            switch span {
            case .code:
                guard !content.trimmed.isEmpty else { return }
                text.replaceSubrange(start..., with: MarkdownHTML.codeSpan(content))
            case .strong, .emphasis:
                // Markdown only reads a delimiter that touches its text, so the space a
                // tag held at either end goes outside it.
                let core = content.trimmed
                guard !core.isEmpty else { return }
                let leading = String(content.prefix { $0.isWhitespace })
                let trailing = String(content.reversed().prefix { $0.isWhitespace }.reversed())
                let mark = span == .strong ? "**" : "*"
                text.replaceSubrange(start..., with: leading + mark + core + mark + trailing)
            case .link(let href):
                guard let href, !href.isEmpty, !href.lowercased().hasPrefix("javascript:"),
                      !content.trimmed.isEmpty else { return }
                let destination = MarkdownImageAttributes.encoded(href)
                if content.contains("![") {
                    // A linked picture, such as a badge, shows the picture and keeps the
                    // link for when the picture cannot be drawn.
                    text.replaceSubrange(start..., with: content.replacingOccurrences(
                        of: "{\(MarkdownImageAttributes.htmlClass)",
                        with: "{\(MarkdownImageAttributes.htmlClass) link=\(destination)"))
                } else {
                    text.replaceSubrange(start..., with: "[\(content.trimmed)](\(destination))")
                }
            }
        }

        // Ends the paragraph being gathered. Whitespace around a line break is HTML
        // layout, not content, and a paragraph of nothing but whitespace is no paragraph.
        private mutating func flushText() {
            defer { text = ""; spans = [] }
            let body = text.components(separatedBy: "\n").map(\.trimmed).joined(separator: "\n").trimmed
            guard !body.isEmpty else { return }
            if !lists.isEmpty {
                items.append(MarkdownListItem(depth: min(lists.count - 1, MarkdownBlock.bullets.count - 1),
                                              marker: itemMarker ?? "", text: body))
                itemMarker = nil
                return
            }
            flushList()
            guard let heading else { return append(.paragraph(body)) }
            // A heading is drawn as text, which has no room for a picture, so a logo in a
            // heading stands as a paragraph of its own on the side it was written.
            let parts = MarkdownBlock.paragraphParts(body)
            let images = parts.compactMap { part -> String? in
                guard case .image(let alt, let source, let attributes) = part else { return nil }
                return "![\(alt)](\(source))\(attributes?.markdown ?? "")"
            }
            guard !images.isEmpty else {
                return append(.heading(level: heading, text: body.replacingOccurrences(of: "\n", with: " ")))
            }
            let title = parts.map { part -> String in
                switch part {
                case .text(let piece): piece
                case .link(let label, let source): "[\(label)](\(source))"
                case .image: ""
                }
            }.joined().replacing(/\s+/, with: " ").trimmed
            let picture = MarkdownBlock.Kind.paragraph(images.joined(separator: " "))
            let imageFirst: Bool
            if case .image? = parts.first(where: { if case .text(let piece) = $0 { !piece.trimmed.isEmpty } else { true } }) {
                imageFirst = true
            } else {
                imageFirst = false
            }
            if imageFirst { append(picture) }
            if !title.isEmpty { append(.heading(level: heading, text: title)) }
            if !imageFirst { append(picture) }
        }

        private mutating func append(_ kind: MarkdownBlock.Kind) {
            kinds.append(centered ? .centered(kind) : kind)
        }

        private mutating func flushList() {
            guard !items.isEmpty else { return }
            kinds.append(.list(items))
            items = []
        }
    }

    // A code span that holds `content` exactly: its fence is longer than any run of
    // backticks inside, and a backtick or space at an end gets the padding Markdown removes.
    static func codeSpan(_ content: String) -> String {
        let longest = content.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: longest + 1)
        let padded = content.hasPrefix("`") || content.hasSuffix("`")
            || (content.hasPrefix(" ") && content.hasSuffix(" ") && content.contains { $0 != " " })
            ? " \(content) " : content
        return fence + padded + fence
    }

    // Text inside an HTML block is not Markdown, so a character Markdown would read as
    // markup is kept as itself. Entities were decoded already, so an ampersand that now
    // looks like one is text too.
    static func escape(_ text: String) -> String {
        var result = ""
        for index in text.indices {
            let character = text[index]
            if "\\`*_[]<>!~{".contains(character)
                || character == "&" && NoteDocument.startsEntity(text[index...]) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
