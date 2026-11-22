import Foundation

// Readers for what git prints: status, name-status and numstat records, and unified diffs.
extension GitInspector {

    // Porcelain v1 records are "XY path", NUL separated. A rename adds a second record
    // holding the old path.
    static func parseStatus(_ text: String) -> [GitChange] {
        let records = text.components(separatedBy: "\0")
        var files: [GitChange] = []
        var i = 0
        while i < records.count {
            let entry = Array(records[i])
            i += 1
            guard entry.count > 3 else { continue }
            let index = entry[0]
            let worktree = entry[1]
            let path = String(entry[3...])

            var original: String?
            if index == "R" || index == "C" || worktree == "R" || worktree == "C" {
                guard i < records.count else { break }
                original = records[i]
                i += 1
            }

            let untracked = index == "?" && worktree == "?"
            let conflicted = index == "U" || worktree == "U"
                || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")

            let kind: GitStatusKind
            if untracked {
                kind = .untracked
            } else if conflicted {
                kind = .conflicted
            } else {
                kind = self.kind(from: index == " " ? worktree : index)
            }

            files.append(GitChange(
                path: path,
                originalPath: original,
                kind: kind,
                isStaged: !untracked && index != " ",
                isUnstaged: untracked || worktree != " ",
                added: nil,
                removed: nil,
                isBinary: false))
        }
        return files
    }

    // --name-status -z records are a status then a path, NUL separated. A rename or a
    // copy carries a score in its status and the old path before the new one.
    static func parseNameStatus(_ text: String) -> [(path: String, originalPath: String?, kind: GitStatusKind)] {
        let records = text.components(separatedBy: "\0")
        var entries: [(path: String, originalPath: String?, kind: GitStatusKind)] = []
        var i = 0
        while i + 1 < records.count {
            guard let letter = records[i].first else { i += 1; continue }
            if letter == "R" || letter == "C" {
                guard i + 2 < records.count else { break }
                entries.append((records[i + 2], records[i + 1], kind(from: letter)))
                i += 3
            } else {
                entries.append((records[i + 1], nil, kind(from: letter)))
                i += 2
            }
        }
        return entries
    }

    private static func kind(from letter: Character) -> GitStatusKind {
        switch letter {
        case "A", "C": .added
        case "D": .deleted
        case "R": .renamed
        default: .modified
        }
    }

    // numstat -z records are "added\tremoved\tpath". A rename leaves the path empty and
    // puts the old and new paths in the two records that follow.
    static func parseNumstat(_ text: String) -> [(path: String, added: Int?, removed: Int?)] {
        let records = text.components(separatedBy: "\0")
        var entries: [(String, Int?, Int?)] = []
        var i = 0
        while i < records.count {
            let parts = records[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            i += 1
            guard parts.count >= 3 else { continue }
            // git writes "-" for both counts when the file is binary.
            let added = Int(parts[0])
            let removed = Int(parts[1])
            var path = parts[2]
            if path.isEmpty {
                guard i + 1 < records.count else { break }
                i += 1
                path = records[i]
                i += 1
            }
            guard !path.isEmpty else { continue }
            entries.append((path, added, removed))
        }
        return entries
    }

    // What one pass over git's output found. Gap rows are ours rather than git's, so
    // they are counted apart from the diff's own rows.
    struct ParsedDiff {
        var lines: [DiffLine] = []
        var total = 0
        var extra = 0
        var binary = false

        var truncated: Bool { total > lines.count - extra }
    }

    // Header lines before the first hunk are noise we already show elsewhere, so they are
    // dropped. Once inside a hunk every line is classified by its first character only:
    // a removed line whose own text starts with "--" would otherwise look like a header.
    static func parse(
        _ text: String, startingAt offset: Int, limit: Int,
        revision: DiffRevision, path defaultPath: String
    ) -> ParsedDiff {
        var result = ParsedDiff()
        var inHunk = false
        var path = defaultPath
        // Where the new side of the file has got to, so a hunk starting further down
        // says how many unchanged lines the diff skipped over.
        var nextNewLine = 1
        // An added file is shown whole, so it has no tail left to offer.
        var whole = false
        var gapID = 0

        // A row for lines the diff left out. It goes where the hole is, so it keeps
        // sitting between the lines shown on either side of it however it is opened.
        func openGap(from start: Int, count: Int?) {
            if let count, count <= 0 { return }
            guard result.lines.count < limit else { return }
            result.extra += 1
            result.lines.append(DiffLine(
                id: offset + result.lines.count, kind: .gap, text: "",
                gap: DiffGap(revision: revision, path: path, id: gapID,
                             start: start, count: count)))
            gapID += 1
        }

        // Whatever the file has after its last hunk. A deleted file has no new side to
        // read, and its hunks never move the new line count off the start.
        func openTail() {
            guard inHunk, !whole, nextNewLine > 1 else { return }
            openGap(from: nextNewLine, count: nil)
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git") {
                // Start of another file in the same output: back to header lines.
                openTail()
                inHunk = false
                whole = false
                path = fileName(fromDiffHeader: line)
                nextNewLine = 1
                continue
            }
            if !inHunk {
                if line.hasPrefix("@@") {
                    inHunk = true
                } else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                    result.binary = true
                    break
                } else if line.hasPrefix("rename from") || line.hasPrefix("rename to")
                            || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") {
                    if line.hasPrefix("new file mode") { whole = true }
                    result.total += 1
                    if result.lines.count < limit {
                        result.lines.append(DiffLine(id: offset + result.lines.count,
                                                     kind: .meta, text: line))
                    }
                    continue
                } else {
                    continue
                }
            }

