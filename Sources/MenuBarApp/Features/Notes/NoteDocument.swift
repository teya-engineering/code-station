import AppKit

// Only the formatting the editor understands goes on disk. Fonts and colours are
// resolved when read, so documents follow the current appearance and never archive objects.
struct NoteDocument: Codable, Equatable, Sendable {
    enum Block: String, Codable, Sendable, CaseIterable {
        // Literal is Markdown the editor cannot show as formatting. A table is drawn as a
        // grid and changed through its own controls, never by typing into the text. Both
        // keep their source as written and are never offered as a style.
        case text, title, heading, subheading, bullet, numbered, checklist, quote, code, literal, table

        var title: String {
            switch self {
            case .text: "Text"
            case .title: "Title"
            case .heading: "Heading"
            case .subheading: "Subheading"
            case .bullet: "Bulleted list"
            case .numbered: "Numbered list"
            case .checklist: "Checklist"
            case .quote: "Quote"
            case .code: "Code block"
            case .literal: "Markdown source"
            case .table: "Table"
            }
        }

        static let lists: Set<Block> = [.bullet, .numbered, .checklist]
        static let styles = allCases.filter { $0 != .literal && $0 != .table }
    }

    struct Run: Codable, Equatable, Sendable {
        var text: String
        var bold = false
        var italic = false
        var block: Block = .text
        var link: String?
        var code = false
        // How deep a list item sits. Zero for every other block.
        var indent = 0
    }

    var runs: [Run] = []
    var text: String { runs.map(\.text).joined() }

