import AppKit

struct QuickNote: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title = ""
    var body = NoteDocument()
    var pinned = false
    var createdAt = Date.now
    var editedAt = Date.now
    var attachments: [NoteAttachment] = []
    var scopeID: String?
    var markdownSource: String?

    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : title }
    var wordCount: Int { body.text.split(whereSeparator: \.isWhitespace).filter { !["☐", "☑", "•"].contains($0) }.count }

    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let searchable = ([title, markdownSource ?? body.text] + attachments.map(\.name)).joined(separator: " ")
        return words.allSatisfy { searchable.localizedStandardContains($0) }
    }

    var bodyMarkdown: String { markdownSource ?? body.markdown }
    var markdown: String { "# \(NoteDocument.escape(displayTitle))\n\n" + bodyMarkdown + "\n" }
}

struct NoteAttachment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var byteCount: Int64
    var image: Bool
}

// Only the formatting the notebook understands goes on disk. Fonts and colours are
// resolved when read, so documents follow the current appearance and never archive objects.
struct NoteDocument: Codable, Equatable, Sendable {
    enum Block: String, Codable, Sendable, CaseIterable {
        case text, title, heading, subheading, bullet, numbered, checklist, quote, code

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
            }
        }
    }

    struct Run: Codable, Equatable, Sendable {
        var text: String
        var bold = false
        var italic = false
        var block: Block = .text
        var link: String?
    }

    var runs: [Run] = []
    var text: String { runs.map(\.text).joined() }

    @MainActor init(_ attributed: NSAttributedString) {
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let block = (attributes[.noteBlock] as? String).flatMap(Block.init(rawValue:)) ?? .text
            runs.append(Run(text: attributed.attributedSubstring(from: range).string,
                            bold: traits.contains(.bold) && ![.title, .heading, .subheading].contains(block),
                            italic: traits.contains(.italic), block: block,
                            link: Self.safeLink(attributes[.link].map { String(describing: $0) })))
        }
    }

    init(runs: [Run] = []) { self.runs = runs }

    @MainActor var attributed: NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes = Self.attributes(block: run.block, bold: run.bold, italic: run.italic)
            if let link = Self.safeLink(run.link) { attributes[.link] = link }
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

    @MainActor static func attributes(block: Block = .text, bold: Bool = false,
                                     italic: Bool = false) -> [NSAttributedString.Key: Any] {
        let size: CGFloat = block == .title ? 30 : block == .heading ? 21 : block == .subheading ? 17 : 14
        var font = block == .code ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            : NSFont.systemFont(ofSize: size, weight: bold || [.title, .heading, .subheading].contains(block) ? .semibold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 12
        if [.bullet, .numbered, .checklist, .quote].contains(block) { paragraph.headIndent = 22 }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            .noteBlock: block.rawValue
        ]
        if block == .quote { attributes[.foregroundColor] = Theme.accentNSColor }
        if block == .code || block == .quote {
            attributes[.backgroundColor] = Theme.accentNSColor.withAlphaComponent(0.07)
        }
        return attributes
    }

    static func safeLink(_ value: String?) -> String? {
        guard let value, let url = URL(string: value),
              ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        guard url.scheme?.lowercased() == "mailto" ? !url.path.isEmpty : url.host?.isEmpty == false else { return nil }
        return value
    }

    static func escape(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_{}[]<>#!|-+.=~&".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    var markdown: String {
        var lines: [(Block, [Run])] = []
        var current: [Run] = []
        for run in runs {
            let pieces = run.text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    lines.append((current.first?.block ?? run.block, current))
                    current = []
                }
                if !piece.isEmpty { var part = run; part.text = piece; current.append(part) }
            }
        }
        if !current.isEmpty { lines.append((current.first?.block ?? .text, current)) }
        var output: [String] = []
        var code: [String] = []
        func flushCode() {
            guard !code.isEmpty else { return }
            let text = code.joined(separator: "\n")
            let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            output.append("\(fence)\n\(text)\n\(fence)")
            code = []
        }
        for (block, runs) in lines {
            if block == .code { code.append(runs.map(\.text).joined()); continue }
            flushCode()
            var runs = runs
            var prefix = ""
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
            }
            let text = runs.map { run in
                guard !run.text.isEmpty else { return "" }
                let leading = String(run.text.prefix(while: \.isWhitespace))
                let remaining = run.text.dropFirst(leading.count)
                let trailing = String(remaining.reversed().prefix(while: \.isWhitespace).reversed())
                var text = Self.escape(String(remaining.dropLast(trailing.count)))
                guard !text.isEmpty else { return run.text }
                if run.italic { text = "*\(text)*" }
                if run.bold && ![.title, .heading, .subheading].contains(block) { text = "**\(text)**" }
                if let link = Self.safeLink(run.link) { text = "[\(text)](<\(link.replacingOccurrences(of: ">", with: "%3E"))>)" }
                return leading + text + trailing
            }.joined()
            output.append(prefix + text)
        }
        flushCode()
        return output.joined(separator: "\n\n")
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
}
