import Foundation
import Testing
@testable import MenuBarApp

struct ThinkingKeywordTests {

    @Test func findsTheWordWhereverItStandsOnItsOwn() {
        let text = "ultrathink about this, then ULTRAthink again."

        let found = ThinkingKeyword.ranges(in: text).map {
            (text as NSString).substring(with: $0)
        }

        #expect(found == ["ultrathink", "ULTRAthink"])
    }

    @Test func ignoresTheWordInsideALongerOne() {
        #expect(ThinkingKeyword.ranges(in: "ultrathinking").isEmpty)
        #expect(ThinkingKeyword.ranges(in: "superultrathink").isEmpty)
        #expect(ThinkingKeyword.ranges(in: "ultrathink_mode").isEmpty)
    }

    @Test func keepsPunctuationAndBracketsAsBoundaries() {
        #expect(ThinkingKeyword.ranges(in: "(ultrathink)").count == 1)
        #expect(ThinkingKeyword.ranges(in: "please ultrathink!").count == 1)
    }

    @Test func spreadsTheLettersAcrossTheSpectrum() {
        let first = ThinkingKeyword.colour(letter: 0, of: 10, at: .now, dark: true)
        let last = ThinkingKeyword.colour(letter: 9, of: 10, at: .now, dark: true)

        #expect(first.hueComponent != last.hueComponent)
    }

    @Test func movesTheColoursOnAsTimePasses() {
        let start = Date()
        let now = ThinkingKeyword.colour(letter: 0, of: 10, at: start, dark: true)
        let later = ThinkingKeyword.colour(letter: 0, of: 10,
                                           at: start.addingTimeInterval(1), dark: true)

        #expect(now.hueComponent != later.hueComponent)
    }

    @Test func takesTheSameColoursForTheSameMoment() {
        let moment = Date()

        #expect(ThinkingKeyword.colour(letter: 3, of: 10, at: moment, dark: false)
                == ThinkingKeyword.colour(letter: 3, of: 10, at: moment, dark: false))
    }
}
