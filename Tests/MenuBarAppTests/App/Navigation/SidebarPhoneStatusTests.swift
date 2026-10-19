import Testing
@testable import MenuBarApp
@testable import CodeStationCore

// The phone line is the only place outside the pairing dialog that says a phone can reach
// the app, so it has to tell a joined phone apart from a code nobody has used yet.
@MainActor
struct SidebarPhoneStatusTests {
    @Test func noCodeShowsNoLine() {
        #expect(SidebarPhoneStatus(nil) == nil)
    }

    @Test func aCodeNobodyJoinedIsOnlyShared() {
        let status = SidebarPhoneStatus(isConnected: false)

        #expect(status.text == "Shared")
    }

    @Test func aJoinedCodeReadsAsOnPhone() {
        let status = SidebarPhoneStatus(isConnected: true)

        #expect(status.text == "On phone")
    }

    @Test func homeButtonSpeaksBothLines() {
        let value = SidebarBrandBar.accessibilityValue(
            runningCount: 3, phone: SidebarPhoneStatus(isConnected: true))

        #expect(value == "3 running sessions, shared with a connected phone")
    }

    @Test func homeButtonSpeaksThePhoneAloneWhenNothingRuns() {
        let value = SidebarBrandBar.accessibilityValue(
            runningCount: 0, phone: SidebarPhoneStatus(isConnected: false))

        #expect(value == "shared with a phone, none connected")
    }

    @Test func homeButtonSaysNothingWhenIdle() {
        #expect(SidebarBrandBar.accessibilityValue(runningCount: 0, phone: nil) == "")
    }
}
