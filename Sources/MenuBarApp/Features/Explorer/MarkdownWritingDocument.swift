import Foundation

enum MarkdownEditorMode: String, CaseIterable {
    case write = "Write", source = "Source", preview = "Preview"
}

// Source stays authoritative. Only syntax that the notebook can express is admitted
// to Write; everything else remains editable in Source without a lossy conversion.
struct MarkdownWritingDocument {
    let source: String
    let document: NoteDocument

    init(source: String, document: NoteDocument) {
        self.source = source
        self.document = document
    }

    init?(_ source: String) {
        self.source = source
        guard !source.contains("\r") else { return nil }
        var runs: [NoteDocument.Run] = []
        let lines = source.components(separatedBy: "\n")
        var index = 0
        var previousWasText = false
        // The start column and text column of each open list item, outermost first.
        var lists: [(start: Int, content: Int)] = []
        while index < lines.count {
            var line = lines[index]
            index += 1
            if line.isEmpty { previousWasText = false; continue }
            var block = NoteDocument.Block.text
            var marker = ""
            if line == "```" {
                var code: [String] = []
                while index < lines.count && lines[index] != "```" {
                    code.append(lines[index]); index += 1
                }
                guard index < lines.count, !code.isEmpty else { return nil }
                index += 1
                if !runs.isEmpty { runs.append(.init(text: "\n")) }
                runs.append(.init(text: code.joined(separator: "\n"), block: .code))
                previousWasText = false
                lists = []
                continue
            }
            let leading = line.prefix(while: { $0 == " " }).count
            line.removeFirst(leading)
            let prefixes: [(String, NoteDocument.Block, String)] = [
                ("### ", .subheading, ""), ("## ", .heading, ""), ("# ", .title, ""),
                ("- [ ] ", .checklist, "☐ "), ("- [x] ", .checklist, "☑ "),
                ("- ", .bullet, "• "), ("> ", .quote, "")
            ]
            if let prefix = prefixes.first(where: { line.hasPrefix($0.0) }) {
                line.removeFirst(prefix.0.count); block = prefix.1; marker = prefix.2
            } else if let range = line.range(of: #"^1\. "#, options: .regularExpression) {
                line.removeSubrange(range); block = .numbered; marker = "1. "
            }
            var depth = 0
            if NoteDocument.Block.lists.contains(block) {
                let width = block == .numbered ? 3 : 2
                while let last = lists.last, last.start > leading { lists.removeLast() }
                if let last = lists.last, last.start == leading {
                    lists[lists.count - 1] = (leading, leading + width)
                } else if leading == (lists.last?.content ?? 0) {
                    lists.append((leading, leading + width))
                } else { return nil }
                depth = lists.count - 1
            } else {
                // An indented line that is not a list item continues an item or starts
                // indented code, and neither has a place in the rich editor.
                guard leading == 0 else { return nil }
                lists = []
            }
            // Indentation, soft wraps, hard breaks and block extensions carry meaning
            // that a paragraph-only rich editor cannot safely reconstruct.
            guard !line.isEmpty, line == line.trimmingCharacters(in: .whitespaces),
                  !line.contains("\t"), !line.hasPrefix("---"), !line.hasPrefix("==="),
                  !line.hasPrefix("+++"), !line.hasPrefix("~~~"),
                  !([.title, .heading, .subheading].contains(block)
                    && line.range(of: #"\s+#+$"#, options: .regularExpression) != nil),
                  !([.bullet, .numbered, .checklist, .quote].contains(block) && line.hasPrefix("#")),
                  !(block == .text && previousWasText),
                  !(block == .text && line.range(of: #"^(\d+[.)] |[+*>#-] )"#, options: .regularExpression) != nil),
                  let inline = Self.inline(line, block: block) else { return nil }
            if !runs.isEmpty { runs.append(.init(text: "\n")) }
            if !marker.isEmpty { runs.append(.init(text: marker, block: block, indent: depth)) }
            runs.append(contentsOf: inline.map { var run = $0; run.indent = depth; return run })
            previousWasText = block == .text
        }
        document = NoteDocument(runs: Self.normalized(NoteDocument(runs: runs)))
    }

    func markdown(afterEditing edited: NoteDocument) -> String {
        // AppKit coalesces adjacent runs, so compare their styled contents, not their
        // incidental run boundaries, before deciding whether anything was edited.
        if Self.normalized(edited) == Self.normalized(document) { return source }
        return edited.markdown + (source.hasSuffix("\n") ? "\n" : "")
    }

    private static func normalized(_ document: NoteDocument) -> [NoteDocument.Run] {
        var result: [NoteDocument.Run] = []
        for run in document.runs where !run.text.isEmpty {
            if var last = result.last, last.bold == run.bold, last.italic == run.italic,
               last.block == run.block, last.link == run.link, last.code == run.code, last.indent == run.indent {
                last.text += run.text; result[result.count - 1] = last
            } else { result.append(run) }
        }
        return result
    }

    private static func inline(_ text: String, block: NoteDocument.Block,
                               bold: Bool = false, italic: Bool = false) -> [NoteDocument.Run]? {
        var rest = text[...]
        var runs: [NoteDocument.Run] = []
        while let first = rest.first {
            if first == "\\" {
                rest.removeFirst()
                guard let escaped = rest.first, #"\`*_{}[]<>#!|-+.=~&"#.contains(escaped) else { return nil }
                runs.append(.init(text: String(escaped), bold: bold, italic: italic, block: block))
                rest.removeFirst()
            } else if first == "*" {
                let delimiter = rest.hasPrefix("***") ? "***" : rest.hasPrefix("**") ? "**" : "*"
                rest.removeFirst(delimiter.count)
                guard let end = rest.range(of: delimiter), end.lowerBound != rest.startIndex,
                      rest.first?.isWhitespace == false,
                      rest[rest.index(before: end.lowerBound)].isWhitespace == false,
                      let nested = inline(String(rest[..<end.lowerBound]), block: block,
                                          bold: bold || delimiter.count >= 2, italic: italic || delimiter.count != 2) else { return nil }
                runs += nested; rest = rest[end.upperBound...]
            } else if first == "`" {
                let fence = String(rest.prefix { $0 == "`" })
                rest.removeFirst(fence.count)
                var search = rest.startIndex
                var close: Range<Substring.Index>?
                while let found = rest[search...].range(of: fence) {
                    let longer = found.upperBound < rest.endIndex && rest[found.upperBound] == "`"
                    if !longer { close = found; break }
                    search = rest[found.lowerBound...].firstIndex { $0 != "`" } ?? rest.endIndex
                }
                guard let close, close.lowerBound != rest.startIndex else { return nil }
                var content = String(rest[..<close.lowerBound])
                if content.count > 2, content.hasPrefix(" "), content.hasSuffix(" "),
                   content.contains(where: { $0 != " " }) {
                    content = String(content.dropFirst().dropLast())
                }
                runs.append(.init(text: content, bold: bold, italic: italic, block: block, code: true))
                rest = rest[close.upperBound...]
            } else if first == "[" {
                guard let close = rest.range(of: "]("), let end = rest[close.upperBound...].firstIndex(of: ")") else { return nil }
                let label = String(rest[rest.index(after: rest.startIndex)..<close.lowerBound])
                var destination = String(rest[close.upperBound..<end])
                if destination.hasPrefix("<"), destination.hasSuffix(">") { destination = String(destination.dropFirst().dropLast()) }
                guard let safe = NoteDocument.safeLink(destination),
                      !destination.contains(where: \.isWhitespace),
                      let nested = inline(label, block: block, bold: bold, italic: italic),
                      nested.allSatisfy({ $0.link == nil }) else { return nil }
                runs += nested.map { var run = $0; run.link = safe; return run }
                rest = rest[rest.index(after: end)...]
            } else {
                guard !"_`[]<>!|~&".contains(first) else { return nil }
                let plain = rest.prefix { !"\\*_`[]<>!|~&".contains($0) }
                runs.append(.init(text: String(plain), bold: bold, italic: italic, block: block))
                rest.removeFirst(plain.count)
            }
        }
        return normalized(NoteDocument(runs: runs))
    }
}

struct MarkdownHeading: Identifiable {
    let line: Int
    let title: String
    var id: Int { line }

    static func read(_ source: String) -> [Self] {
        var fence: String?
        return source.components(separatedBy: "\n").enumerated().compactMap { index, line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                fence = fence == nil ? marker : fence == marker ? nil : fence
                return nil
            }
            guard fence == nil, let range = line.range(of: #"^#{1,6} "#, options: .regularExpression) else { return nil }
            return Self(line: index + 1, title: String(line[range.upperBound...]))
        }
    }
}
