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

    // The pill is one button for the state and the branch, so VoiceOver hears both halves
    // in one go, state first.
    @Test func speaksTheStateThenTheBranch() {
        let state = SessionStateReading(tone: .running, since: Date().addingTimeInterval(-312),
                                        ticks: true)
        let facts = SessionFacts(branch: "code-station/6318e9ff")
        #expect(SessionFactsChip.accessibilityLabel(state: state, facts: facts, showsBranch: true)
                    == "Running for 5m, branch code-station/6318e9ff, working set preview")
        // The Changes tab names the branch itself, so the pill leaves it out there.
        #expect(SessionFactsChip.accessibilityLabel(state: state, facts: facts, showsBranch: false)
                    == "Running for 5m, working set preview")
    }

    @Test func speaksTheWindowAndASessionWithNoTime() {
        let state = SessionStateReading(tone: .needsYou)
        let facts = SessionFacts(context: 0.42, agent: .claudeCode)
        #expect(SessionFactsChip.accessibilityLabel(state: state, facts: facts, showsBranch: true)
                    == "Needs you, working set preview, context 42% full")
    }

    @Test func namesADiagnosisOnlyWhileItRuns() {
        #expect(SessionStateReading(tone: .running, diagnosing: true).word == "DIAGNOSING")
        #expect(SessionStateReading(tone: .idle, diagnosing: true).word == "IDLE")
        #expect(SessionStateReading(tone: .running, diagnosing: true).spokenWord == "Diagnosing")
    }

    @Test func namesCompletionWorkWithoutHidingAttentionOrWaiting() {
        for activity in [SessionCompletionActivity.title, .recap, .finishing] {
            let running = SessionStateReading(tone: .running, diagnosing: true,
                                              completionActivity: activity)
            #expect(running.spokenWord == activity.label)
            for tone in [SessionTone.needsYou, .waiting, .idle] {
                #expect(SessionStateReading(tone: tone, completionActivity: activity).word == tone.word)
            }
        }
    }

    // The card carries the count the pill rounds off.
    @Test func countsPreciselyOnTheCard() {
        #expect(SessionStateReading.preciseElapsed(4) == "0m 04s")
        #expect(SessionStateReading.preciseElapsed(312) == "5m 12s")
        #expect(SessionStateReading.preciseElapsed(2 * 3_600 + 14 * 60 + 9) == "2h 14m")
        #expect(SessionStateReading.preciseElapsed(27 * 3_600) == "1d 3h")
        #expect(SessionStateReading.preciseElapsed(-5) == "0m 00s")
    }

    @Test func saysWhenALiveStateBeganAndWhenAnIdleOneLastMoved() {
        let now = Date()
        let clock = now.formatted(date: .omitted, time: .shortened)
        #expect(SessionStateReading.sinceLine(now, tone: .running) == "since \(clock)")
        #expect(SessionStateReading.sinceLine(now, tone: .idle) == "last active \(clock)")
        let lastWeek = now.addingTimeInterval(-7 * 86_400)
        #expect(SessionStateReading.sinceLine(lastWeek, tone: .idle)
                    == "last active \(RelativeTime.stamp(lastWeek))")
    }
    @Test func countsOpenPullRequestsIncludingDraftsByRepositoryURL() {
        let first = PullRequest(number: 3, url: "https://github.com/team/first/pull/3")
        let second = PullRequest(number: 3, url: "https://github.com/team/second/pull/3")
        var facts = SessionFacts(pullRequests: [first, second])
        #expect(facts.pullRequestCountLabel == "2 linked")
        facts.pullRequestStatuses[first.url] = PullRequestStatus(
            state: .open, title: "First", headBranch: "topic", isDraft: true)
        #expect(facts.pullRequestCountLabel == "2 linked")
        facts.pullRequestStatuses[second.url] = PullRequestStatus(
            state: .merged, title: "Second", headBranch: "topic")
        #expect(facts.pullRequestCountLabel == "1 open")
        #expect(facts.pullRequestStatuses[first.url]?.readinessLabel == "Draft")
        #expect(facts.pullRequestStatuses[second.url]?.readinessLabel == "Merged")
        #expect(SessionFactsChip.accessibilityLabel(state: .init(tone: .idle),
            facts: facts, showsBranch: true).contains("1 open pull requests"))
    }

    @Test func distinguishesNewSessionsFromFinishedAndRunningOnes() {
        #expect(SessionStateReading(tone: .idle, isNew: true).spokenWord == "New session")
        #expect(SessionStateReading(tone: .running, isNew: true).spokenWord == "Running")
    }

    @Test func constrainsPreviewToTheWindowBelowItsShortcut() {
        let layout = SessionFactsLayout(anchor: CGRect(x: 700, y: 40, width: 240, height: 36),
                                        bounds: CGSize(width: 960, height: 640))
        #expect(layout.width == 430)
        #expect(layout.height == 549)
        let narrow = SessionFactsLayout(anchor: CGRect(x: 80, y: 40, width: 240, height: 36),
                                        bounds: CGSize(width: 340, height: 400))
        #expect(narrow.width == 312)
        #expect(narrow.height == 309)
    }

}
