import Foundation
import Testing
@testable import MenuBarApp

// The chip is the only thing left of these facts while it is shut, so what it says has to
// be the most identifying thing the session has.
@MainActor
struct SessionFactsTests {
    @Test func namesTheBranchAndThePullRequest() {
        let facts = SessionFacts(branch: "lantern/billing-split",
                                 pullRequest: PullRequest(number: 482,
                                                          url: "https://github.com/a/b/pull/482"))

        #expect(facts.summary == "billing-split · #482")
    }

    // A team that starts every branch with the same word would otherwise fill the chip
    // with the part that never differs.
    @Test func dropsTheBranchPrefix() {
        #expect(SessionFacts(branch: "feature/teams/split-worker").summary == "split-worker")
        #expect(SessionFacts(branch: "main").summary == "main")
    }

    // A session on the project's own checkout has no branch of its own until git answers,
    // so the chip falls back to what it is running rather than disappearing.
    @Test func fallsBackToTheModelThenTheWindow() {
        #expect(SessionFacts(model: "Opus", context: 0.38).summary == "Opus")
        #expect(SessionFacts(context: 0.38).summary == "38%")
        #expect(SessionFacts(cost: 12.5).summary == "$12.50")
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
