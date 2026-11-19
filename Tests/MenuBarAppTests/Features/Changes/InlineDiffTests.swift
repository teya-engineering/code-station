import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// A changed line picks out the words that changed, so a one-word edit does not read the
// same as a rewrite.
struct InlineDiffTests {

    private func ranges(_ lines: [DiffLine]) -> [Int: [NSRange]] {
        InlineDiff.ranges(DiffComparisonRow.align(lines))
    }

    // The text each range covers, which reads better in a failure than offsets do.
    private func marked(_ old: String, _ new: String) -> (old: [String], new: [String]) {
        let marks = ranges([DiffLine(id: 0, kind: .deletion, text: "-" + old),
                            DiffLine(id: 1, kind: .addition, text: "+" + new)])
        let text = { (line: String, ranges: [NSRange]?) in
            (ranges ?? []).map { (line as NSString).substring(with: $0) }
        }
        return (text(old, marks[0]), text(new, marks[1]))
    }

    @Test func oneChangedWordIsAllThatIsMarked() {
        let marks = marked("let total = price * count", "let total = cost * count")
        #expect(marks.old == ["price"])
        #expect(marks.new == ["cost"])
    }

    @Test func somethingAddedAtTheEndMarksOnlyTheNewPart() {
        let marks = marked("import { Baz, Bar } from \"foo\";", "import { Baz, Bar, Foo } from \"foo\";")
        #expect(marks.old.isEmpty)
        #expect(marks.new == [", Foo"])
    }

    @Test func changesWithOnlyAFewCharactersBetweenThemReadAsOne() {
        let marks = marked("call(alpha.beta)", "call(gamma.delta)")
        #expect(marks.old == ["alpha.beta"])
        #expect(marks.new == ["gamma.delta"])
    }

    @Test func changesFarApartStaySeparate() {
        let marks = marked("let first = makeThing(with: value)", "let second = makeThing(with: other)")
        #expect(marks.old == ["first", "value"])
        #expect(marks.new == ["second", "other"])
    }

    @Test func aLineThatOnlyMovedInOrOutHasNothingMarked() {
        let marks = marked("    return value", "        return value  ")
        #expect(marks.old.isEmpty)
        #expect(marks.new.isEmpty)
    }

    @Test func rangesCountUTF16SoTextAfterAnEmojiLinesUp() {
        let marks = marked("label = \"👋 hello\"", "label = \"👋 goodbye\"")
        #expect(marks.new == ["goodbye"])
        #expect(marks.old == ["hello"])
    }

    @Test func linesThatShareLittleAreNotMarked() {
        // Paired only by where they sit: a comment facing the line it was written above.
        let marks = marked("return foo()", "// new helper")
        #expect(marks.old.isEmpty)
        #expect(marks.new.isEmpty)
    }

    @Test func aLongPairIsLeftWithItsBandAlone() {
        let old = (0..<600).map { "a\($0)" }.joined(separator: " ")
        let new = (0..<600).map { "b\($0)" }.joined(separator: " ")
        let marks = marked(old, new)
        #expect(marks.old.isEmpty)
        #expect(marks.new.isEmpty)
    }

    @Test func removedLinesPairWithTheAddedLinesBesideThem() {
        let lines = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -1,3 +1,2 @@"),
            DiffLine(id: 1, kind: .deletion, text: "-let a = 1"),
            DiffLine(id: 2, kind: .deletion, text: "-let b = 2"),
            DiffLine(id: 3, kind: .deletion, text: "-let c = 3"),
            DiffLine(id: 4, kind: .addition, text: "+let a = 10"),
            DiffLine(id: 5, kind: .addition, text: "+let b = 2 // kept"),
            DiffLine(id: 6, kind: .context, text: " done")
        ]
        let marks = ranges(lines)
        // Ranges are measured from after the sign.
        #expect(marks[1] == [NSRange(location: 8, length: 1)])
        #expect(marks[4] == [NSRange(location: 8, length: 2)])
        #expect(marks[2] == nil)
        #expect(marks[5] == [NSRange(location: 9, length: 8)])
        // A removed line with no added line beside it keeps its band alone.
        #expect(marks[3] == nil)
        #expect(marks[6] == nil)
    }

    @Test func lonelyAdditionsAreNotMarked() {
        let lines = [DiffLine(id: 0, kind: .addition, text: "+brand new")]
        #expect(ranges(lines).isEmpty)
    }

    @Test func theSideBySideCellPaintsTheChangedWordsOnly() {
        let lines = [
            DiffLine(id: 0, kind: .deletion, text: "-let total = price"),
            DiffLine(id: 1, kind: .addition, text: "+let total = cost")
        ]
        let marks = ranges(lines)
        func painted(_ line: DiffLine) -> [String] {
            let code = SideBySideDiff.code(line, marks: marks)
            return code.runs.compactMap { run in
                run.backgroundColor == nil ? nil : String(code[run.range].characters)
            }
        }
        #expect(painted(lines[0]) == ["price"])
        #expect(painted(lines[1]) == ["cost"])
        // The sign sits in its own column, so the cell holds only the code.
        #expect(String(SideBySideDiff.code(lines[1], marks: marks).characters) == "let total = cost")
    }

    @Test func aMarkThatNoLongerFitsItsLineIsDropped() {
        // Marks worked out for one diff and read against another must never reach past
        // the end of the line they land on.
        let line = DiffLine(id: 0, kind: .addition, text: "+short")
        let code = SideBySideDiff.code(line, marks: [0: [NSRange(location: 3, length: 40)]])
        #expect(code.runs.allSatisfy { $0.backgroundColor == nil })
    }

    @Test func theUnifiedDiffPaintsTheChangedWordsOnly() {
        let lines = [
            DiffLine(id: 0, kind: .deletion, text: "-let total = price"),
            DiffLine(id: 1, kind: .addition, text: "+let total = cost")
        ]
        let text = DiffText.attributed(lines, numbered: true)
        let string = text.string as NSString
        var painted: [String] = []
        text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { painted.append(string.substring(with: range)) }
        }
        #expect(painted == ["price", "cost"])
    }

    @Test func aSignThatACombiningMarkLeansOnStillLinesUpTheMarks() {
        // The combining accent joins the sign into one character two units long, and
        // the last line has no newline after it to absorb a mark that runs over.
        let lines = [
            DiffLine(id: 0, kind: .deletion, text: "-\u{301}let total = price"),
            DiffLine(id: 1, kind: .addition, text: "+\u{301}let total = cost")
        ]
        let text = DiffText.attributed(lines)
        let string = text.string as NSString
        var painted: [String] = []
        text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { painted.append(string.substring(with: range)) }
        }
        #expect(painted == ["price", "cost"])
    }
}
