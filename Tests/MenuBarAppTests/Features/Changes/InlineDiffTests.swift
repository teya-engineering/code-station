import AppKit
import Testing
@testable import MenuBarApp

// A changed line picks out the words that changed, so a one-word edit does not read the
// same as a rewrite.
struct InlineDiffTests {

    // The text each range covers, which reads better in a failure than offsets do.
    private func marked(_ old: String, _ new: String) -> (old: [String], new: [String]) {
        let marks = InlineDiff.compare(old, new)
        let text = { (line: String, ranges: [NSRange]) in ranges.map { (line as NSString).substring(with: $0) } }
        return (text(old, marks.old), text(new, marks.new))
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
        let marks = InlineDiff.compare("    return value", "        return value  ")
        #expect(marks.old.isEmpty)
        #expect(marks.new.isEmpty)
    }

    @Test func rangesCountUTF16SoTextAfterAnEmojiLinesUp() {
        let old = "label = \"👋 hello\""
        let new = "label = \"👋 goodbye\""
        let marks = InlineDiff.compare(old, new)
        #expect(marks.new.map { (new as NSString).substring(with: $0) } == ["goodbye"])
        #expect(marks.old.map { (old as NSString).substring(with: $0) } == ["hello"])
    }

    @Test func aLongPairIsLeftWithItsBandAlone() {
        let old = (0..<600).map { "a\($0)" }.joined(separator: " ")
        let new = (0..<600).map { "b\($0)" }.joined(separator: " ")
        let marks = InlineDiff.compare(old, new)
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
        let ranges = InlineDiff.ranges(lines)
        // Ranges are measured from after the sign.
        #expect(ranges[1] == [NSRange(location: 8, length: 1)])
        #expect(ranges[4] == [NSRange(location: 8, length: 2)])
        #expect(ranges[2] == nil)
        #expect(ranges[5] == [NSRange(location: 9, length: 8)])
        // A removed line with no added line beside it keeps its band alone.
        #expect(ranges[3] == nil)
        #expect(ranges[6] == nil)
    }

    @Test func lonelyAdditionsAreNotMarked() {
        let lines = [DiffLine(id: 0, kind: .addition, text: "+brand new")]
        #expect(InlineDiff.ranges(lines).isEmpty)
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
}
