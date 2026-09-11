import Testing
@testable import MenuBarApp

struct ChangeFileSelectionTests {
    private let files = ["one", "two", "three", "four", "five"]
    private var changes: [GitChange] {
        files.map {
            GitChange(path: $0, kind: .modified, isStaged: false, isUnstaged: true,
                      isBinary: false)
        }
    }

    @Test func plainClickReplacesTheSelection() {
        var selection = ChangeFileSelection()
        selection.select("one", in: files, extendingRange: false, toggling: false)
        selection.select("three", in: files, extendingRange: false, toggling: false)

        #expect(selection.ids == ["three"])
        #expect(selection.anchorID == "three")
        #expect(selection.activeID == "three")
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchor() {
        var selection = ChangeFileSelection()
        selection.select("two", in: files, extendingRange: false, toggling: false)
        selection.select("four", in: files, extendingRange: true, toggling: false)

        #expect(selection.ids == ["two", "three", "four"])
        #expect(selection.anchorID == "two")
        #expect(selection.activeID == "four")
    }

    @Test func commandClickTogglesIndividualFiles() {
        var selection = ChangeFileSelection()
        selection.select("one", in: files, extendingRange: false, toggling: false)
        selection.select("three", in: files, extendingRange: false, toggling: true)
        selection.select("five", in: files, extendingRange: false, toggling: true)
        selection.select("three", in: files, extendingRange: false, toggling: true)

        #expect(selection.ids == ["one", "five"])
        #expect(selection.anchorID == "five")
        #expect(selection.activeID == "five")
    }

    @Test func commandShiftClickAddsARangeToTheSelection() {
        var selection = ChangeFileSelection()
        selection.select("one", in: files, extendingRange: false, toggling: false)
        selection.select("three", in: files, extendingRange: false, toggling: true)
        selection.select("five", in: files, extendingRange: true, toggling: true)

        #expect(selection.ids == ["one", "three", "four", "five"])
        #expect(selection.anchorID == "three")
        #expect(selection.activeID == "five")
    }

    @Test func refreshDropsFilesThatNoLongerExist() {
        var selection = ChangeFileSelection()
        selection.select("two", in: files, extendingRange: false, toggling: false)
        selection.select("four", in: files, extendingRange: true, toggling: false)

        selection.retain(["two", "three"], in: ["one", "two", "three", "five"])

        #expect(selection.ids == ["two", "three"])
        #expect(selection.anchorID == "two")
        #expect(selection.activeID == "two")
    }

    @Test func contextMenuUsesTheWholeRangeOnAnySelectedRow() {
        var selection = ChangeFileSelection()
        selection.select("two", in: files, extendingRange: false, toggling: false)
        selection.select("four", in: files, extendingRange: true, toggling: false)

        for file in changes[1...3] {
            #expect(selection.contextMenuFiles(for: file, in: changes).map(\.id)
                == ["two", "three", "four"])
        }
    }

    @Test func contextMenuUsesDisjointSelectionsInDisplayOrder() {
        var selection = ChangeFileSelection()
        selection.select("four", in: files, extendingRange: false, toggling: false)
        selection.select("two", in: files, extendingRange: false, toggling: true)

        #expect(selection.contextMenuFiles(for: changes[3], in: changes).map(\.id)
            == ["two", "four"])
    }

    @Test func contextMenuOnAnUnselectedRowTargetsOnlyThatFile() {
        var selection = ChangeFileSelection()
        selection.select("two", in: files, extendingRange: false, toggling: false)
        selection.select("four", in: files, extendingRange: true, toggling: false)

        #expect(selection.contextMenuFiles(for: changes[0], in: changes) == [changes[0]])
    }

    @Test func contextMenuWorksWithoutASelection() {
        let selection = ChangeFileSelection()

        #expect(selection.contextMenuFiles(for: changes[2], in: changes) == [changes[2]])
    }
}

struct RowStepTests {
    @Test func firstPressOpensTheEndTheKeyPointsAwayFrom() {
        #expect(RowStep.destination(from: nil, step: 1, count: 5) == 0)
        #expect(RowStep.destination(from: nil, step: -1, count: 5) == 4)
    }

    @Test func arrowsMoveOneRowAtATime() {
        #expect(RowStep.destination(from: 2, step: 1, count: 5) == 3)
        #expect(RowStep.destination(from: 2, step: -1, count: 5) == 1)
    }

    @Test func theEndsOfTheListStayPut() {
        #expect(RowStep.destination(from: 4, step: 1, count: 5) == nil)
        #expect(RowStep.destination(from: 0, step: -1, count: 5) == nil)
    }

    @Test func anEmptyListHasNowhereToGo() {
        #expect(RowStep.destination(from: nil, step: 1, count: 0) == nil)
    }
}
