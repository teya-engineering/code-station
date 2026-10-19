import Foundation

// How a task's runs are laid out on its page: newest first, under one heading per day,
// so a run reads as "the one from yesterday afternoon" rather than as a date to decode.
public enum TaskRunHistory {
    public enum Filter: CaseIterable, Hashable {
        case all, scheduled, failed

        public var title: String {
            switch self {
            case .all: "All"
            case .scheduled: "Scheduled"
            case .failed: "Failed"
            }
        }
    }

    public struct Day: Identifiable, Equatable {
        let start: Date
        public let title: String
        public let runs: [ChatSession]

        public var id: Date { start }
    }

    // Whether a run failed is only known to the runner, so it is asked rather than read
    // off the run.
    public static func filtered(_ runs: [ChatSession], by filter: Filter,
                         failed: (ChatSession) -> Bool) -> [ChatSession] {
        switch filter {
        case .all: runs
        case .scheduled: runs.filter(\.isScheduledRun)
        case .failed: runs.filter(failed)
        }
    }

    // Runs are grouped by the day they started, since that is the time a row shows.
    public static func days(of runs: [ChatSession], now: Date = Date(),
                     calendar: Calendar = .current) -> [Day] {
        let newestFirst = runs.sorted { $0.createdAt > $1.createdAt }
        var days: [Day] = []
        for run in newestFirst {
            let start = calendar.startOfDay(for: run.createdAt)
            if let last = days.last, last.start == start {
                days[days.count - 1] = Day(start: start, title: last.title,
                                           runs: last.runs + [run])
            } else {
                days.append(Day(start: start, title: dayTitle(start, now: now, calendar: calendar),
                                runs: [run]))
            }
        }
        return days
    }

    public static func dayTitle(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: today) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) { style = style.year() }
        return day.formatted(style)
    }

    // "42s", "4m 12s", "1h 05m": how long a run took, precise enough to compare two runs
    // of the same prompt.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let rest = total % 60
        if hours > 0 { return "\(hours)h " + String(format: "%02dm", minutes) }
        if minutes > 0 { return "\(minutes)m " + String(format: "%02ds", rest) }
        return "\(rest)s"
    }
}
