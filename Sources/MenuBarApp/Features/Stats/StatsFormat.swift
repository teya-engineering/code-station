import Foundation

// How Stats writes its readings. Long stretches read in hours and minutes, the way Home's
// ribbon writes them; short waits keep their seconds, since a reply in 40 seconds and one
// in four minutes are the difference being looked for.
enum StatsFormat {
    static func time(_ seconds: TimeInterval) -> String {
        seconds <= 0 ? "0m" : DayRibbon.duration(seconds)
    }

    static func short(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "–" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 {
            let rest = whole % 60
            return rest == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(rest)s"
        }
        return DayRibbon.duration(seconds)
    }

    // The axis of the time chart: hours once there are hours to show.
    static func axis(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 { return "\((seconds / 3_600).formatted(.number.precision(.fractionLength(0...1))))h" }
        return "\(Int((seconds / 60).rounded()))m"
    }

    static func money(_ amount: Double) -> String {
        amount >= 1_000 ? "$" + amount.formatted(.number.precision(.fractionLength(0))) : Money.short(amount)
    }

    static func count(_ value: Int) -> String { value.formatted() }

    static func tokens(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "–" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func average(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
