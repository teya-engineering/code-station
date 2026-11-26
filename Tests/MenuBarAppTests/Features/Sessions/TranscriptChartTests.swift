import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MenuBarApp

struct TranscriptChartTests {
    private func fence(_ payload: String) -> String {
        "```\(TranscriptChartSpec.fenceLanguage)\n\(payload)\n```"
    }

    private func spec(_ payload: String) throws -> TranscriptChartSpec {
        try TranscriptChartSpec.parse(payload).get()
    }

    private func blocks(_ text: String) -> [MessageSegment] {
        MessageSegment.split(text)
    }

    @Test func readsATimeSeriesWithItsThreshold() throws {
        let chart = try spec("""
        {"kind":"line","title":"p99 checkout","unit":"ms","time":true,
         "series":[{"label":"checkout","points":[[1757000000,412],[1757000060,438]]}],
         "rules":[{"axis":"y","value":500,"label":"SLO"}]}
        """)

        #expect(chart.kind == .line)
        #expect(chart.title == "p99 checkout")
        #expect(chart.unit == "ms")
        #expect(chart.isTime)
        #expect(chart.series.count == 1)
        #expect(chart.series[0].values == [412, 438])
        #expect(chart.series[0].points.first?.x == .number(1_757_000_000))
        #expect(chart.rules == [.init(axis: .y, value: 500, label: "SLO")])
    }

    @Test func aBarChartNamesItsCategories() throws {
        let chart = try spec("""
        {"kind":"bar","series":[{"label":"5xx","points":[["/pay",812],["/refund",42]]}]}
        """)

        #expect(chart.series[0].points.map(\.x) == [.category("/pay"), .category("/refund")])
        #expect(chart.series[0].values == [812, 42])
    }

    @Test func aStatCarriesItsDeltaAndWhichWayIsGood() throws {
        let rising = try spec("""
        {"kind":"stat","value":4.2,"unit":"%","delta":{"value":3.9,"label":"vs the hour before",
         "goodDirection":"down"}}
        """)
        #expect(rising.value == 4.2)
        #expect(rising.delta?.label == "vs the hour before")
        #expect(rising.delta?.risingIsGood == false)

        // Left unsaid, a rise is the good news, which is the safer way round: a chart that
        // calls a rise good when it was bad is worse than one that says nothing.
        let unsaid = try spec(#"{"kind":"stat","value":99.9,"delta":{"value":0.2}}"#)
        #expect(unsaid.delta?.risingIsGood == true)
    }

    // A reading that came back as null, NaN or an infinity is not a measurement, and
    // plotting it would put a break or a spike in the line that nothing measured.
    @Test func dropsReadingsThatAreNotNumbers() throws {
        let chart = try spec("""
        {"kind":"line","series":[{"label":"rate","points":[[1,4],[2,"n/a"],[3,6]]}]}
        """)
        #expect(chart.series[0].values == [4, 6])
    }

    @Test func keepsTheShapeAndTheEndWhenThereAreTooManyPoints() throws {
        let points = (0..<1200).map { "[\($0),\($0 * 2)]" }.joined(separator: ",")
        let chart = try spec("""
        {"kind":"line","series":[{"label":"count","points":[\(points)]}]}
        """)

        #expect(chart.series[0].points.count == TranscriptChartSpec.pointLimit)
        #expect(chart.series[0].points.first?.x == .number(0))
        #expect(chart.series[0].points.last?.x == .number(1199))
        #expect(chart.series[0].points.last?.y == 2398)
    }

    // The ninth series would have to repeat a colour or invent one. Saying how many were
    // left out beats drawing two series the reader cannot tell apart.
    @Test func cutsTheSeriesThePaletteCannotName() throws {
        let series = (0..<11).map { #"{"label":"s\#($0)","points":[[1,\#($0)]]}"# }
            .joined(separator: ",")
        let chart = try spec(#"{"kind":"line","series":[\#(series)]}"#)

        #expect(chart.series.count == TranscriptChartSpec.seriesLimit)
        #expect(chart.omittedSeriesCount == 3)
    }

    @Test func aChartSitsBetweenTheProseAroundIt() throws {
        let payload = #"{"kind":"line","series":[{"label":"a","points":[[1,2]]}]}"#
        let segments = blocks("""
        The retries start here.

        \(fence(payload))

        Everything after it recovered.
        """)

        #expect(segments.map(\.isChart) == [false, true, false])
        #expect(segments[1].text == payload)
        #expect(try TranscriptChartSpec.parse(segments[1].text).get() == (try spec(payload)))
        #expect(MarkdownBlock.parse(segments[0].text).map(\.kind)
            == [.paragraph("The retries start here.")])
        #expect(MarkdownBlock.parse(segments[2].text).map(\.kind)
            == [.paragraph("Everything after it recovered.")])
    }

    // Dropping it would lose the agent's evidence without saying so.
    @Test func aChartThatCannotBeReadSaysSo() {
        for payload in ["{broken", #"{"kind":"pie","series":[]}"#,
                        #"{"kind":"line","series":[]}"#, #"{"kind":"stat"}"#] {
            #expect(throws: TranscriptChartSpec.Failure.unreadable) {
                try TranscriptChartSpec.parse(payload).get()
            }
        }
    }

