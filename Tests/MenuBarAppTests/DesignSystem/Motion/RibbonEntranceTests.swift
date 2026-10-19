import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// When the day ribbon earns its entrance, and how the entrance moves through time.
struct RibbonEntranceTests {
    private let now = Date(timeIntervalSince1970: 1_758_499_200)

    private func ribbon(_ spans: [(start: Double, minutes: Double)]) -> DayRibbon {
        let id = UUID()
        let session = RibbonSession(id: id, title: "A session",
                                    subject: RibbonSubject(name: "robota",
                                                           tint: Theme.projectTint(for: "robota")),
                                    sources: [id], isOpen: false)
        // Each span starts this many hours before now.
        return DayRibbon.build([session], spans: { _ in
            spans.map { span in
                let start = now.addingTimeInterval(-span.start * 3_600)
                return TimeSpan(start: start, end: start.addingTimeInterval(span.minutes * 60))
            }
        }, now: now)
    }

    // MARK: - Earning it

    @Test func aDaySpreadAcrossEnoughSlotsEarnsTheEntrance() {
        // Eight 20 minute stretches, each in a slot of its own.
        let day = ribbon((1...8).map { (start: Double($0) * 2, minutes: 20) })
        #expect(day.spent >= RibbonEntrance.minimumSpent)
        #expect(RibbonEntrance.isDeserved(by: day))
    }

    @Test func aLongStretchInTooFewSlotsOnlyFades() {
        // Two hours in one place fills five 22.5 minute slots at most.
        let day = ribbon([(start: 6, minutes: 90)])
        #expect(day.spent >= RibbonEntrance.minimumSpent)
        #expect(!RibbonEntrance.isDeserved(by: day))
    }

    @Test func manySlotsUnderAnHourOnlyFade() {
        let day = ribbon((1...10).map { (start: Double($0) * 2, minutes: 5) })
        #expect(day.spent < RibbonEntrance.minimumSpent)
        #expect(!RibbonEntrance.isDeserved(by: day))
    }

    // MARK: - Timing

    @Test func runsForAboutThreeSeconds() {
        let play = RibbonEntrance(total: "17h 49m")
        #expect(play.digits == [1, 7, 4, 9])
        #expect(abs(play.duration - 2.904) < 0.001)
    }

    @Test func everyDigitRestsOnItsValueLeftToRight() {
        let play = RibbonEntrance(total: "17h 49m")
        for column in play.digits.indices {
            let landed = play.turn(ofDigit: column, at: play.flightStart)
            #expect(Int(landed.rounded()) % 10 == play.digits[column])
        }
        // Just after the first digit stops, the last is still turning.
        let early = 0.76
        #expect(play.turn(ofDigit: 0, at: early).truncatingRemainder(dividingBy: 10) == 1)
        #expect(play.turn(ofDigit: 3, at: early) < Double(1 * 10 + 9))
    }

    @Test func barsGrowLeftToRightAsTheTotalFlies() {
        let play = RibbonEntrance(total: "2h")
        #expect(play.grow(ofBar: 0, of: 64, at: play.flightStart) == 0)
        let time = play.flightStart + 0.05
        #expect(play.grow(ofBar: 0, of: 64, at: time) > 0)
        #expect(play.grow(ofBar: 31, of: 64, at: time) == 0)
    }

    // Each bar keeps its colours for a second after it starts to grow, so the drain
    // follows the grow wave across the chart.
    @Test func eachBarDrainsASecondAfterItStartsToGrow() {
        let play = RibbonEntrance(total: "2h")
        let start = play.flightStart + 1
        #expect(play.drain(ofBar: 0, of: 64, at: start) < 0.001)
        #expect(play.drain(ofBar: 0, of: 64, at: start + 0.15) > 0)
        #expect(play.drain(ofBar: 10, of: 64, at: start + 0.07) == 0)
        #expect(play.drain(ofBar: 0, of: 64, at: start + 0.3) == 1)
    }

    // A narrow chart spreads its fewer bars over the same time.
    @Test func aNarrowChartTakesTheSameTime() {
        let play = RibbonEntrance(total: "2h")
        let time = play.flightStart + 0.3
        #expect(play.grow(ofBar: 16, of: 32, at: time) == play.grow(ofBar: 32, of: 64, at: time))
    }

    @Test func endsWithTheChartAtRest() {
        let play = RibbonEntrance(total: "17h 49m")
        let end = play.duration
        #expect((0..<64).allSatisfy { play.grow(ofBar: $0, of: 64, at: end) == 1 })
        #expect((0..<20).allSatisfy { play.drain(ofBar: $0, of: 20, at: end) == 1 })
        #expect((0..<64).allSatisfy { play.drain(ofBar: $0, of: 64, at: end) == 1 })
        #expect(play.chartOpacity(at: end) == 1)
        #expect(play.numberOpacity(at: end) == 1)
        #expect(play.restOpacity(at: end) == 1)
        #expect(play.rollOpacity(at: end) == 0)
    }

    @Test func dimsTheChartWhileTheTotalRolls() {
        let play = RibbonEntrance(total: "17h 49m")
        #expect(abs(play.chartOpacity(at: 0.5) - 0.45) < 0.001)
        #expect(play.numberOpacity(at: 0.5) == 0)
    }
}