            let kind: DiffLine.Kind
            switch line.first {
            case "@": kind = .hunk
            case "+": kind = .addition
            case "-": kind = .deletion
            case "\\": kind = .meta
            default: kind = .context
            }

            if kind == .hunk, let range = newSideRange(ofHunk: line) {
                // A hunk that only removes lines is written as sitting after a line
                // rather than at one, so the first line it shows is the next one.
                let firstShown = range.count == 0 ? range.start + 1 : range.start
                openGap(from: nextNewLine, count: firstShown - nextNewLine)
                nextNewLine = max(nextNewLine, firstShown + range.count)
            }

            result.total += 1
            if result.lines.count < limit {
                result.lines.append(DiffLine(id: offset + result.lines.count, kind: kind,
                                             text: clean(line)))
            }
        }

        // A trailing newline always produces one empty final line.
        if let last = result.lines.last, last.text.isEmpty, last.kind == .context {
            result.lines.removeLast()
            result.total -= 1
        }
        openTail()
        return result
    }

    // "@@ -12,7 +34,9 @@ trailing" says the new side starts at line 34 and covers 9
    // lines. A missing count means one line.
    private static func newSideRange(ofHunk line: String) -> (start: Int, count: Int)? {
        let fields = line.split(separator: " ")
        guard fields.count >= 3, fields[2].hasPrefix("+") else { return nil }
        let numbers = fields[2].dropFirst().split(separator: ",")
        guard let start = Int(numbers[0]) else { return nil }
        guard numbers.count > 1 else { return (start, 1) }
        guard let count = Int(numbers[1]) else { return nil }
        return (start, count)
    }

    // "diff --git a/old b/new" names the file; the b side is where it lives now. Paths
    // with unusual characters arrive quoted, so the quote is part of the marker then.
    private static func fileName(fromDiffHeader line: String) -> String {
        if let range = line.range(of: " \"b/") {
            var name = String(line[range.upperBound...])
            if name.hasSuffix("\"") { name.removeLast() }
            return name
        }
        if let range = line.range(of: " b/") {
            return String(line[range.upperBound...])
        }
        return line
    }

    // Very long lines (minified files) are the other way a diff can stall layout.
    private static let lineCharacterLimit = 2000

    static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "\t", with: "    ")
        text = text.replacingOccurrences(of: "\r", with: "")
        if text.count > lineCharacterLimit {
            text = String(text.prefix(lineCharacterLimit)) + " …"
        }
        return text
    }
}