    // A block arrives a character at a time like the rest of the reply, so the one at the
    // end of a reply still running is held back until its closing fence lands.
    @Test func showsNothingWhileTheChartIsStillArriving() throws {
        let half = try #require(blocks("Before it\n\n```chart\n{\"kind\":\"li").last)
        #expect(half.isChart)
        #expect(half.isOpen)

        let whole = try #require(blocks(fence(#"{"kind":"line","series":[{"label":"a","points":[[1,2]]}]}"#)).last)
        #expect(whole.isChart)
        #expect(!whole.isOpen)
    }

    // The agent only ever sees the instructions as text, so nothing in them can rely on a
    // character that has no glyph: it would read as though it were not there and be copied
    // back the same way.
    @Test func everyClaudeSessionIsToldHowToDrawOne() {
        #expect(AgentInstructions.appendedSystemPrompt.contains(TranscriptChartSpec.agentInstructions))
        #expect(TranscriptChartSpec.agentInstructions.contains("```chart"))
        #expect(!TranscriptChartSpec.agentInstructions.contains(TranscriptMarker.open))
    }

    @Test func numbersReadAtAGlance() {
        #expect(TranscriptChartFormat.compact(0) == "0")
        #expect(TranscriptChartFormat.compact(412) == "412")
        #expect(TranscriptChartFormat.compact(4.25) == "4.3")
        #expect(TranscriptChartFormat.compact(12_900) == "12.9K")
        #expect(TranscriptChartFormat.compact(4_200_000) == "4.2M")
        #expect(TranscriptChartFormat.value(99.9, unit: "%") == "99.9%")
        #expect(TranscriptChartFormat.value(412, unit: "ms") == "412 ms")
    }

    // MARK: - Evidence fields

    private let reset = """
        {"kind":"line","time":true,"source":"PROMETHEUS","server":"platform-prd",
         "series":[{"label":"balance","unit":"credits","points":[[0,576],[300,576],[600,2.5],[900,3]]},
                   {"label":"cpu","unit":"%","points":[[0,12],[300,14],[600,13],[900,15]]},
                   {"label":"balance, projected","continues":"balance","points":[[900,3],[1500,8]]}],
         "rules":[{"axis":"y","value":20,"unit":"credits","label":"alert under 20","breach":"below"},
                  {"axis":"x","value":600,"label":"new instance","tone":"warn","breach":"below"}],
         "bands":[{"from":700,"label":"alert firing","tone":"bad"},{"from":900,"to":800}],
         "views":[{"label":"The reset","from":300,"to":900},{"label":"backwards","from":9,"to":1}]}
        """

    @Test func readsTheFieldsThatMakeAChartEvidence() throws {
        let chart = try spec(reset)

        #expect(chart.series.map(\.unit) == ["credits", "%", nil])
        #expect(chart.series[2].continues == "balance")
        #expect(chart.rules[0].breach == .below)
        #expect(chart.rules[0].unit == "credits")
        #expect(chart.rules[1].tone == .warn)
        // A moment has no wrong side to be on.
        #expect(chart.rules[1].breach == nil)
        // A band or a window that ends before it starts marks nothing.
        #expect(chart.bands == [.init(from: 700, to: nil, label: "alert firing", tone: .bad)])
        #expect(chart.views == [.init(label: "The reset", from: 300, to: 900)])
        #expect(chart.source == "PROMETHEUS")
        #expect(chart.server == "platform-prd")
    }

