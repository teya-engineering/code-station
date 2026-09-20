import Foundation
import Testing
@testable import MenuBarApp

// The strip is the last thing a person reads before walking away from sessions the app
// will delete on its own, so the two lines have to agree with what the sweep will
// actually take. These cover the wording rules rather than the layout.
struct OldSessionsStripTests {
    private func summary(sessions: Int = 0, losesWork: Int = 0,
                         snoozedProjects: Int = 0) -> OldSessionsWatch.Summary {
        OldSessionsWatch.Summary(sessions: sessions, losesWork: losesWork,
                                 snoozedProjects: snoozedProjects)
    }

    // MARK: - Nothing waiting yet

    // With no cohort settled the strip is only an offer, so it names the threshold that
    // put those sessions on the list.
    @Test func theOfferNamesTheCountAndTheThreshold() {
        let title = OldSessionsStrip.title(summary(sessions: 4), deleting: nil, days: 30)

        #expect(title == "4 sessions older than 30 days")
    }

    @Test func theOfferCountsWhatAcceptingItWouldCost() {
        let detail = OldSessionsStrip.detail(summary(sessions: 4, losesWork: 2),
                                             deleting: nil, days: 30)

        #expect(detail == "2 sessions would lose work")
    }

    // One session reads as one, not "1 sessions".
    @Test func asingleSessionLosingWorkReadsAsOne() {
        let detail = OldSessionsStrip.detail(summary(sessions: 3, losesWork: 1),
                                             deleting: nil, days: 30)

        #expect(detail == "1 session would lose work")
    }

    // A snooze is why the count looks smaller than it should, so a quiet strip is never a
    // mystery. With nothing at risk the line says only what is being held back.
    @Test func aSnoozeIsNamedEvenWhenNothingWouldLoseWork() {
        let detail = OldSessionsStrip.detail(summary(sessions: 2, snoozedProjects: 1),
                                             deleting: nil, days: 30)

        #expect(detail == "1 project snoozed")
    }

    @Test func aSnoozeAndLostWorkAreBothNamed() {
        let detail = OldSessionsStrip.detail(summary(sessions: 5, losesWork: 3,
                                                     snoozedProjects: 2),
                                             deleting: nil, days: 30)

        #expect(detail == "2 projects snoozed · 3 would lose work")
    }

    // MARK: - A cohort waiting

    // Once the sweep has settled on a cohort the top line is a promise about that cohort,
    // so it counts what will go rather than everything that has gone quiet.
    @Test func aWaitingCohortIsWhatTheTopLineCounts() {
        let title = OldSessionsStrip.title(summary(sessions: 9), deleting: 4, days: 30)

        #expect(title == "4 sessions will be deleted")
    }

    // The threshold moves to the detail line, since the top line gave up naming it.
    @Test func theDetailPicksUpTheThresholdAndWhatIsBeingKept() {
        let detail = OldSessionsStrip.detail(summary(sessions: 9), deleting: 4, days: 30)

        #expect(detail == "Older than 30 days · 5 kept for review")
    }

    @Test func aSnoozeStillGetsALineUnderAPromise() {
        let detail = OldSessionsStrip.detail(summary(sessions: 9, snoozedProjects: 1),
                                             deleting: 4, days: 30)

        #expect(detail == "Older than 30 days · 5 kept for review · 1 project snoozed")
    }

    // Nothing held back means nothing to say about it.
    @Test func aCohortThatTakesEverythingMentionsNoLeftovers() {
        let detail = OldSessionsStrip.detail(summary(sessions: 4), deleting: 4, days: 30)

        #expect(detail == "Older than 30 days")
    }

    // The summary runs on its own slower clock, so it can still be counting sessions the
    // cohort has already lost. A subtraction that went negative would read as
    // "-1 kept for review".
    @Test func aSummaryLaggingBehindTheCohortNeverReportsNegativeLeftovers() {
        let detail = OldSessionsStrip.detail(summary(sessions: 2), deleting: 5, days: 30)

        #expect(detail == "Older than 30 days")
        #expect(!detail.contains("-"))
    }

    // MARK: - Singulars

    @Test func aSingleDayAndASingleSessionBothReadAsOne() {
        #expect(OldSessionsStrip.title(summary(sessions: 1), deleting: nil, days: 1)
            == "1 session older than 1 day")
        #expect(OldSessionsStrip.title(summary(sessions: 3), deleting: 1, days: 30)
            == "1 session will be deleted")
    }
}
