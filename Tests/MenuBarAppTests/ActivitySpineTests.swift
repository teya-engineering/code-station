import Foundation
import Testing
@testable import MenuBarApp

struct ActivitySpineTests {

    @Test func staysOpenWhileTheTurnIsWorkingThroughIt() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: nil,
                                             isLive: true,
                                             hasExpandedRows: false))
    }

    @Test func foldsOnceTheTurnHasEnded() {
        #expect(!ActivitySpine.rowsAreVisible(isFoldable: true,
                                              userChoice: nil,
                                              isLive: false,
                                              hasExpandedRows: false))
    }

    @Test func staysOpenWhileTheReaderHasARowExpanded() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: nil,
                                             isLive: false,
                                             hasExpandedRows: true))
    }

    @Test func keepsAReadersChoiceAfterTheTurnEnds() {
        #expect(ActivitySpine.rowsAreVisible(isFoldable: true,
                                             userChoice: true,
                                             isLive: false,
                                             hasExpandedRows: false))
    }
}

struct SpineCardTests {

    @Test func aFinishedCallKnowsHowLongItTook() {
        let started = Date(timeIntervalSinceReferenceDate: 1_000)
        var tool = ToolUse(id: "b1", name: "Bash", input: "{}", result: "ok")
        tool.startedAt = started
        tool.finishedAt = started.addingTimeInterval(2.5)
        #expect(tool.duration == 2.5)
    }

    @Test func aRunningCallHasNoDurationYet() {
        var tool = ToolUse(id: "b1", name: "Bash", input: "{}")
        tool.startedAt = Date()
        #expect(tool.duration == nil)
    }

    @Test func aCallRecordedWithoutTimesHasNoDuration() {
        let tool = ToolUse(id: "b1", name: "Read", input: "{}", result: "ok")
        #expect(tool.duration == nil)
    }

    @Test func shortSpansKeepTheirTenths() {
        #expect(ElapsedTime.duration(0.34) == "0.3s")
        #expect(ElapsedTime.duration(2) == "2.0s")
    }

    @Test func longerSpansReadLikeTheLiveClock() {
        #expect(ElapsedTime.duration(41.6) == "41s")
        #expect(ElapsedTime.duration(161) == "2m 41s")
        #expect(ElapsedTime.reading(161) == "2m 41s")
    }

    @Test func theBandSaysTheStateInWords() {
        #expect(SpineCardState(isWorking: true, isError: false).word == "RUNNING")
        #expect(SpineCardState(isWorking: false, isError: false).word == "DONE")
        #expect(SpineCardState(isWorking: false, isError: true).word == "FAILED")
    }

    // A background agent's call reports in at once and keeps going, so the band goes by
    // the work, not by the call having a result.
    @Test func aCallStillWorkingIsRunningWhateverItsResultSays() {
        #expect(SpineCardState(isWorking: true, isError: true) == .running)
    }
}