    // The chart this was built for: a balance in the hundreds beside a percentage in the
    // teens. On one scale the percentage is a flat line along the floor.
    @Test func seriesWithDifferentUnitsGetTheirOwnScale() throws {
        let lanes = ChartLanes(try spec(reset))

        #expect(lanes.lanes.map(\.unit) == ["credits", "%"])
        let frame = lanes.frame(from: 0, to: 900)
        #expect(frame.scales[0] == .init(low: 0, high: 600))
        #expect(frame.scales[1] == .init(low: 0, high: 20))
        // The level belongs to the lane whose unit it names.
        #expect(lanes.lanes[0].levels.map(\.value) == [20])
        #expect(lanes.lanes[1].levels.isEmpty)
    }

    @Test func aBlockWithNoneOfTheNewFieldsIsOneLane() throws {
        let lanes = ChartLanes(try spec("""
        {"kind":"line","unit":"ms","series":[{"label":"a","points":[[1,400],[2,440]]},
                                              {"label":"b","points":[[1,410],[2,470]]}]}
        """))

        #expect(lanes.lanes.count == 1)
        #expect(lanes.lanes[0].unit == "ms")
        #expect(lanes.solidLines.map(\.slot) == [0, 1])
        #expect(lanes.windows.map(\.label) == [ChartLanes.wholeRange])
        // Readings well above zero keep their own floor, so the change is not flattened.
        #expect(lanes.frame(from: 1, to: 2).scales[0] == .init(low: 400, high: 500))
    }

    @Test func aProjectionTakesItsParentsColourAndSaysItIsOne() throws {
        let lanes = ChartLanes(try spec(reset))
        let balance = try #require(lanes.solidLines.first)

        #expect(lanes.solidLines.map(\.label) == ["balance", "cpu"])
        #expect(lanes.projection(of: balance)?.slot == balance.slot)
        #expect(lanes.readout(balance, at: 600) == .init(value: 2.5, isProjected: false, isBreach: true))
        #expect(lanes.readout(balance, at: 300) == .init(value: 576, isProjected: false, isBreach: false))
        #expect(lanes.readout(balance, at: 1500) == .init(value: 8, isProjected: true, isBreach: true))
        #expect(lanes.readout(lanes.solidLines[1], at: 1500) == nil)
        // The whole range stops at the last measurement while a named window reaches the rest.
        #expect(lanes.windows[0].to == 900)
        #expect(lanes.latest == 900)
    }

    // With no window to jump to, the whole range is the only way to see a projection.
    @Test func theWholeRangeHoldsAProjectionWhenNoWindowIsNamed() throws {
        let lanes = ChartLanes(try spec("""
        {"kind":"line","series":[{"label":"a","points":[[0,1],[10,2]]},
                                  {"label":"later","continues":"a","points":[[10,2],[30,4]]}]}
        """))
        #expect(lanes.windows[0].to == 30)
    }

    @Test func aViewRefitsEachScaleToWhatIsInIt() throws {
        let lanes = ChartLanes(try spec(reset))
        let recovery = lanes.frame(from: 600, to: 900)
        // The level stays on the scale, so the line it must clear is still in sight.
        #expect(recovery.scales[0] == .init(low: 0, high: 20))
        #expect(lanes.summary(lanes.solidLines[0], in: recovery)?.first == 2.5)
        #expect(lanes.summary(lanes.solidLines[0], in: recovery)?.high == 3)
        #expect(lanes.summary(lanes.solidLines[0], in: lanes.frame(from: 1000, to: 1100)) == nil)
    }

    @Test func thePointerSnapsToAReadingInView() throws {
        let lanes = ChartLanes(try spec(reset))
        let frame = lanes.frame(from: 300, to: 900)
        #expect(lanes.snapped(480, in: frame) == 600)
        #expect(lanes.snapped(-50, in: frame) == 300)
    }

