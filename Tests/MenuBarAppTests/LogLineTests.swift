import Foundation
import Testing
@testable import MenuBarApp

// Splitting a log file back into entries. The log is read when something has gone wrong,
// so nothing in a file may be dropped on the way to the screen.
struct LogLineTests {

    @Test func splitsAnEntryIntoItsThreeParts() {
        let lines = LogLine.parse("12:04:31.220 [4f2ab8c1] stream: assistant text\n")
        #expect(lines.count == 1)
        #expect(lines[0].time == "12:04:31.220")
        #expect(lines[0].session == "4f2ab8c1")
        #expect(lines[0].message == "stream: assistant text")
    }

    // App-level entries carry dashes where a session id would be, which is nothing worth
    // showing in a column of its own.
    @Test func leavesTheSessionColumnEmptyForTheAppsOwnLines() {
        let lines = LogLine.parse("09:00:00.001 [--------] app launched\n")
        #expect(lines[0].session == "")
        #expect(lines[0].message == "app launched")
    }

    // A crash report or a stray write is exactly the kind of thing worth seeing, so a
    // line that does not fit the format is kept whole rather than dropped.
    @Test func keepsLinesItCannotSplit() {
        let lines = LogLine.parse("something else entirely\n\n12:00:00.000 [aabbccdd] fine\n")
        #expect(lines.count == 2)
        #expect(lines[0].message == "something else entirely")
        #expect(lines[0].time == "")
        #expect(lines[1].message == "fine")
    }

    @Test func keepsTheRestOfAMessageThatHasSpacesInIt() {
        let lines = LogLine.parse("12:00:00.000 [aabbccdd] tool result [id 7] took 4.2s")
        #expect(lines[0].message == "tool result [id 7] took 4.2s")
    }
}
