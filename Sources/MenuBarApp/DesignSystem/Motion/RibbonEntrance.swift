import Foundation
import CodeStationCore

// The entrance the day ribbon plays each time Home opens on a full day.
// The total rolls up over the dimmed chart and flies into the headline. As it flies the
// bars grow up from the baseline in their project colours, left to right, and a second
// later each one drains from the top into the accent green, which is how the chart looks
// at rest.
//
// Every value is a pure function of the time since the start, so one clock can drive
// the whole thing and a skip is only a jump to the end.
struct RibbonEntrance {
    // The bar a day has to clear to earn the entrance. A thinner day is drawn the way it
    // always is, with a plain fade.
    static let minimumSlots = 8
    static let minimumSpent: TimeInterval = 3_600
    static let slots = 64

    // The headline's own size and the size the total rolls at, so the flight can shrink
    // one into the other.
    static let headlineSize: CGFloat = 11.5
    static let rollSize: CGFloat = 46

    // The total as it reads in the headline, and its digits in order.
    let total: String
    let digits: [Int]

    private static let roll: TimeInterval = 0.75
    private static let digitStagger: TimeInterval = 0.07
    private static let flightDelay: TimeInterval = 0.14
    private static let flight: TimeInterval = 0.52
    private static let grow: TimeInterval = 0.6
    private static let growStagger: TimeInterval = 0.008
    // How long a bar shows its project colours, from the moment it starts to grow.
    private static let hold: TimeInterval = 1
    private static let drain: TimeInterval = 0.3

    init(total: String) {
        self.total = total
        digits = total.compactMap(\.wholeNumberValue)
    }

    static func isDeserved(by ribbon: DayRibbon) -> Bool {
        guard ribbon.spent >= minimumSpent else { return false }
        let filled = ribbon.activity(bucketCount: slots).filter { $0.spent > 0 }.count
        return filled >= minimumSlots
    }

    // MARK: - Timing

    var flightStart: TimeInterval {
        Self.roll + Double(max(0, digits.count - 1)) * Self.digitStagger + Self.flightDelay
    }

    // The bars grow left to right as the total takes off. The stagger is spread over the
    // full set of slots, so a narrow chart takes the same time.
    private func growStart(ofBar index: Int, of count: Int) -> TimeInterval {
        let scale = Double(Self.slots) / Double(max(count, 1))
        return flightStart + Double(index) * scale * Self.growStagger
    }

    var duration: TimeInterval {
        flightStart + Double(Self.slots - 1) * Self.growStagger + Self.hold + Self.drain
    }

    // How far a digit's strip has turned, in digits. Each column spins one turn more than
    // the one after it, and they land left to right.
    func turn(ofDigit column: Int, at time: TimeInterval) -> Double {
        let spins = Double(digits.count - column)
        let end = Self.roll + Double(column) * Self.digitStagger
        return (spins * 10 + Double(digits[column])) * Self.easeOutQuart(time / end)
    }

    // How far the total has travelled from over the chart into the headline.
    func flight(at time: TimeInterval) -> Double {
        Self.easeInOutCubic((time - flightStart) / Self.flight)
    }

    // The large total fades in as it starts to roll, and hands over to the headline's own
    // text just before it lands.
    func rollOpacity(at time: TimeInterval) -> Double {
        min(Self.clamp(time / 0.16), 1 - Self.clamp((flight(at: time) - 0.7) / 0.3))
    }

    func numberOpacity(at time: TimeInterval) -> Double {
        Self.clamp((flight(at: time) - 0.65) / 0.35)
    }

    func restOpacity(at time: TimeInterval) -> Double {
        Self.clamp((time - flightStart - Self.flight + 0.12) / 0.26)
    }

    // The chart sits at 45% while the total rolls over it, and comes back as it flies.
    func chartOpacity(at time: TimeInterval) -> Double {
        1 - 0.55 * (1 - Self.clamp((time - flightStart) / 0.3)) * Self.clamp(time / 0.2)
    }

    // How far a bar has grown up from the baseline.
    func grow(ofBar index: Int, of count: Int, at time: TimeInterval) -> Double {
        Self.easeOutQuart((time - growStart(ofBar: index, of: count)) / Self.grow)
    }

    // How much of a bar's project colour has drained away from the top.
    func drain(ofBar index: Int, of count: Int, at time: TimeInterval) -> Double {
        Self.easeInOutCubic(
            (time - growStart(ofBar: index, of: count) - Self.hold) / Self.drain)
    }

    // MARK: - Curves

    private static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }

    private static func easeOutQuart(_ x: Double) -> Double {
        1 - pow(1 - clamp(x), 4)
    }

    private static func easeInOutCubic(_ x: Double) -> Double {
        let x = clamp(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}
