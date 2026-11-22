import Foundation

// One changed or unchanged line of a diff with the number it carries in the version it
// belongs to. The gutter, the comment rows and the placement below all read from this,
// so a number on screen and a number in a comment always agree.
struct NumberedDiffLine: Equatable {
    var id: Int
    var side: ReviewSide
    var number: Int
    // The code without the diff's sign column.
    var code: String

    static func lines(_ lines: [DiffLine]) -> [NumberedDiffLine] {
        var numbered: [NumberedDiffLine] = []
        for row in DiffComparisonRow.align(lines) {
            if let left = row.left, left == row.right {
                if left.kind == .context, let number = row.oldNumber {
                    numbered.append(.init(id: left.id, side: .old, number: number, code: code(left)))
                }
                if left.kind == .context, let number = row.newNumber {
                    numbered.append(.init(id: left.id, side: .new, number: number, code: code(left)))
                }
                continue
            }
            if let left = row.left, left.kind == .deletion, let number = row.oldNumber {
                numbered.append(.init(id: left.id, side: .old, number: number, code: code(left)))
            }
            if let right = row.right, right.kind == .addition, let number = row.newNumber {
                numbered.append(.init(id: right.id, side: .new, number: number, code: code(right)))
            }
        }
        return numbered
    }

    static func excerpt(_ anchor: DiffAnchor, in diff: [DiffLine]) -> (text: String, offsets: [Int]) {
        let range = anchor.line...(anchor.lastLine ?? anchor.line)
        let selected = lines(diff).filter { $0.side == anchor.side && range.contains($0.number) }
        return (selected.map(\.code).joined(separator: "\n"), selected.map { $0.number - anchor.line })
    }

    private static func code(_ line: DiffLine) -> String { String(line.text.dropFirst()) }

    var anchor: DiffAnchor { DiffAnchor(side: side, line: number) }
}

// Where each of a file's comments sits in the diff open now. The agent may have moved
// the code since a comment was left, so a comment whose line no longer holds the text it
// was left on looks for that text nearby, and one that cannot find it at all is listed
// above the diff instead of being pinned to the wrong line.
struct ReviewPlacement: Equatable {
    // Keyed by the id of the diff line each group of comments is drawn below.
    var below: [Int: [ReviewComment]] = [:]
    var unplaced: [ReviewComment] = []

    // Kept on the file as a whole, by choice, after their code left the diff.
    var onFile: [ReviewComment] = []

    static func place(_ comments: [ReviewComment], in lines: [DiffLine]) -> ReviewPlacement {
        guard !comments.isEmpty else { return ReviewPlacement() }
        let numbered = NumberedDiffLine.lines(lines)
        var placement = ReviewPlacement()
        for comment in comments.sorted(by: { $0.created < $1.created }) {
            if comment.onFile {
                placement.onFile.append(comment)
            } else if let found = locate(comment.anchor, excerpt: comment.excerpt,
                                  excerptOffsets: comment.excerptOffsets, in: numbered) {
                placement.below[found.lastID, default: []].append(comment)
            } else {
                placement.unplaced.append(comment)
            }
        }
        return placement
    }

    // Where the lines that held `excerpt` are now, and the id of the last of them. The
    // lines a comment was left on win while every one of them still holds its code;
    // otherwise the nearest run that does. Code as plain as a lone brace turns up in many
    // places, so if it has moved and could be any of several, it is nowhere rather than
    // somewhere wrong. A comment that quotes nothing can only stay on its own number.
    static func locate(_ anchor: DiffAnchor, excerpt: String,
                       excerptOffsets: [Int]? = nil,
                       in numbered: [NumberedDiffLine]) -> (anchor: DiffAnchor, lastID: Int)? {
        var lines: [Int: NumberedDiffLine] = [:]
        for line in numbered where line.side == anchor.side { lines[line.number] = line }
        let span = (anchor.lastLine ?? anchor.line) - anchor.line
        func last(from start: Int, count: Int) -> NumberedDiffLine? {
            lines[start + span] ?? lines[start + count - 1]
        }
        guard !excerpt.isBlank else {
            return lines[anchor.line + span].map { (anchor, $0.id) }
        }
        let expected = excerpt.components(separatedBy: "\n").map(\.trimmed)
        let offsets = excerptOffsets ?? Array(expected.indices)
        guard offsets.count == expected.count else { return nil }
        func holds(_ start: Int) -> Bool {
            zip(offsets, expected).allSatisfy { offset, code in lines[start + offset]?.code.trimmed == code }
        }
        if holds(anchor.line), let end = last(from: anchor.line, count: expected.count) {
            return (anchor, end.id)
        }
        let starts = lines.keys.filter(holds).sorted { abs($0 - anchor.line) < abs($1 - anchor.line) }
        guard let best = starts.first else { return nil }
        let distinctive = expected.joined().count { $0.isLetter || $0.isNumber } >= 4
        guard starts.count == 1 || distinctive,
              let end = last(from: best, count: expected.count) else { return nil }
        let moved = DiffAnchor(side: anchor.side, line: best, lastLine: anchor.lastLine.map { _ in best + span })
        return (moved, end.id)
    }
}

// Where everything left on the open file sits in the diff on screen: the comments not
// sent yet, the sent ones, and the questions, each keyed by the line it is drawn below.
struct DiffPlacements {
    var comments = ReviewPlacement()
    var sent = ReviewPlacement()
    var questions: [Int: [ReviewQuestion]] = [:]
}
