import Foundation
import Testing
@testable import MenuBarApp

// The word a running turn shows. It only has to do two things: move on its own, and not
// look stuck while it does.
struct WorkingWordsTests {

    private let words = WorkingWords(order: ["Mulling", "Pondering", "Noodling"])

    @Test func keepsAWordUpForItsWholeTurnThenMovesOn() {
        #expect(words.word(after: 0) == "Mulling")
        #expect(words.word(after: WorkingWords.interval - 0.01) == "Mulling")
        #expect(words.word(after: WorkingWords.interval) == "Pondering")
        #expect(words.word(after: WorkingWords.interval * 2) == "Noodling")
    }

    // A long turn runs off the end of the list, and starting over is better than stopping
    // on the last word, which would look exactly like a frozen row.
    @Test func startsOverRatherThanStopping() {
        #expect(words.word(after: WorkingWords.interval * 3) == "Mulling")
        #expect(words.word(after: WorkingWords.interval * 39) == "Mulling")
        #expect(words.word(after: WorkingWords.interval * 40) == "Pondering")
    }

    // A turn can be under way before the row is on screen, so the clock it is given is not
    // guaranteed to start at zero.
    @Test func survivesAClockThatRunsBackwards() {
        #expect(words.word(after: -5) == "Mulling")
    }

    // Walking a shuffled list rather than picking at random is what stops a word repeating
    // itself, so every word gets a turn before any of them comes back.
    @Test func everyWordGetsATurnBeforeAnyRepeats() {
        let all = WorkingWords()
        let seen = (0..<WorkingWords.all.count).map {
            all.word(after: Double($0) * WorkingWords.interval)
        }
        #expect(Set(seen).count == WorkingWords.all.count)
    }

    @Test func hasNothingToSayWithoutAnyWords() {
        #expect(WorkingWords(order: []).word(after: 0) == "Working")
    }

    @Test func everyPersonalityCyclesOnlyThroughItsOwnPhrases() {
        for personality in AgentPersonality.allCases {
            let words = WorkingWords(personality: personality)
            let seen = (0..<personality.workingWords.count).map {
                words.word(after: Double($0) * WorkingWords.interval)
            }

            #expect(Set(seen) == Set(personality.workingWords))
        }
    }

    @Test func personalitiesDoNotShareWorkingPhrases() {
        let phraseSets = AgentPersonality.allCases.map { Set($0.workingWords) }

        for first in phraseSets.indices {
            for second in phraseSets.indices where first < second {
                #expect(phraseSets[first].isDisjoint(with: phraseSets[second]))
            }
        }
    }
}
