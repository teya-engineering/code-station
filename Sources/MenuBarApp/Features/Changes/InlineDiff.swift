import Foundation

// Which words of a changed line actually changed. git marks whole lines, so a one-word
// edit lights up the same as a rewrite. Within a run of removed lines followed by added
// ones, each removed line is set against the added line beside it, the same pairing the
// side-by-side view lays out, and the two are compared word by word.
enum InlineDiff {
    // Comparing two lines costs their word counts multiplied. A pair past this is left
    // with its row band alone, and a diff stops picking out words once it has spent the
    // whole budget, so a long diff never stalls on it.
    static let pairLimit = 250_000
    static let workLimit = 2_000_000

    // The changed parts of each line, keyed by line id, as UTF-16 ranges into the line's
    // text after its + or - sign. A line with nothing to pick out is left out.
    static func ranges(_ rows: [DiffComparisonRow]) -> [Int: [NSRange]] {
        var result: [Int: [NSRange]] = [:]
        var work = workLimit
        for row in rows {
            guard let old = row.left, let new = row.right,
                  old.kind == .deletion, new.kind == .addition else { continue }
            let marks = compare(String(old.text.dropFirst()), String(new.text.dropFirst()), work: &work)
            if !marks.old.isEmpty { result[old.id] = marks.old }
            if !marks.new.isEmpty { result[new.id] = marks.new }
        }
        return result
    }

    private static func compare(_ old: String, _ new: String,
                                work: inout Int) -> (old: [NSRange], new: [NSRange]) {
        let a = tokens(old)
        let b = tokens(new)
        // Indentation and trailing space are left out, so a line that only moved in or
        // out keeps its band and nothing more.
        var aStart = a.firstIndex { !$0.isSpace } ?? a.count
        var bStart = b.firstIndex { !$0.isSpace } ?? b.count
        var aEnd = (a.lastIndex { !$0.isSpace } ?? -1) + 1
        var bEnd = (b.lastIndex { !$0.isSpace } ?? -1) + 1
        aEnd = max(aEnd, aStart)
        bEnd = max(bEnd, bStart)
        let aWords = a[aStart..<aEnd].count { !$0.isSpace }
        let bWords = b[bStart..<bEnd].count { !$0.isSpace }
        // What the two share at either end is unchanged, and costs nothing to find.
        while aStart < aEnd, bStart < bEnd, a[aStart].text == b[bStart].text { aStart += 1; bStart += 1 }
        while aStart < aEnd, bStart < bEnd, a[aEnd - 1].text == b[bEnd - 1].text { aEnd -= 1; bEnd -= 1 }
        guard aStart < aEnd || bStart < bEnd else { return ([], []) }

        let cost = (aEnd - aStart) * (bEnd - bStart)
        guard cost <= pairLimit, cost <= work else { return ([], []) }
        work -= cost
        let found = changes(a, aStart..<aEnd, b, bStart..<bEnd)
        // Lines are paired only by where they sit, so a removed line can face an added
        // line that has nothing to do with it. When less than half of the two is shared
        // they are not one line edited, and marking nearly all of both says nothing.
        let removed = found.reduce(0) { total, hunk in total + a[hunk.old].count { !$0.isSpace } }
        let shared = aWords - removed
        guard shared * 4 >= aWords + bWords else { return ([], []) }
        let hunks = merged(found, in: a)
        return (hunks.compactMap { span(a, $0.old) }, hunks.compactMap { span(b, $0.new) })
    }

    struct Token {
        let text: Substring
        let range: NSRange
        let isSpace: Bool
    }

    // A word is a run of letters, digits and underscores, a run of spaces is one token,
    // and any other character stands alone, so punctuation can match on its own.
    static func tokens(_ line: String) -> [Token] {
        var result: [Token] = []
        var i = line.startIndex
        var offset = 0
        while i < line.endIndex {
            let first = line[i]
            var end = line.index(after: i)
            if isWord(first) {
                while end < line.endIndex, isWord(line[end]) { end = line.index(after: end) }
            } else if first.isWhitespace {
                while end < line.endIndex, line[end].isWhitespace { end = line.index(after: end) }
            }
            let text = line[i..<end]
            let length = text.utf16.count
            result.append(Token(text: text, range: NSRange(location: offset, length: length),
                                isSpace: first.isWhitespace))
            offset += length
            i = end
        }
        return result
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private struct Hunk {
        var old: Range<Int>
        var new: Range<Int>
    }

    // The runs of tokens that differ, found from the longest run of tokens both lines
    // share in order.
    private static func changes(_ a: [Token], _ aRange: Range<Int>,
                                _ b: [Token], _ bRange: Range<Int>) -> [Hunk] {
        let n = aRange.count
        let m = bRange.count
        // common[i * (m + 1) + j] is how many tokens a[i...] and b[j...] share in order.
        var common = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    common[i * (m + 1) + j] = a[aRange.lowerBound + i].text == b[bRange.lowerBound + j].text
                        ? common[(i + 1) * (m + 1) + j + 1] + 1
                        : max(common[(i + 1) * (m + 1) + j], common[i * (m + 1) + j + 1])
                }
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0, lastI = 0, lastJ = 0
        func close() {
            if lastI < i || lastJ < j {
                hunks.append(Hunk(old: aRange.lowerBound + lastI..<aRange.lowerBound + i,
                                  new: bRange.lowerBound + lastJ..<bRange.lowerBound + j))
            }
        }
        while i < n, j < m {
            if a[aRange.lowerBound + i].text == b[bRange.lowerBound + j].text {
                close()
                i += 1; j += 1
                lastI = i; lastJ = j
            } else if common[(i + 1) * (m + 1) + j] >= common[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        i = n; j = m
        close()
        return hunks
    }

    // Two changes with only a space or a character or two left between them read as one
    // edit, so they are drawn as one. Otherwise a rewritten line breaks into confetti.
    private static func merged(_ hunks: [Hunk], in a: [Token]) -> [Hunk] {
        var result: [Hunk] = []
        for hunk in hunks {
            guard let last = result.last else { result.append(hunk); continue }
            let between = a[last.old.upperBound..<hunk.old.lowerBound]
            if between.allSatisfy(\.isSpace) || between.reduce(0, { $0 + $1.range.length }) <= 2 {
                result[result.count - 1] = Hunk(old: last.old.lowerBound..<hunk.old.upperBound,
                                                new: last.new.lowerBound..<hunk.new.upperBound)
            } else {
                result.append(hunk)
            }
        }
        return result
    }

    private static func span(_ tokens: [Token], _ range: Range<Int>) -> NSRange? {
        guard let first = range.first, let last = range.last else { return nil }
        let start = tokens[first].range.location
        return NSRange(location: start, length: NSMaxRange(tokens[last].range) - start)
    }
}
