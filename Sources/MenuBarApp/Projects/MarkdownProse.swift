import SwiftUI

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

struct MarkdownTable: Equatable {
    enum ColumnAlignment: Equatable {
        case leading, center, trailing
    }

    let header: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
}

struct MarkdownListItem: Equatable {
    let depth: Int
    let marker: String
    let text: String
}

// Inline markdown only: `code`, bold, italics and links render, newlines stay as
// they are. Block structure is the parser's job, so none of it reaches here.
extension AttributedString {
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// Draws one parsed block in the transcript's type and palette.
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            Text(.inlineMarkdown(text))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(.inlineMarkdown(text))
                .font(headingFont(level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 6 : 2)
        case .table(let table):
            MarkdownTableView(table: table)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.marker)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(.inlineMarkdown(item.text))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let text):
            Text(.inlineMarkdown(text))
                .font(.system(size: 13))
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

    // Sizes step down the way the app's own headers do: serif for the two big
    // levels, plain semibold below.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .serif(18)
        case 2: .serif(15.5)
        case 3: .system(size: 14, weight: .semibold)
        default: .system(size: 13, weight: .semibold)
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
        return Text(.inlineMarkdown(text))
            .font(.system(size: 12.5, weight: header ? .semibold : .regular))
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
