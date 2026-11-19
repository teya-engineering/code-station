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

    static let off = TranscriptTimestamps(format: .off)

    var showsSteps: Bool { format != .off && scope == .messagesAndSteps }

    // Nil when stamps are off, or when the entry has no time of its own. An imported
    // conversation that recorded no time is dated the distant past, and "1 Jan 1" would
    // say something false.
    func label(for date: Date?) -> String? {
        guard let date, Self.isKnown(date) else { return nil }
        switch format {
        case .off: return nil
        case .time: return date.formatted(date: .omitted, time: .shortened)
        case .seconds: return date.formatted(date: .omitted, time: .standard)
        case .smart: return RelativeTime.stamp(date)
        }
    }

    // The whole moment, whatever the row shows: the day as well as the second.
    func tooltip(for date: Date) -> String {
        RelativeTime.stamp(date, seconds: true)
    }

    static func isKnown(_ date: Date) -> Bool {
        date > Date(timeIntervalSince1970: 0)
    }
}

extension EnvironmentValues {
    @Entry var transcriptTimestamps = TranscriptTimestamps.off
}
