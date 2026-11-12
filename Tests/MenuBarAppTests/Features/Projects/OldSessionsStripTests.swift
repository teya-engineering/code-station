import Foundation
import Testing
@testable import MenuBarApp

// With automatic cleanup off, the strip is only an offer to review what has gone quiet.
// These cover the wording rules rather than the layout.
struct OldSessionsStripTests {
    private func summary(sessions: Int = 0, losesWork: Int = 0,
                         snoozedProjects: Int = 0) -> OldSessionsWatch.Summary {
        OldSessionsWatch.Summary(sessions: sessions, losesWork: losesWork,
                                 snoozedProjects: snoozedProjects)
    }

    @Test func theOfferNamesTheCountAndTheThreshold() {
        #expect(OldSessionsOfferStrip.title(summary(sessions: 4), days: 30)
            == "4 sessions older than 30 days")
        #expect(OldSessionsOfferStrip.title(summary(sessions: 1), days: 1)
            == "1 session older than 1 day")
    }

    // The detail says why nothing will happen on its own, then what accepting would cost.
    @Test func theOfferSaysCleanupIsOffAndWhatItWouldCost() {
        #expect(OldSessionsOfferStrip.detail(summary(sessions: 4))
            == "Automatic cleanup is off")
        #expect(OldSessionsOfferStrip.detail(summary(sessions: 5, losesWork: 3,
                                                     snoozedProjects: 2))
            == "Automatic cleanup is off · 3 would lose work · 2 projects snoozed")
    }
}
