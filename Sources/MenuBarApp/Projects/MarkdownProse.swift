import SwiftUI
import UniformTypeIdentifiers

// Block-level markdown for chat prose: headings, tables, lists, quotes and rules.
// Fenced code is split out before this runs (see MessageSegment). A small hand-rolled
// parser covers what Claude Code emits and keeps the app free of a Markdown dependency.
struct MarkdownBlock: Identifiable, Equatable {
    let id: Int
    let kind: Kind

    enum Kind: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case table(MarkdownTable)
        case list([MarkdownListItem])
        case quote(String)
        case rule
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var kinds: [Kind] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            if !joined.isEmpty { kinds.append(.paragraph(joined)) }
        }

        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let level = headingLevel(trimmed) {
                flushParagraph()
                var title = String(trimmed.drop(while: { $0 == "#" }))
                // "## Title ##" closes with hashes that are decoration, not content.
                while title.hasSuffix("#") { title.removeLast() }
                kinds.append(.heading(level: level, text: title.trimmingCharacters(in: .whitespaces)))
                index += 1
            } else if isRule(trimmed) {
                flushParagraph()
                kinds.append(.rule)
                index += 1
            } else if trimmed.hasPrefix("|"),
                      index + 1 < lines.count,
                      let alignments = separatorAlignments(lines[index + 1],
                                                          columns: cells(trimmed).count) {
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
                kinds.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
            } else if listItem(lines[index]) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while index < lines.count, let item = listItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                kinds.append(.list(items))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoted.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                kinds.append(.quote(quoted.joined(separator: "\n")))
            } else {
                paragraph.append(lines[index])
                index += 1
            }
        }
        flushParagraph()
        return kinds.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
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

    // The row of dashes under a header is what makes the pipes above it a table. Its
    // colons carry each column's alignment.
    private static func separatorAlignments(_ line: String,
                                            columns: Int) -> [MarkdownTable.ColumnAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        let parts = cells(trimmed)
        guard parts.count == columns, !parts.isEmpty else { return nil }
        var alignments: [MarkdownTable.ColumnAlignment] = []
        for part in parts {
            guard part.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func sized(_ row: [String], to count: Int) -> [String] {
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }

    private static let bullets = ["•", "◦", "▪"]


    private static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix(while: { $0 == " " }).count
        let depth = min(indent / 2, bullets.count - 1)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // "* * *" is a rule, not a one-item list.
        guard !isRule(trimmed) else { return nil }
        if let range = trimmed.range(of: #"^[-*+] +"#, options: .regularExpression) {
            var body = String(trimmed[range.upperBound...])
            var marker = bullets[depth]
            if body.hasPrefix("[ ] ") {
                marker = "☐"
                body = String(body.dropFirst(4))
            } else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                marker = "☑"
                body = String(body.dropFirst(4))
            }
            return MarkdownListItem(depth: depth, marker: marker, text: body)
        }
        if let range = trimmed.range(of: #"^\d{1,3}[.)] +"#, options: .regularExpression) {
            let marker = trimmed[range.lowerBound..<range.upperBound]
                .trimmingCharacters(in: .whitespaces)
            return MarkdownListItem(depth: depth, marker: marker,
                                    text: String(trimmed[range.upperBound...]))
        }
        return nil
    }
}

// Images in prose: ![alt](path). Only a paragraph can hold one, and only a local file
// renders, so the parser keeps every piece verbatim - an image that does not resolve
// goes back into the text exactly as it was written.
extension MarkdownBlock {
    enum ParagraphPart: Equatable {
        case text(String)
        case image(alt: String, source: String)
    }

    static func paragraphParts(_ text: String) -> [ParagraphPart] {
        var parts: [ParagraphPart] = []
        var plain = ""
        var index = text.startIndex

        // Reads up to the terminator on the same line; an image never spans lines.
        func take(until terminator: Character,
                  from start: String.Index) -> (String, String.Index)? {
            var i = start
            while i < text.endIndex, !text[i].isNewline {
                if text[i] == terminator { return (String(text[start..<i]), i) }
                i = text.index(after: i)
            }
            return nil
        }

        while let bang = text.range(of: "![", range: index..<text.endIndex) {
            var parsed: (alt: String, source: String, end: String.Index)?
            // An opener inside the alt means this "![" was stray text and the real
            // image starts further in, so the candidate is abandoned in its favour.
            if let (alt, closeBracket) = take(until: "]", from: bang.upperBound),
               !alt.contains("![") {
                let openParen = text.index(after: closeBracket)
                if openParen < text.endIndex, text[openParen] == "(",
                   let (source, closeParen) = take(until: ")",
                                                   from: text.index(after: openParen)),
                   !source.trimmingCharacters(in: .whitespaces).isEmpty {
                    parsed = (alt, source, text.index(after: closeParen))
                }
            }
            if let parsed {
                plain += text[index..<bang.lowerBound]
                if !plain.isEmpty {
                    parts.append(.text(plain))
                    plain = ""
                }
                parts.append(.image(alt: parsed.alt, source: parsed.source))
                index = parsed.end
            } else {
                // Not an image after all; the "![" is ordinary text.
                plain += text[index..<bang.upperBound]
                index = bang.upperBound
            }
        }
        plain += text[index...]
        if !plain.isEmpty { parts.append(.text(plain)) }
        return parts
    }

