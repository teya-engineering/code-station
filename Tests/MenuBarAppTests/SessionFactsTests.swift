import Foundation
import Testing
@testable import MenuBarApp

// The chip stays one stable target while the facts inside it change.
@MainActor
struct SessionFactsTests {
    @Test func keepsTheDetailsLabelWhileTheWindowChanges() {
        let facts = SessionFacts(branch: "lantern/billing-split",
                                 pullRequest: PullRequest(number: 482,
                                                          url: "https://github.com/a/b/pull/482"),
                                 model: "Opus",
                                 context: 0.38)

        #expect(facts.summary == "Details")
    }

    // A session that has not taken a turn yet has no window to read, so the chip offers
    // the card rather than standing in for it with a fact nobody is watching.
    @Test func offersTheCardBeforeTheFirstTurn() {
        #expect(SessionFacts(branch: "main").summary == "Details")
        #expect(SessionFacts(model: "Opus").summary == "Details")
        #expect(SessionFacts(cost: 12.5).summary == "Details")
    }

    // Nothing to say means no chip at all, rather than an empty one.
    @Test func saysNothingAboutASessionThatHasDoneNothing() {
        #expect(SessionFacts().summary == nil)
        #expect(SessionFacts(branch: "").summary == nil)
    }

    // The window turns from a reading into a warning at the same points wherever it is
    // drawn - the chip, and the hairline under the strip.
    @Test func warnsAsTheWindowFills() {
        #expect(SessionFacts.contextColour(0.4, agent: .claudeCode) == Theme.dotOn)
        #expect(SessionFacts.contextColour(0.72, agent: .claudeCode) == Theme.attention)
        #expect(SessionFacts.contextColour(0.9, agent: .claudeCode) == Theme.deletion)
        // Codex makes its own room as the window fills, so a full one is worth noticing
        // rather than a turn that will not start.
        #expect(SessionFacts.contextColour(0.9, agent: .codex) == Theme.attention)
    }

    @Test func lightsTheFuseAboveEightyPercent() {
        #expect(!ContextHairline.showsFuse(at: 0.8))
        #expect(ContextHairline.showsFuse(at: 0.801))
        #expect(ContextHairline.animatesFuse(at: 0.801, whileActive: true))
        #expect(!ContextHairline.animatesFuse(at: 0.801, whileActive: false))
        #expect(!ContextHairline.animatesFuse(at: 0.8, whileActive: true))
    }
}