    @MainActor init(_ attributed: NSAttributedString) {
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var block = (attributes[.noteBlock] as? String).flatMap(Block.init(rawValue:)) ?? .text
            var text = attributed.attributedSubstring(from: range).string
            // A table is one attachment character standing in for its source. Text typed
            // or pasted beside it can pick up its attributes, but only the attachment
            // itself is the table.
            if block == .table || text.contains(Self.attachmentCharacter) {
                if let source = NoteTableCell.source(of: attributes[.attachment]),
                   text == String(Self.attachmentCharacter) {
                    runs.append(Run(text: source, block: .table))
                    return
                }
                text.removeAll { $0 == Self.attachmentCharacter }
                if block == .table { block = .text }
                if text.isEmpty { return }
            }
            runs.append(Run(text: text,
                            bold: traits.contains(.bold) && ![.title, .heading, .subheading].contains(block),
                            italic: traits.contains(.italic), block: block,
                            link: Self.keptLink(attributes[.link].map { String(describing: $0) }),
                            code: attributes[.noteCode] as? Bool ?? false,
                            indent: attributes[.noteIndent] as? Int ?? 0))
        }
    }

    init(runs: [Run] = []) { self.runs = runs }

    @MainActor var attributed: NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            if run.block == .table {
                var attributes = Self.attributes()
                attributes[.noteBlock] = Block.table.rawValue
                // Line spacing would add a strip under the grid that a selection fills.
                let paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 12
                attributes[.paragraphStyle] = paragraph
                attributes[.attachment] = NoteTableCell.attachment(source: run.text)
                result.append(NSAttributedString(string: String(Self.attachmentCharacter), attributes: attributes))
                continue
            }
            var attributes = Self.attributes(block: run.block, bold: run.bold, italic: run.italic,
                                             code: run.code, indent: run.indent)
            if let link = Self.keptLink(run.link) { attributes[.link] = link }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        var offset = 0
        while offset < result.length {
            let range = (result.string as NSString).paragraphRange(for: NSRange(location: offset, length: 0))
            if result.attribute(.noteBlock, at: offset, effectiveRange: nil) as? String == Block.checklist.rawValue,
               (result.string as NSString).substring(with: range).hasPrefix("☑") {
                result.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                      .foregroundColor: NSColor.secondaryLabelColor], range: range)
            }
            offset = NSMaxRange(range)
        }
        return result
    }

    @MainActor static func attributes(block: Block = .text, bold: Bool = false, italic: Bool = false,
                                     code: Bool = false, indent: Int = 0) -> [NSAttributedString.Key: Any] {
        let size: CGFloat = block == .title ? 30 : block == .heading ? 21 : block == .subheading ? 17 : 14
        var font = block == .code || block == .literal ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            : code ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: bold ? .semibold : .regular)
            : NSFont.systemFont(ofSize: size, weight: bold || [.title, .heading, .subheading].contains(block) ? .semibold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let indent = Block.lists.contains(block) ? indent : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 12
        paragraph.firstLineHeadIndent = CGFloat(indent) * 22
        if [.bullet, .numbered, .checklist, .quote].contains(block) { paragraph.headIndent = CGFloat(indent + 1) * 22 }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            .noteBlock: block.rawValue
        ]
        if indent > 0 { attributes[.noteIndent] = indent }
        if code && block != .code { attributes[.noteCode] = true }
        if block == .quote { attributes[.foregroundColor] = Theme.accentNSColor }
        if block == .literal { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        if block == .code || block == .quote || code {
            attributes[.backgroundColor] = Theme.accentNSColor.withAlphaComponent(0.07)
        }
        return attributes
    }

    static let attachmentCharacter: Character = "\u{FFFC}"

    static func safeLink(_ value: String?) -> String? {
        guard let value, let url = URL(string: value),
              ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        guard url.scheme?.lowercased() == "mailto" ? !url.path.isEmpty : url.host?.isEmpty == false else { return nil }
        return value
    }

    // A link a document already holds: a web or mail link, or a path to a file beside it,
    // which project documents use to point at each other. New links still go through
    // safeLink, so a typed address without a scheme is not mistaken for a path.
    static func keptLink(_ value: String?) -> String? {
        if let web = safeLink(value) { return web }
        guard let value, !value.isEmpty, !value.hasPrefix("//"), !value.contains(where: \.isWhitespace),
              let url = URL(string: value), url.scheme == nil, url.host == nil else { return nil }
        return value
    }

    // Markdown reads "&amp;" or "&#38;" as a character reference, but a lone "&" is just text.
    static func startsEntity(_ text: Substring) -> Bool {
        text.range(of: #"^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{0,31});"#,
                   options: .regularExpression) != nil
    }

    static func escape(_ text: String, lineStart: Bool = false) -> String {
        var result = ""
        for index in text.indices {
            let character = text[index]
            if "\\`*_[]<>#!|~".contains(character) || character == "&" && startsEntity(text[index...]) {
                result.append("\\")
            }
            result.append(character)
        }
        // These marks only start a list, a quote or a rule at the beginning of a line.
        if lineStart, let first = result.first, "-+=>".contains(first) {
            result.insert("\\", at: result.startIndex)
        } else if lineStart, let number = result.range(of: #"^\d+[.)]"#, options: .regularExpression) {
            result.insert("\\", at: result.index(before: number.upperBound))
        }
        return result
    }

    var markdown: String {
        let blocks = markdownBlocks
        return zip(blocks.indices, blocks).map { index, block in
            (index == 0 ? "" : Self.separator(blocks[index - 1].block, block.block)) + block.text
        }.joined()
    }

    // List items sit on their own lines so the list stays tight. Every other block needs a
    // blank line, or the next line would carry on the paragraph above it.
    static func separator(_ previous: Block, _ next: Block) -> String {
        Block.lists.contains(previous) && Block.lists.contains(next) ? "\n" : "\n\n"
    }

    // One entry for each paragraph of the document, with each run of code lines as one block.
    var markdownBlocks: [(block: Block, text: String)] {
        var lines: [(Block, [Run])] = []
        var current: [Run] = []
        for run in runs {
            // A table's source spans several lines but is one block, and it never shares
            // a line with text written next to it.
            if run.block == .table {
                if !current.isEmpty { lines.append((current[0].block, current)) }
                current = [run]
                continue
            }
            let pieces = run.text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    lines.append((current.first?.block ?? run.block, current))
                    current = []
                }
                if !piece.isEmpty {
                    if current.first?.block == .table { lines.append((.table, current)); current = [] }
                    var part = run; part.text = piece; current.append(part)
                }
            }
        }
        if !current.isEmpty { lines.append((current.first?.block ?? .text, current)) }
        var output: [(block: Block, text: String)] = []
        // Code and literal lines are kept whole, blank lines included, until the block ends.
        var verbatim: (block: Block, lines: [String])?
        // Where each open list item's text starts, so a nested item lines up under it.
        var listContent: [Int] = []
        func flushCode() {
            guard let (block, lines) = verbatim else { return }
            verbatim = nil
            let text = lines.joined(separator: "\n")
            guard block == .code else { output.append((block, text)); return }
            let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            output.append((.code, "\(fence)\n\(text)\n\(fence)"))
        }
        for (block, runs) in lines {
            if block == .table {
                flushCode()
                output.append((.table, runs.map(\.text).joined()))
                listContent = []
                continue
            }
            if block == .code || block == .literal {
                if verbatim?.block != block { flushCode() }
                verbatim = (block, (verbatim?.lines ?? []) + [runs.map(\.text).joined()])
                listContent = []
                continue
            }
            flushCode()
            var runs = runs
            var prefix = ""
            var indentation = ""
            if let first = runs.first {
                let text = runs.map(\.text).joined()
                let marker = Self.markerLength(text, block: block)
                var remaining = marker
                for index in runs.indices where remaining > 0 {
                    let count = min(remaining, runs[index].text.count)
                    runs[index].text = String(runs[index].text.dropFirst(count))
                    remaining -= count
                }
                switch block {
                case .title: prefix = "# "
                case .heading: prefix = "## "
                case .subheading: prefix = "### "
                case .bullet: prefix = "- "
                case .numbered: prefix = "1. "
                case .checklist: prefix = first.text.hasPrefix("☑") ? "- [x] " : "- [ ] "
                case .quote: prefix = "> "
                default: break
                }
                if Block.lists.contains(block) {
                    let level = min(first.indent, listContent.count)
                    listContent.removeSubrange(level...)
                    let start = listContent.last ?? 0
                    indentation = String(repeating: " ", count: start)
                    listContent.append(start + prefix.count)
                } else {
                    listContent = []
                }
            }
            let first = runs.firstIndex { !$0.text.isEmpty }
            let text = zip(runs.indices, runs).map { index, run in
                guard !run.text.isEmpty else { return "" }
                if run.code && block != .code { return Self.codeSpan(run) }
                let leading = String(run.text.prefix(while: \.isWhitespace))
                let remaining = run.text.dropFirst(leading.count)
                let trailing = String(remaining.reversed().prefix(while: \.isWhitespace).reversed())
                var text = Self.escape(String(remaining.dropLast(trailing.count)), lineStart: index == first)
                guard !text.isEmpty else { return run.text }
                if run.italic { text = "*\(text)*" }
                if run.bold && ![.title, .heading, .subheading].contains(block) { text = "**\(text)**" }
                if let link = Self.keptLink(run.link) { text = "[\(text)](<\(link.replacingOccurrences(of: ">", with: "%3E"))>)" }
                return leading + text + trailing
            }.joined()
            output.append((block, indentation + prefix + text))
        }
        flushCode()
        return output
    }

    private static func codeSpan(_ run: Run) -> String {
        let longest = run.text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: longest + 1)
        // A backtick at either end would join the fence, and Markdown drops one space from
        // each side of a span, so both get an extra space that the reader takes off again.
        let padded = run.text.hasPrefix("`") || run.text.hasSuffix("`")
            || (run.text.hasPrefix(" ") && run.text.hasSuffix(" ") && run.text.contains { $0 != " " }) ? " \(run.text) " : run.text
        var text = fence + padded + fence
        if run.italic { text = "*\(text)*" }
        if run.bold && ![.title, .heading, .subheading].contains(run.block) { text = "**\(text)**" }
        if let link = keptLink(run.link) { text = "[\(text)](<\(link.replacingOccurrences(of: ">", with: "%3E"))>)" }
        return text
    }

    static func markerLength(_ text: String, block: Block) -> Int {
        if [.bullet, .checklist].contains(block), ["• ", "☐ ", "☑ "].contains(where: text.hasPrefix) { return 2 }
        if block == .numbered, let range = text.range(of: #"^\d+\. "#, options: .regularExpression) {
            return text.distance(from: text.startIndex, to: range.upperBound)
        }
        return 0
    }
}

extension NSAttributedString.Key {
    static let noteBlock = NSAttributedString.Key("codeStationNoteBlock")
    static let noteCode = NSAttributedString.Key("codeStationNoteCode")
    static let noteIndent = NSAttributedString.Key("codeStationNoteIndent")
}

// Notes saved before a field existed leave it out, so every field falls back to its default.
extension NoteDocument.Run {
    private enum CodingKeys: String, CodingKey { case text, bold, italic, block, link, code, indent }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        block = try container.decodeIfPresent(NoteDocument.Block.self, forKey: .block) ?? .text
        link = try container.decodeIfPresent(String.self, forKey: .link)
        code = try container.decodeIfPresent(Bool.self, forKey: .code) ?? false
        indent = try container.decodeIfPresent(Int.self, forKey: .indent) ?? 0
    }
}
