import Foundation
import Testing
@testable import MenuBarApp

// The gutter numbers a line and the highlighter reads one, and both start from here, so
// an off-by-one shows up as numbers against the wrong rows or colour bleeding a line.
struct LineIndexTests {

    @Test func anEmptyDocumentIsOneEmptyLine() {
        let index = LineIndex("")

        #expect(index.count == 1)
        #expect(index.line(at: 0) == 0)
        #expect(index.range(of: 0, length: 0) == NSRange(location: 0, length: 0))
    }

    @Test func aTrailingNewlineLeavesALastLineToNumber() {
        #expect(LineIndex("a\n").count == 2)
        #expect(LineIndex("a").count == 1)
    }

    @Test func everyOffsetLandsOnItsLine() {
        let index = LineIndex("ab\ncd\n\nef")

        #expect(index.line(at: 0) == 0)
        #expect(index.line(at: 2) == 0)   // the newline belongs to the line it ends
        #expect(index.line(at: 3) == 1)
        #expect(index.line(at: 6) == 2)   // the empty line
        #expect(index.line(at: 7) == 3)
    }

    @Test func offsetsPastTheEndClampToTheLastLine() {
        let index = LineIndex("ab\ncd")

        #expect(index.line(at: 500) == 1)
        #expect(index.start(of: 99) == 3)
        #expect(index.start(of: -1) == 0)
    }

    @Test func aLineRangeCarriesItsNewline() {
        let text = "ab\ncd\n"
        let index = LineIndex(text as NSString)
        let length = (text as NSString).length

        #expect(index.range(of: 0, length: length) == NSRange(location: 0, length: 3))
        #expect(index.range(of: 1, length: length) == NSRange(location: 3, length: 3))
        #expect(index.range(of: 2, length: length) == NSRange(location: 6, length: 0))
    }

    @Test func offsetsCountTheSameUnitsTheTextViewDoes() {
        // The emoji is two UTF-16 units, so a line index built in characters would put
        // every line after it one short.
        let index = LineIndex("🙂\nx")

        #expect(index.start(of: 1) == 3)
        #expect(index.line(at: 3) == 1)
    }
}
