import Foundation
import Testing
@testable import MenuBarApp

// The box is small but it carries three rules that only show up in combination: when the
// field stays on screen, which clear makes the rail chase the current row, and how long a
// reveal granted to one row survives.
struct SidebarFilterBoxTests {

    // MARK: - When the field is on screen

    @Test func theFieldIsHiddenUntilItIsAskedForOrTypedIn() {
        var box = SidebarFilterBox()
        #expect(!box.showsField)

        box.openField()
        #expect(box.showsField)
    }

    // Text keeps the field up on its own, so a filter arriving from anywhere else is
    // never invisible while it is narrowing the rail.
    @Test func textAloneKeepsTheFieldUp() {
        var box = SidebarFilterBox()
        box.text = "teya"

        #expect(box.showsField)
    }

    // The close button empties a box with something in it and closes one already empty,
    // so it never needs a second press to get out of the way.
    @Test func theCloseButtonEmptiesFirstAndClosesSecond() {
        var box = SidebarFilterBox()
        box.openField()
        box.text = "teya"

        box.closeOrClear()
        #expect(box.text.isEmpty)
        #expect(box.showsField, "the field closed while it still had text to clear")

        box.closeOrClear()
        #expect(!box.showsField)
    }

    // MARK: - Which clear chases the current row

    // A clear by a person is a request to see everything again, so the rail is free to
    // jump back to wherever the current row ended up.
    @Test func aPlainClearLeavesNoNoteBehind() {
        var box = SidebarFilterBox()
        box.text = "teya"

        box.clear()
        let leftANote = box.wasClearedForDisclosure()

        #expect(box.text.isEmpty)
        #expect(!leftANote)
    }

    // Opening or closing a row while filtering clears the box too, but the click already
    // said where to look, so the rail must not also chase the current row.
    @Test func aDisclosureClearLeavesANoteForTheClearThatFollows() {
        var box = SidebarFilterBox()
        box.text = "teya"

        box.clearForDisclosure()
        let leftANote = box.wasClearedForDisclosure()

        #expect(box.text.isEmpty)
        #expect(leftANote)
    }

    // The note is answered once. A note left standing would swallow the next clear a
    // person made, and the rail would stop following them entirely.
    @Test func theNoteIsAnsweredOnceAndThenForgotten() {
        var box = SidebarFilterBox()
        box.text = "teya"
        box.clearForDisclosure()

        let first = box.wasClearedForDisclosure()
        let second = box.wasClearedForDisclosure()

        #expect(first)
        #expect(!second, "the note survived being answered")
    }

    // The sequence the sidebar actually sees: a disclosure clear, then a person filtering
    // again and clearing it themselves. Only the second one should move the rail.
    @Test func aPersonsClearAfterADisclosureStillMovesTheRail() {
        var box = SidebarFilterBox()
        box.text = "teya"
        box.clearForDisclosure()
        let fromDisclosure = box.wasClearedForDisclosure()

        box.text = "station"
        box.clear()
        let fromPerson = box.wasClearedForDisclosure()

        #expect(fromDisclosure)
        #expect(!fromPerson)
    }

    // MARK: - Revealing one row's sessions

    // A row opened while filtering shows all its sessions, so a match can be explored
    // without emptying the box first.
    @Test func openingARowWhileFilteringRevealsItWhole() {
        let project = UUID()
        var box = SidebarFilterBox()
        box.text = "teya"

        box.reveal(project)

        #expect(box.revealsEverything(in: project))
        #expect(!box.revealsEverything(in: UUID()))
    }

    // With the whole rail showing there is nothing for a reveal to widen, and a reveal
    // recorded now would outlive the filter that justified it.
    @Test func openingARowWithNoFilterRevealsNothing() {
        let project = UUID()
        var box = SidebarFilterBox()

        box.reveal(project)

        #expect(!box.revealsEverything(in: project))
    }

    // A new query makes the reveal stale: it was granted against the old one, and the new
    // one may not match that row at all.
    @Test func typingDropsTheRevealItWasGrantedUnder() {
        let project = UUID()
        var box = SidebarFilterBox()
        box.text = "teya"
        box.reveal(project)

        box.text = "station"
        box.typed()

        #expect(!box.revealsEverything(in: project))
    }

    // MARK: - The rule it hands out

    // Whitespace is not a filter. A box holding only spaces leaves the rail whole.
    @Test func whitespaceAloneIsNotAFilter() {
        var box = SidebarFilterBox()
        box.text = "   "

        #expect(!box.isActive)
        #expect(box.query.isEmpty)
        #expect(box.filter.matches(name: "anything"))
    }

    @Test func theQueryIsHandedOutTrimmed() {
        var box = SidebarFilterBox()
        box.text = "  teya  "

        #expect(box.isActive)
        #expect(box.query == "teya")
        #expect(box.filter.matches(name: "Teya Code Station"))
    }
}
