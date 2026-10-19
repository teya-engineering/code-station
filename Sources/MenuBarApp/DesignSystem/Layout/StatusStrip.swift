import AppKit
import SwiftUI
import CodeStationCore

// MARK: - Status strip

// The thin line under a header, and the pieces every one of them is made of. A screen
// names itself on the band above and describes itself here, always in the same order and
// the same type: what it is, what state it is in, what it can run. Building the parts
// once is what keeps the project, workspace, task and session strips reading as one line
// with different readings on it rather than as four lines.

// A reading that names a state: mono capitals, tinted only when the state is worth
// noticing.
struct StatusCaps: View {
    let text: String
    var tint: Color? = nil
    var size: CGFloat = 10.5

    var body: some View {
        Text(text)
            .font(.mono(size, .semibold))
            .kerning(0.6)
            .foregroundStyle(tint ?? Color.secondary)
            .fixedSize()
    }
}

// A reading that carries a value rather than a state: the same size in plain mono, so a
// branch or a commit subject sits under the words of the header without competing.
struct StatusValue: View {
    let text: String
    var tint: Color? = nil
    var truncation: Text.TruncationMode = .tail
    var size: CGFloat = 10.5

    var body: some View {
        Text(text)
            .font(.mono(size))
            .foregroundStyle(tint ?? Color.secondary)
            .lineLimit(1)
            .truncationMode(truncation)
    }
}

// The separator between two readings that belong to the same item.
struct StatusDot: View {
    var size: CGFloat = 10.5

    var body: some View {
        Text("·").font(.mono(size)).foregroundStyle(.tertiary)
    }
}

// The separator between readings about different things. A rule rather than more space,
// which a strip this thin does not have to give.
struct StatusRule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 14)
    }
}

// "2m", "3h", "2d": short enough to sit at the end of a narrow row.
enum RelativeTime {
    // The rungs a reading climbs: how many seconds each unit holds and the letter it is
    // written with. A reading takes the largest unit it has at least one of.
    private static let units: [(seconds: TimeInterval, letter: String)] = [
        (1, "s"), (60, "m"), (3_600, "h"), (86_400, "d"), (604_800, "w")
    ]

    private static func reading(_ seconds: TimeInterval, weeks: Bool) -> String {
        let rungs = weeks ? units[...] : units.dropLast()
        let unit = rungs.last { seconds >= $0.seconds } ?? units[0]
        return "\(Int(seconds / unit.seconds))\(unit.letter)"
    }

    static func short(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        return seconds < 60 ? "now" : reading(seconds, weeks: true)
    }

    // "41s", "2m", "1h": a length of time rather than a point in it, for the rows that
    // count seconds. Seconds are kept because the first minute of a build is the part
    // being watched, which is exactly where `short` says only "now". It stops at days:
    // a run that has lasted weeks is stuck, and "16d" says so better than "2w".
    static func duration(since date: Date) -> String {
        reading(max(0, Date().timeIntervalSince(date)), weeks: false)
    }

    // "today 09:41", "yesterday 16:18", "3 Aug 11:02": what a row shows when the reader
    // is deciding which session to come back to rather than how fresh it is.
    static func stamp(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }
}

// A name that gets replaced rather than edited, most often the moment a session's first
// prompt takes "New session" over. The new name fades in where the old one was, so the
// replacement is clear without drawing both names together.
extension View {
    func changingName(_ name: String) -> some View {
        modifier(ChangingName(name: name))
    }
}

private struct ChangingName: ViewModifier {
    let name: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Slow for an animation, and deliberately so: this runs once in a session's life,
    // while the eye is still on the composer the name came from. Anything quicker is
    // over before it is looked at, and reads as the name having always been there.
    private static let duration = 0.7

    // The words change inside the one view instead of a new copy being stacked over the
    // old one. Stacking keys the view on the name itself, so a row the list hands to
    // another session counts as a name change and draws both names at once, and the old
    // one has no property left to animate away with: it stays until the row is rebuilt.
    func body(content: Content) -> some View {
        content
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: Self.duration), value: name)
    }
}