    @Test func aBandStillOpenIsNamedWhereItComesIntoView() throws {
        let lanes = ChartLanes(try spec(reset))
        let whole = lanes.frame(from: 0, to: 900)
        #expect(lanes.markers(in: whole).map(\.label) == ["new instance", "alert firing"])
        #expect(lanes.markers(in: lanes.frame(from: 800, to: 900)).map(\.time) == [800])
        #expect(lanes.markers(in: lanes.frame(from: 0, to: 500)).isEmpty)
    }

    // Every case here is a name the reader would otherwise lose to the edge of the card
    // or to the flag beside it.
    @Test func flagsNeverLeaveThePlotOrCoverEachOther() {
        let width: CGFloat = 480

        // Room to the right: the flag hangs there.
        #expect(ChartGeometry.place(flags: [(100, 120)], within: width) == [.init(row: 0, flipped: false)])
        // Near the right edge it flips to the left of its stem.
        #expect(ChartGeometry.place(flags: [(430, 120)], within: width) == [.init(row: 0, flipped: true)])
        // Two close together: the second one goes up a row rather than over the first.
        let close = ChartGeometry.place(flags: [(200, 150), (215, 150)], within: width)
        #expect(close == [.init(row: 1, flipped: false), .init(row: 0, flipped: false)]
            || close == [.init(row: 0, flipped: true), .init(row: 0, flipped: false)])

