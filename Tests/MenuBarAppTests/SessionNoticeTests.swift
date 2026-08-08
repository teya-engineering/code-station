import Testing
@testable import MenuBarApp

struct SessionNoticeTests {
    @Test func leavesIdleSeenSessionsOut() {
        #expect(SessionNotice(isBusy: false, needsInput: false, finishedUnseen: false) == nil)
    }

    @Test func includesRunningSessions() {
        #expect(SessionNotice(isBusy: true, needsInput: false, finishedUnseen: false) == .running)
    }

    @Test func includesUnseenCompletions() {
        #expect(SessionNotice(isBusy: false, needsInput: false, finishedUnseen: true) == .finished)
    }

    @Test func inputTakesPriorityOverOtherStates() {
        #expect(SessionNotice(isBusy: true, needsInput: true, finishedUnseen: true) == .needsInput)
    }
}
