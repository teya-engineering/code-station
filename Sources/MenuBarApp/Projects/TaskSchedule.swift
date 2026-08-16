import Foundation

// A task schedule keeps both its rule and the small amount of state needed to resume it
// after an app restart. The app must be running for a task to start. A missed occurrence
// is handled once when the app is available again instead of replaying a backlog.
struct TaskSchedule: Codable, Equatable {
    static let countRange = 1...10_000
    static let timeOfDayRange = 0..<(24 * 60)

    enum Timing: String, Codable, CaseIterable, Hashable {
        case interval
        case timeOfDay
    }

    enum IntervalUnit: String, Codable, CaseIterable, Hashable {
        case minutes
        case hours

        var seconds: TimeInterval {
            switch self {
            case .minutes: 60
            case .hours: 3_600
            }
        }

        func label(for amount: Int) -> String {
            switch self {
            case .minutes: amount == 1 ? "minute" : "minutes"
            case .hours: amount == 1 ? "hour" : "hours"
            }
        }
    }

    enum Recurrence: String, Codable, CaseIterable, Hashable {
        case daily
        case weekdays
        case weekly

        var title: String {
            switch self {
            case .daily: "Daily"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            }
        }
    }

    enum Weekday: Int, Codable, CaseIterable, Hashable {
        case monday = 2
        case tuesday = 3
        case wednesday = 4
        case thursday = 5
        case friday = 6
        case saturday = 7
        case sunday = 1

        var shortTitle: String {
            switch self {
            case .monday: "Mon"
            case .tuesday: "Tue"
            case .wednesday: "Wed"
            case .thursday: "Thu"
            case .friday: "Fri"
            case .saturday: "Sat"
            case .sunday: "Sun"
            }
        }

        var title: String {
            switch self {
            case .monday: "Monday"
            case .tuesday: "Tuesday"
            case .wednesday: "Wednesday"
            case .thursday: "Thursday"
            case .friday: "Friday"
            case .saturday: "Saturday"
            case .sunday: "Sunday"
            }
        }
    }

    var isEnabled = false
    var timing: Timing = .interval
    var interval = 30
    var intervalUnit: IntervalUnit = .minutes
    // Minutes after midnight keeps a wall-clock time stable without attaching it to an
    // arbitrary date.
    var timeOfDayMinutes = 9 * 60
    var recurrence: Recurrence = .daily
    var weekday: Weekday = .monday
    var maximumRuns: Int?
    var requiresConfirmation = false

    private(set) var completedRuns = 0
    private(set) var nextRunAt: Date?
    private(set) var isWaitingForConfirmation = false

    var hasReachedMaximum: Bool {
        maximumRuns.map { completedRuns >= $0 } ?? false
    }

    var isActive: Bool {
        guard isEnabled, !hasReachedMaximum else { return false }
        switch timing {
        case .interval:
            return Self.countRange.contains(interval)
                && (maximumRuns.map(Self.countRange.contains) ?? true)
        case .timeOfDay:
            return Self.timeOfDayRange.contains(timeOfDayMinutes)
        }
    }

    var timeText: String {
        String(format: "%02d:%02d", timeOfDayMinutes / 60, timeOfDayMinutes % 60)
    }

    var summary: String {
        switch timing {
        case .interval:
            return "Every \(interval) \(intervalUnit.label(for: interval))"
        case .timeOfDay:
            switch recurrence {
            case .daily: return "Daily at \(timeText)"
            case .weekdays: return "Weekdays at \(timeText)"
            case .weekly: return "Every \(weekday.title) at \(timeText)"
            }
        }
    }

    mutating func restart(at date: Date = Date(), calendar: Calendar = .current) {
        completedRuns = 0
        isWaitingForConfirmation = false
        nextRunAt = isActive ? nextDate(after: date, calendar: calendar) : nil
    }

    mutating func prepareIfNeeded(at date: Date = Date(), calendar: Calendar = .current) {
        guard isActive, nextRunAt == nil, !isWaitingForConfirmation else { return }
        nextRunAt = nextDate(after: date, calendar: calendar)
    }

    mutating func waitForConfirmation() {
        guard isActive, timing == .interval, requiresConfirmation else { return }
        isWaitingForConfirmation = true
    }

    mutating func recordRun(at date: Date = Date(), calendar: Calendar = .current) {
        completedRuns += 1
        isWaitingForConfirmation = false
        if hasReachedMaximum {
            isEnabled = false
            nextRunAt = nil
        } else {
            nextRunAt = nextDate(after: date, calendar: calendar)
        }
    }

    mutating func skip(at date: Date = Date(), calendar: Calendar = .current) {
        isWaitingForConfirmation = false
        nextRunAt = isActive ? nextDate(after: date, calendar: calendar) : nil
    }

    mutating func turnOff() {
        isEnabled = false
        isWaitingForConfirmation = false
        nextRunAt = nil
    }

    func hasSameConfiguration(as other: TaskSchedule) -> Bool {
        isEnabled == other.isEnabled
            && timing == other.timing
            && interval == other.interval
            && intervalUnit == other.intervalUnit
            && timeOfDayMinutes == other.timeOfDayMinutes
            && recurrence == other.recurrence
            && weekday == other.weekday
            && maximumRuns == other.maximumRuns
            && requiresConfirmation == other.requiresConfirmation
    }

    func nextDate(after date: Date, calendar: Calendar = .current) -> Date {
        switch timing {
        case .interval:
            return date.addingTimeInterval(TimeInterval(interval) * intervalUnit.seconds)
        case .timeOfDay:
            return nextTimeOfDay(after: date, calendar: calendar)
        }
    }

    private func nextTimeOfDay(after date: Date, calendar: Calendar) -> Date {
        let hour = timeOfDayMinutes / 60
        let minute = timeOfDayMinutes % 60
        let start = calendar.startOfDay(for: date)

        // Eight days covers every weekly rule and still permits today's time when it is
        // ahead. `nextDate` handles daylight-saving gaps using the calendar's next valid
        // wall-clock time.
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: start),
                  matchesRecurrence(day, calendar: calendar),
                  let candidate = calendar.nextDate(
                    after: day.addingTimeInterval(-1),
                    matching: DateComponents(hour: hour, minute: minute, second: 0),
                    matchingPolicy: .nextTime,
                    direction: .forward),
                  calendar.isDate(candidate, inSameDayAs: day), candidate > date else { continue }
            return candidate
        }

        // The loop always finds a date for supported calendar rules. Keeping a future
        // fallback prevents a malformed external record from becoming due forever.
        return date.addingTimeInterval(86_400)
    }

    private func matchesRecurrence(_ date: Date, calendar: Calendar) -> Bool {
        let value = calendar.component(.weekday, from: date)
        switch recurrence {
        case .daily: return true
        case .weekdays: return (Weekday.monday.rawValue...Weekday.friday.rawValue).contains(value)
        case .weekly: return value == weekday.rawValue
        }
    }

    static func parseTime(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
