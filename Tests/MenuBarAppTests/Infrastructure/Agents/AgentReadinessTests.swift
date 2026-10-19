import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct AgentReadinessTests {
    @Test func anAccountWithoutTheCLIIsNotReady() {
        #expect(AgentReadiness(installed: false, signedIn: true,
                               checking: false, failed: false) == .notInstalled)
    }

    @Test func aPendingCheckDoesNotClaimTheUserIsSignedOut() {
        #expect(AgentReadiness(installed: true, signedIn: false,
                               checking: true, failed: false) == .checking)
    }

    @Test func anUnreadableAccountIsDifferentFromBeingSignedOut() {
        #expect(AgentReadiness(installed: true, signedIn: false,
                               checking: false, failed: true) == .failed)
        #expect(AgentReadiness(installed: true, signedIn: false,
                               checking: false, failed: false) == .signInNeeded)
    }

    @Test func retryWaitsForTheResultBeforeReplacingAFailure() {
        #expect(AgentReadiness(installed: true, signedIn: true,
                               checking: true, failed: true) == .checking)
        #expect(AgentReadiness(installed: true, signedIn: true,
                               checking: false, failed: true) == .failed)
        #expect(AgentReadiness(installed: true, signedIn: true,
                               checking: false, failed: false) == .connected)
    }
}
