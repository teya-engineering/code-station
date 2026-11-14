import Testing
@testable import MenuBarApp

struct NewWorkspaceGapTests {
    @Test func readyOnceTwoProjectsAndANameArePicked() {
        #expect(NewWorkspaceGap(picked: 2, name: "Payments") == nil)
        #expect(NewWorkspaceGap(picked: 5, name: "Payments") == nil)
    }

    @Test func noProjectsAsksForTwo() {
        let gap = NewWorkspaceGap(picked: 0, name: "Payments")
        #expect(gap?.sentence == "Pick at least two projects. A workspace holds projects worked on together.")
        #expect(gap?.picked == 0)
    }

    @Test func oneProjectAsksForOneMore() {
        let gap = NewWorkspaceGap(picked: 1, name: "Payments")
        #expect(gap?.sentence == "Pick one more project. A workspace needs two or more.")
        #expect(gap?.picked == 1)
    }

    @Test func projectsComeBeforeTheName() {
        #expect(NewWorkspaceGap(picked: 1, name: "  ")?.sentence
            == "Pick one more project. Then give the workspace a name.")
        #expect(NewWorkspaceGap(picked: 0, name: "")?.sentence
            == "Pick at least two projects. Then give the workspace a name.")
    }

    @Test func enoughProjectsWithoutANameAsksForTheName() {
        let gap = NewWorkspaceGap(picked: 2, name: " ")
        #expect(gap == .name)
        #expect(gap?.sentence == "Give the workspace a name to create it.")
        #expect(gap?.picked == nil)
    }
}
