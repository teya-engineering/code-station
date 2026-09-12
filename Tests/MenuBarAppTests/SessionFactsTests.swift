import Foundation
import Testing
@testable import MenuBarApp

// The chip is the branch, and behind it the rest of what a session is looked up by.
@MainActor
struct SessionFactsTests {
    @Test func namesTheBranchOnTheChip() {
        let facts = SessionFacts(branch: "lantern/billing-split",
                                 pullRequests: [PullRequest(number: 482,
                                                            url: "https://github.com/a/b/pull/482")],
                                 model: "Opus",
                                 context: 0.38)

        #expect(facts.summary == "lantern/billing-split")
    }

    // A session with no repository behind it has no branch to name, so the chip stands
    // for the card rather than for a fact it does not have.
    @Test func fallsBackToTheWordDetailsWithoutARepository() {
        #expect(SessionFacts(model: "Opus").summary == "Details")
        #expect(SessionFacts(cost: 12.5).summary == "Details")
        #expect(SessionFacts(branch: "", model: "Opus").summary == "Details")
    }

    // Everything the card can show is a reason to offer the card, including the counts
    // that now ride on the Changes tab.
    @Test func opensForAnyFactItCanCarry() {
        #expect(SessionFacts(branch: "main").summary == "main")
        #expect(SessionFacts(changes: .init(files: 3, added: 12, removed: 4)).summary == "Details")
        #expect(SessionFacts(context: 0.2).summary == "Details")
    }

    // Nothing to say means no chip at all, rather than an empty one.
    @Test func saysNothingAboutASessionThatHasDoneNothing() {
        #expect(SessionFacts().summary == nil)
        #expect(SessionFacts(branch: "").summary == nil)
    }

    // The window turns from a reading into a warning at the same points wherever it is
    // drawn - the card, and the hairline above the destination deck.
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
