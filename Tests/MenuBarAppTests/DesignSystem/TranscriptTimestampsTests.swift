import Foundation
import Testing
@testable import MenuBarApp

// The time written beside each transcript entry, picked in Settings → Appearance.
@MainActor
struct TranscriptTimestampsTests {
    private let moment = Date()

    @Test func secondsAndMessagesAndStepsAreTheDefaultAndThePickIsKept() throws {
        let suite = "TranscriptTimestampsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Preferences.timestampFormat(in: defaults) == .seconds)
        #expect(Preferences.timestampScope(in: defaults) == .messagesAndSteps)
        Preferences.setTimestampFormat(.smart, in: defaults)
        Preferences.setTimestampScope(.messages, in: defaults)
        #expect(Preferences.timestampFormat(in: defaults) == .smart)
        #expect(Preferences.timestampScope(in: defaults) == .messages)
        defaults.set("not-a-format", forKey: "timestampFormat")
        defaults.set("not-a-scope", forKey: "timestampScope")
        #expect(Preferences.timestampFormat(in: defaults) == .seconds)
        #expect(Preferences.timestampScope(in: defaults) == .messagesAndSteps)
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
    }
}