        for flags in [[(10.0, 300.0), (20, 300), (30, 300), (470, 300)],
                      [(200, 150), (215, 150), (230, 150), (245, 150)],
                      [(0, 500)], [(470, 200), (475, 200), (478, 200)]] as [[(CGFloat, CGFloat)]] {
            let placed = ChartGeometry.place(flags: flags.map { (x: $0.0, width: $0.1) }, within: width)
            var taken: [Int: [ClosedRange<CGFloat>]] = [:]
            for (flag, place) in zip(flags, placed) {
                guard let row = place.row else { continue }
                let span = place.flipped ? flag.0 - flag.1...flag.0 : flag.0...flag.0 + flag.1
                #expect(span.lowerBound >= 0 && span.upperBound <= width)
                #expect(!(taken[row] ?? []).contains { $0.overlaps(span) })
                taken[row, default: []].append(span)
            }
        }
    }

    @Test func theTimeAxisIsMarkedAtTimesPeopleSay() {
        let hour = ChartLanes.ticks(from: 0, to: 3600, limit: 5, isTime: true)
        #expect(hour.step == 900)
        #expect(hour.values == [0, 900, 1800, 2700, 3600])
        #expect(ChartLanes.ticks(from: 0, to: 3600, limit: 5, isTime: false).step == 1000)
        #expect(ChartLanes.niceStep(37) == 50)
        #expect(ChartLanes.gridValues(.init(low: 0, high: 600), steps: 3) == [0, 200, 400, 600])
    }

    @Test func timesAreWrittenOnA24HourClock() {
        let utc = TimeZone(identifier: "UTC")!
        let lisbonSummer = TimeZone(identifier: "Europe/Lisbon")!
        // 2026-07-01 13:05:09 UTC
        let moment = 1_782_911_109.0
        #expect(TranscriptChartFormat.clock(moment, in: utc) == "13:05")
        #expect(TranscriptChartFormat.clock(moment, seconds: true, in: utc) == "13:05:09")
        #expect(TranscriptChartFormat.clock(moment, in: lisbonSummer) == "14:05")
        #expect(TranscriptChartFormat.moment(moment, isTime: true, span: 300, in: utc) == "13:05:09")
        #expect(TranscriptChartFormat.moment(412, isTime: false, span: 300) == "412")
        #expect(TranscriptChartFormat.span(2100) == "35 min")
        #expect(TranscriptChartFormat.span(7800) == "2 h 10 min")
        #expect(TranscriptChartFormat.signed(-573.5) == "-574")
        #expect(TranscriptChartFormat.signed(4.1) == "+4.1")
    }

    @Test func aChangeOfViewMovesTheAxisAndTheScalesTogether() throws {
        let lanes = ChartLanes(try spec(reset))
        let whole = lanes.frame(from: 0, to: 900)
        let recovery = lanes.frame(from: 600, to: 900)
        let half = whole.mixed(with: recovery, 0.5)
        #expect(half.from == 300)
        #expect(half.scales[0].high == 310)
        #expect(whole.mixed(with: recovery, 1) == recovery)
    }

    // A marked moment lands as the line reaches it, and nothing waits once the line is drawn.
    @Test func markersLandAsTheLinePassesThem() {
        #expect(ChartMotion.landed(0.5, drawn: 0.4) == 0)
        #expect(ChartMotion.landed(0.5, drawn: 0.5 + ChartMotion.markerLanding * 2) == 1)
        #expect(ChartMotion.landed(0.99, drawn: 1) == 1)
        // The dot at the end of a line waits for the line to reach it.
        #expect(ChartMotion.endDot(drawn: 0.9) == 0)
        #expect(ChartMotion.endDot(drawn: 1) == 1)
    }

    // A block that was whole but empty is an answer, not a failure, and is told apart so
    // the reader is offered a wider window rather than a redraw.
    @Test func anEmptyChartIsToldApartFromABrokenOne() {
        #expect(throws: TranscriptChartSpec.Failure.noReadings(title: "p99")) {
            try TranscriptChartSpec.parse(#"{"kind":"line","title":"p99","series":[{"label":"a","points":[]}]}"#).get()
        }
        #expect(ChartFollowUp.widen(title: "p99").contains("```chart"))
        #expect(ChartFollowUp.window(title: "p99", from: "10:35", to: "11:10 UTC", change: "a went from 1 to 2.")
            == "Look closer at 10:35 to 11:10 UTC on the chart \"p99\". a went from 1 to 2. "
            + "What else changed in that window? Show what you find as evidence.")
    }

    @Test func theAgentIsToldAboutUnitsAndViews() {
        for field in ["\"unit\"", "\"continues\"", "\"breach\"", "\"bands\"", "\"views\"", "\"source\""] {
            #expect(TranscriptChartSpec.agentInstructions.contains(field))
        }
    }

    // The order of the slots is the mechanism that keeps neighbouring series apart for a
    // colour-blind reader, so a series takes the slot its position names.
    @Test func seriesTakeTheirSlotInOrder() {
        #expect(TranscriptChartPalette.colour(0) == Theme.chartSeries[0])
        #expect(TranscriptChartPalette.colour(7) == Theme.chartSeries[7])
        #expect(Theme.chartSeries.count == TranscriptChartSpec.seriesLimit)
    }

    // A long series name, three windows and a flag at each edge are what used to push a
    // chart past its card. The card must take the width it is given and no more.
    @MainActor @Test(arguments: [480.0, 620.0, 900.0])
    func theChartStaysInsideItsCard(width: Double) throws {
        let long = "{namespace=acceptance-bin, app=acceptance-bin-service, pod=acceptance-bin-service-7d9f8b6c5-x2k4q}"
        let chart = try spec("""
        {"kind":"line","time":true,"title":"acceptance-bin-service-main - CPU credit balance (min) vs CPU % (max)",
         "caption":"The balance fell from 576 to 2.5 in one 5 minute sample while CPU stayed level.",
         "source":"PROMETHEUS","server":"platform-prd",
         "series":[{"label":"\(long)","unit":"credits","points":[[0,576],[300,576],[600,2.5],[900,3]]},
                   {"label":"CPU utilization (max)","unit":"%","points":[[0,12],[300,14],[600,13],[900,15]]}],
         "rules":[{"axis":"x","value":0,"label":"a moment named at the very start of the range"},
                  {"axis":"x","value":900,"label":"a moment named at the very end of the range"}],
         "views":[{"label":"The reset","from":300,"to":900},{"label":"Recovery","from":600,"to":900},
                  {"label":"A third window with a long name","from":0,"to":300}]}
        """)
        for view in [AnyView(TranscriptChartView(spec: chart, arrives: false)),
                     AnyView(ChartArrivingCard()), AnyView(ChartMissingCard(failure: .unreadable))] {
            let card = NSHostingController(rootView: view
                .environment(TooltipPresenter())
                .environment(DialogPresenter())
                .environment(MenuPresenter()))
            let size = card.sizeThatFits(in: CGSize(width: width, height: 4000))
            #expect(size.width <= width)
            #expect(size.height > 0)
        }
    }
}