    enum ResolvedPart: Equatable {
        case text(String)
        case image(alt: String, url: URL)
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

        for part in paragraphParts(text) {
            switch part {
            case .text(let piece):
                appendText(piece)
            case .image(let alt, let source):
                if let url = resolve(source) {
                    resolved.append(.image(alt: alt, url: url))
                } else {
                    appendText("![\(alt)](\(source))")
                }
            }
        }
        return resolved
    }
}

// Where a prose image may come from: an existing local image file, named by an absolute
// path or one relative to the project. Anything else - a web URL, a missing file, a
// non-image - stays as text, and nothing is ever fetched over the network.
enum TranscriptImage {
    static func resolve(_ source: String, projectPath: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }
        let url = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : URL(fileURLWithPath: projectPath).appendingPathComponent(trimmed)
        let file = url.standardizedFileURL
        guard let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .image) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return file
    }
}

struct MarkdownTable: Equatable {
    enum ColumnAlignment: Equatable {
        case leading, center, trailing
    }

    let header: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
}

struct MarkdownListItem: Equatable {
    // The markers that carry no meaning of their own, so the view can draw a shape
    // instead. A number or a tick box says something the shape would lose.
    static let plainBullets: Set<String> = ["•", "◦", "▪"]

    let depth: Int
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
}

enum TranscriptLink {
    static let finderToolTip = "Open in Finder"

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
}

private struct InlineMarkdownText: View {
    private let attributed: AttributedString

    init(_ text: String) {
        attributed = .inlineMarkdown(text)
    }

    var body: some View {
        Text(attributed)
            .appTooltip(attributed.hasLocalFileLink ? TranscriptLink.finderToolTip : "")
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

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            paragraph(text)
        case .heading(let level, let text):
            InlineMarkdownText(text)
                .font(headingFont(level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 6 : 2)
        case .table(let table):
            MarkdownTableView(table: table)
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        marker(item)
                            .frame(minWidth: 14, alignment: .trailing)
                        InlineMarkdownText(item.text)
                            .scaledText(13.5)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16 * textScale)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let text):
            InlineMarkdownText(text)
                .scaledText(13)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
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
    // at reading size; without any it stays one piece of text, exactly as before.
    @ViewBuilder private func paragraph(_ text: String) -> some View {
        let parts = MarkdownBlock.resolvedParts(text) {
            TranscriptImage.resolve($0, projectPath: projectPath)
        }
        if parts.contains(where: { if case .image = $0 { true } else { false } }) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let piece):
                        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { paragraphText(trimmed) }
                    case .image(let alt, let url):
                        InlineImageView(url: url, label: alt.isEmpty ? nil : alt)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            paragraphText(text)
        }
    }

    private func paragraphText(_ text: String) -> some View {
        InlineMarkdownText(text)
            .scaledText(13)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A plain bullet is a small green disc rather than a glyph, so a list of findings
    // reads as part of the app instead of as typed punctuation. Numbers and tick boxes
    // still say what they say, so those keep their marker.
    @ViewBuilder private func marker(_ item: MarkdownListItem) -> some View {
        if MarkdownListItem.plainBullets.contains(item.marker) {
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 5, height: 5)
                .offset(y: -3)
        } else {
            Text(item.marker)
                .scaledText(13)
                .foregroundStyle(.secondary)
        }
    }

    // Sizes step down the way the app's own headers do: serif for the two big
    // levels, plain semibold below.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .serif(18 * textScale)
        case 2: .serif(15.5 * textScale)
        case 3: .system(size: 14 * textScale, weight: .semibold)
        default: .system(size: 13 * textScale, weight: .semibold)
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, header: true)
                        .background(Theme.field)
                }
            }
            ForEach(table.rows.indices, id: \.self) { row in
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, header: false)
                    }
                }
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    // Every cell stretches, so columns share the width evenly and long cells wrap
    // instead of pushing the table past the page.
    private func cell(_ text: String, column: Int, header: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column)
            ? table.alignments[column] : .leading
        return InlineMarkdownText(text)
            .scaledText(12.5, header ? .semibold : .regular)
            .textSelection(.enabled)
            .multilineTextAlignment(textAlignment(alignment))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
