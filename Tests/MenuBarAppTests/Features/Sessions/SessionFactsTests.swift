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
                    == "Running for 5m, branch code-station/6318e9ff, session details")
        // The Changes tab names the branch itself, so the pill leaves it out there.
        #expect(SessionFactsChip.accessibilityLabel(state: state, facts: facts, showsBranch: false)
                    == "Running for 5m, session details")
    }

    @Test func speaksTheWindowAndASessionWithNoTime() {
        let state = SessionStateReading(tone: .needsYou)
        let facts = SessionFacts(context: 0.42, agent: .claudeCode)
        #expect(SessionFactsChip.accessibilityLabel(state: state, facts: facts, showsBranch: true)
                    == "Needs you, session details, context 42% full")
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
            facts: facts, showsBranch: true).contains("pull requests: 1 draft, 1 merged"))
    }

    // The chip names the pull request that most needs the person and counts the rest;
    // VoiceOver hears every state, most pressing first.
    @Test func namesTheMostPressingPullRequestOnTheChip() {
        let merged = PullRequest(number: 1777, url: "https://github.com/team/a/pull/1777")
        let approved = PullRequest(number: 412, url: "https://github.com/team/b/pull/412")
        let review = PullRequest(number: 1809, url: "https://github.com/team/a/pull/1809")
        let changes = PullRequest(number: 1812, url: "https://github.com/team/a/pull/1812")
        var facts = SessionFacts(pullRequests: [merged, approved, review, changes])
        // Nothing read yet: the newest, still Linked.
        #expect(facts.leadPullRequest == changes)
        #expect(facts.pullRequestTone(changes).word == "Linked")
        #expect(facts.spokenPullRequestStates == "4 linked")

        facts.pullRequestStatuses = [
            merged.url: PullRequestStatus(state: .merged, title: "", headBranch: "a"),
            approved.url: PullRequestStatus(state: .open, title: "", headBranch: "b", reviewDecision: .approved),
            review.url: PullRequestStatus(state: .open, title: "", headBranch: "c", reviewDecision: .reviewRequired),
            changes.url: PullRequestStatus(state: .open, title: "", headBranch: "d", reviewDecision: .changesRequested)
        ]
        #expect(facts.leadPullRequest == changes)
        #expect(facts.spokenPullRequestStates == "1 changes requested, 1 in review, 1 approved, 1 merged")

        facts.pullRequests = [merged, approved]
        #expect(facts.leadPullRequest == approved)
        facts.pullRequests = [merged]
        #expect(facts.leadPullRequest == merged)
        #expect(facts.pullRequestTone(merged).symbol == .merge)
        facts.pullRequests = []
        #expect(facts.leadPullRequest == nil)
    }

    // Closed sorts under merged, and one not read yet waits under both.
    @Test func ranksPullRequestStatesByHowMuchTheyNeedThePerson() {
        let ranked: [PullRequestStatus.Readiness?] = [.changesRequested, .inReview, .approved, .draft, .merged, .closed, nil]
        let tones = ranked.map { readiness in
            PullRequestTone(readiness.map { readiness in
                switch readiness {
                case .draft: PullRequestStatus(state: .open, title: "", headBranch: "b", isDraft: true)
                case .inReview: PullRequestStatus(state: .open, title: "", headBranch: "b")
                case .approved: PullRequestStatus(state: .open, title: "", headBranch: "b", reviewDecision: .approved)
                case .changesRequested:
                    PullRequestStatus(state: .open, title: "", headBranch: "b", reviewDecision: .changesRequested)
                case .merged: PullRequestStatus(state: .merged, title: "", headBranch: "b")
                case .closed: PullRequestStatus(state: .closed, title: "", headBranch: "b")
                }
            })
        }
        #expect(tones.map(\.readiness) == ranked)
        #expect(tones.map(\.urgency) == Array(0..<ranked.count))
        #expect(tones.map(\.word) == ["Changes requested", "In review", "Approved", "Draft", "Merged", "Closed", "Linked"])
        #expect(tones.map(\.symbol) == [.pull, .pull, .pull, .draft, .merge, .closed, .pull])
        #expect(tones.map(\.railLook) == [.filled, .filled, .filled, .filled, .filled, .filled, .outlined])
    }

    // What may still need the person leads, newest first, and the merged and closed ones
    // follow, newest first too. A state not known yet counts as one that may need them.
    @Test func listsOpenPullRequestsFirstAndNewestFirstWithinEach() {
        let merged = PullRequest(number: 1, url: "https://github.com/team/a/pull/1")
        let open = PullRequest(number: 2, url: "https://github.com/team/a/pull/2")
        let unknown = PullRequest(number: 3, url: "https://github.com/team/b/pull/3")
        let closed = PullRequest(number: 4, url: "https://github.com/team/b/pull/4")
        let draft = PullRequest(number: 5, url: "https://github.com/team/c/pull/5")
        let facts = SessionFacts(
            pullRequests: [merged, open, unknown, closed, draft],
            pullRequestStatuses: [
                merged.url: .init(state: .merged, title: "", headBranch: ""),
                open.url: .init(state: .open, title: "", headBranch: ""),
                closed.url: .init(state: .closed, title: "", headBranch: ""),
                draft.url: .init(state: .open, title: "", headBranch: "", isDraft: true)
            ])

        #expect(facts.orderedPullRequests.map(\.number) == [5, 3, 2, 4, 1])
    }

    // An open card keeps the order it opened with when a state lands, so nothing moves
    // under the pointer. One opened meanwhile goes on top, and one that went is dropped.
    @Test func holdsTheOrderAnOpenCardStartedWith() {
        let first = PullRequest(number: 1, url: "https://github.com/team/a/pull/1")
        let second = PullRequest(number: 2, url: "https://github.com/team/a/pull/2")
        let third = PullRequest(number: 3, url: "https://github.com/team/a/pull/3")
        var facts = SessionFacts(pullRequests: [first, second])
        let held = facts.orderedPullRequests.map(\.url)
        #expect(held == [second.url, first.url])

        facts.pullRequestStatuses[second.url] = .init(state: .merged, title: "", headBranch: "")
        #expect(facts.orderedPullRequests.map(\.number) == [1, 2])
        #expect(facts.pullRequests(holding: held).map(\.number) == [2, 1])

        facts.pullRequests = [first, second, third]
        #expect(facts.pullRequests(holding: held).map(\.number) == [3, 2, 1])

        facts.pullRequests = [first, third]
        #expect(facts.pullRequests(holding: held).map(\.number) == [3, 1])
    }

    // A pull request already merged when it is linked to an open card joins the bottom,
    // under the open ones the person may still need.
    @Test func putsASettledLateArrivalUnderTheHeldRows() {
        let first = PullRequest(number: 1, url: "https://github.com/team/a/pull/1")
        let second = PullRequest(number: 2, url: "https://github.com/team/a/pull/2")
        let old = PullRequest(number: 3, url: "https://github.com/team/b/pull/3")
        var facts = SessionFacts(pullRequests: [first, second])
        let held = facts.orderedPullRequests.map(\.url)

        facts.pullRequests = [old, first, second]
        facts.pullRequestStatuses[old.url] = .init(state: .merged, title: "", headBranch: "")
        #expect(facts.pullRequests(holding: held).map(\.number) == [2, 1, 3])
    }

    // The stored list keeps a pull request found for the branch behind the ones read from
    // the transcript, whatever its age, so newest is read from when GitHub says each was
    // opened. One GitHub has not answered for yet counts as the newest.
    @Test func ordersByWhenGitHubSaysEachWasOpened() {
        let fromTranscript = PullRequest(number: 9, url: "https://github.com/team/a/pull/9")
        let fromBranch = PullRequest(number: 4, url: "https://github.com/team/b/pull/4")
        let unread = PullRequest(number: 12, url: "https://github.com/team/c/pull/12")
        let day: TimeInterval = 86_400
        let facts = SessionFacts(
            pullRequests: [fromTranscript, unread, fromBranch],
            pullRequestStatuses: [
                fromTranscript.url: .init(state: .open, title: "", headBranch: "",
                                          createdAt: Date(timeIntervalSince1970: 3 * day)),
                fromBranch.url: .init(state: .open, title: "", headBranch: "",
                                      createdAt: Date(timeIntervalSince1970: day))
            ])

        #expect(facts.orderedPullRequests.map(\.number) == [12, 9, 4])
    }

    private func snapshot(branch: String, files: [(added: Int, removed: Int)] = []) -> GitSnapshot {
        var snapshot = GitSnapshot(state: .ready, branch: branch)
        snapshot.files = files.enumerated().map { index, counts in
            GitChange(path: "file-\(index).swift", kind: .modified, isStaged: false, isUnstaged: true,
                      added: counts.added, removed: counts.removed, isBinary: false)
        }
        return snapshot
    }

    // The transcript's running total stands in only until git has answered.
    @Test func countsTheTreeOnceGitHasAnswered() {
        var summary = SessionSummary()
        #expect(SessionFacts.Changes(snapshots: [], summary: summary) == nil)

        summary.added = 7
        summary.removed = 2
        #expect(SessionFacts.Changes(snapshots: [], summary: summary)
            == .init(files: 0, added: 7, removed: 2))

        #expect(SessionFacts.Changes(snapshots: [snapshot(branch: "main")], summary: summary) == nil)
        let trees = [snapshot(branch: "main", files: [(3, 1), (4, 0)]),
                     snapshot(branch: "other", files: [(1, 5)])]
        #expect(SessionFacts.Changes(snapshots: trees, summary: summary)
            == .init(files: 3, added: 8, removed: 6))
    }

    @Test func readsASessionsFactsFromItsLeadCheckout() {
        var session = ChatSession(projectID: UUID(), agent: .codex)
        session.worktreeBranch = "made/at-creation"
        let request = PullRequest(number: 7, url: "https://github.com/a/b/pull/7")
        session.pullRequests = [request]
        let status = PullRequestStatus(state: .open, title: "Seven", headBranch: "made/at-creation")
        let reviews = [PullRequestReviewStore.Loaded(pullRequest: request, status: status, reviews: [])]

        // Git has answered for neither folder: the branch the session was made on stands in.
        let waiting = SessionFacts(session: session, snapshots: [nil, nil], reviews: reviews,
                                   modelTitle: { $0 }, showsCost: true)
        #expect(waiting.branch == "made/at-creation")
        #expect(waiting.changes == nil)
        #expect(waiting.pullRequestStatuses == [request.url: status])
        #expect(waiting.agent == .codex)

        // A clean tree is known to be clean only once every folder has answered.
        let partial = SessionFacts(session: session, snapshots: [snapshot(branch: "lead"), nil],
                                   reviews: [], modelTitle: { $0 }, showsCost: true)
        #expect(partial.branch == "lead")
        #expect(partial.changes == nil)
        let clean = SessionFacts(session: session,
                                 snapshots: [snapshot(branch: "lead"), snapshot(branch: "second")],
                                 reviews: [], modelTitle: { $0 }, showsCost: true)
        #expect(clean.changes == .init(files: 0, added: 0, removed: 0))
        #expect(SessionFacts(session: session, snapshots: [], reviews: [], modelTitle: { $0 },
                             showsCost: true).changes == nil)
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
