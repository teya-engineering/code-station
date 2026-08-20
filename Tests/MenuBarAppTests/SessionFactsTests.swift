import Foundation
import Testing
@testable import MenuBarApp

// The chip is the only thing left of these facts while it is shut, so what it says has to
// be the one reading that is worth watching rather than looking up.
@MainActor
struct SessionFactsTests {
    @Test func readsOutTheWindow() {
        let facts = SessionFacts(branch: "lantern/billing-split",
                                 pullRequest: PullRequest(number: 482,
                                                          url: "https://github.com/a/b/pull/482"),
                                 model: "Opus",
                                 context: 0.38)

        #expect(facts.summary == "38%")
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
}
