import Foundation
import SwiftUI

// How the time an entry happened is written beside it in a transcript.
enum TimestampFormat: String, CaseIterable, Identifiable, Sendable {
    case off
    case time
    case seconds
    case smart

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .time: "Time"
        case .seconds: "Seconds"
        case .smart: "Smart"
        }
    }
}

// Which entries carry a time: every message and every step the agent took, or only the
// messages, for a quieter transcript.
enum TimestampScope: String, CaseIterable, Identifiable, Sendable {
    case messagesAndSteps
    case messages

    var id: String { rawValue }

    var label: String {
        switch self {
        case .messagesAndSteps: "Messages and steps"
        case .messages: "Messages only"
        }
    }
}

struct TranscriptTimestamps: Equatable, Sendable {
    var format: TimestampFormat = .seconds
    var scope: TimestampScope = .messagesAndSteps
    // The day "today" and "yesterday" are measured from. It is part of the value, so a
    // transcript that only redraws when its stamps change still redraws past midnight.
    var today = Calendar.current.startOfDay(for: Date())

    static let off = TranscriptTimestamps(format: .off)

    var showsSteps: Bool { format != .off && scope == .messagesAndSteps }

    // Whether an entry gets a stamp at all, without the cost of writing it. False when
    // stamps are off, when a step's stamp is hidden by "Messages only", or when the entry
    // has no time of its own. An imported conversation that recorded no time is dated the
    // distant past, and "1 Jan 1" would say something false.
    func shows(_ date: Date?, step: Bool = false) -> Bool {
        guard let date, Self.isKnown(date), format != .off else { return false }
        return !step || showsSteps
    }

    func label(for date: Date?, step: Bool = false) -> String? {
        guard let date, shows(date, step: step) else { return nil }
        switch format {
        case .off: return nil
        case .time: return date.formatted(date: .omitted, time: .shortened)
        case .seconds: return date.formatted(date: .omitted, time: .standard)
        case .smart: return RelativeTime.stamp(date, now: today)
        }
    }

    // The whole moment, whatever the row shows: the day as well as the second.
    func tooltip(for date: Date) -> String {
        RelativeTime.stamp(date, seconds: true, now: today)
    }

    static func isKnown(_ date: Date) -> Bool {
        date > Date(timeIntervalSince1970: 0)
    }
}

extension EnvironmentValues {
    @Entry var transcriptTimestamps = TranscriptTimestamps.off
}
