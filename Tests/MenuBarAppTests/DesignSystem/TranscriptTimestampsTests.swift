import Foundation
import Testing
@testable import MenuBarApp

// The time written beside each transcript entry, picked in Settings → Appearance.
@MainActor
struct TranscriptTimestampsTests {
    private let moment = Date()

    @Test func offAndMessagesAndStepsAreTheDefaultAndThePickIsKept() throws {
        let defaults = scratchDefaults()

        #expect(Preferences.timestampFormat.read(in: defaults) == .off)
        #expect(Preferences.timestampScope.read(in: defaults) == .messagesAndSteps)
        Preferences.timestampFormat.write(.smart, in: defaults)
        Preferences.timestampScope.write(.messages, in: defaults)
        #expect(Preferences.timestampFormat.read(in: defaults) == .smart)
        #expect(Preferences.timestampScope.read(in: defaults) == .messages)
        defaults.set("not-a-format", forKey: "timestampFormat")
        defaults.set("not-a-scope", forKey: "timestampScope")
        #expect(Preferences.timestampFormat.read(in: defaults) == .off)
        #expect(Preferences.timestampScope.read(in: defaults) == .messagesAndSteps)
    }

    @Test func offWritesNoTime() {
        #expect(TranscriptTimestamps.off.label(for: moment) == nil)
        #expect(!TranscriptTimestamps.off.showsSteps)
    }

    // An imported conversation that recorded no time is dated the distant past.
    @Test func anEntryWithNoKnownTimeHasNoStamp() {
        let stamps = TranscriptTimestamps()
        #expect(stamps.label(for: nil) == nil)
        #expect(stamps.label(for: .distantPast) == nil)
    }

    @Test func eachFormatWritesItsOwnShape() {
        func label(_ format: TimestampFormat) -> String? {
            TranscriptTimestamps(format: format).label(for: moment)
        }
        #expect(label(.time) == moment.formatted(date: .omitted, time: .shortened))
        #expect(label(.seconds) == moment.formatted(date: .omitted, time: .standard))
        #expect(label(.smart) == "today \(moment.formatted(date: .omitted, time: .shortened))")
    }

    @Test func hoverAlwaysGivesTheDayAndTheSecond() {
        for format in [TimestampFormat.time, .seconds, .smart] {
            #expect(TranscriptTimestamps(format: format).tooltip(for: moment)
                == "today \(moment.formatted(date: .omitted, time: .standard))")
        }
    }

    @Test func messagesOnlyKeepsStepsUnstamped() {
        #expect(TranscriptTimestamps(scope: .messagesAndSteps).showsSteps)
        #expect(!TranscriptTimestamps(scope: .messages).showsSteps)
        let quiet = TranscriptTimestamps(scope: .messages)
        #expect(quiet.shows(moment))
        #expect(!quiet.shows(moment, step: true))
        #expect(quiet.label(for: moment, step: true) == nil)
        #expect(TranscriptTimestamps().shows(moment, step: true))
        #expect(!TranscriptTimestamps.off.shows(moment))
        #expect(!TranscriptTimestamps().shows(.distantPast))
    }

    // An equatable message only redraws when its stamps change, so the day has to be
    // part of them for "today" to become "yesterday" after midnight.
    @Test func theDayItIsNowDecidesTodayAndYesterday() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: moment)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        let time = moment.formatted(date: .omitted, time: .standard)
        let before = TranscriptTimestamps(format: .smart, today: today)
        let after = TranscriptTimestamps(format: .smart, today: tomorrow)
        #expect(before != after)
        #expect(before.tooltip(for: moment) == "today \(time)")
        #expect(after.tooltip(for: moment) == "yesterday \(time)")
        #expect(after.label(for: moment)?.hasPrefix("yesterday ") == true)
    }

    @Test func aDateFromAnotherYearNamesTheYear() throws {
        let calendar = Calendar.current
        let lastYear = try #require(calendar.date(byAdding: .year, value: -1, to: moment))
        let stamp = TranscriptTimestamps().tooltip(for: lastYear)
        #expect(stamp.contains(String(calendar.component(.year, from: lastYear))))
        let earlierThisYear = try #require(calendar.date(from: DateComponents(
            year: calendar.component(.year, from: moment), month: 1, day: 1, hour: 9)))
        let tooltip = TranscriptTimestamps().tooltip(for: earlierThisYear)
        if !tooltip.hasPrefix("today"), !tooltip.hasPrefix("yesterday") {
            #expect(!tooltip.contains(String(calendar.component(.year, from: moment))))
        }
    }
}
