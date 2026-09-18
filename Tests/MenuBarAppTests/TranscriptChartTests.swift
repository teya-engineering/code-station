import Foundation
import Testing
@testable import MenuBarApp

struct TranscriptChartTests {
    private func marker(_ payload: String) -> String {
        "\(TranscriptMarker.open)chart\(TranscriptMarker.separator)\(payload)\(TranscriptMarker.close)"
    }

    private func spec(_ payload: String) throws -> TranscriptChartSpec {
        let parsed = try #require(TranscriptChartSpec.parse(marker(payload)))
        return try parsed.get()
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
        let chart = try spec(#"{"kind":"line","series":[{"label":"a","points":[[1,2]]}]}"#)
        let blocks = MarkdownBlock.parse("""
        The retries start here.

        \(marker(#"{"kind":"line","series":[{"label":"a","points":[[1,2]]}]}"#))

        Everything after it recovered.
        """)

        #expect(blocks.map(\.kind) == [
            .paragraph("The retries start here."),
            .chart(chart),
            .paragraph("Everything after it recovered."),
        ])
    }

    // Dropping it would lose the agent's evidence without saying so, and showing the raw
    // line would put control characters in the transcript.
    @Test func aChartThatCannotBeReadSaysSo() {
        for payload in ["{broken", #"{"kind":"pie","series":[]}"#,
                        #"{"kind":"line","series":[]}"#, #"{"kind":"stat"}"#] {
            #expect(MarkdownBlock.parse(marker(payload)).map(\.kind) == [.unreadableChart],
                    "\(payload) should not draw a chart")
        }
    }

    // A marker arrives a character at a time like the rest of the reply.
    @Test func showsNothingWhileTheMarkerIsStillArriving() {
        let half = "\(TranscriptMarker.open)chart\(TranscriptMarker.separator){\"kind\":\"li"
        #expect(MarkdownBlock.parse(half).isEmpty)
        #expect(MarkdownBlock.parse("Before it\n\n\(half)").map(\.kind) == [.paragraph("Before it")])
    }

    @Test func everyClaudeSessionIsToldHowToDrawOne() {
        #expect(SessionRunner.appendedSystemPrompt.contains(TranscriptChartSpec.agentInstructions))
        #expect(TranscriptChartSpec.agentInstructions.contains(marker("").dropLast()))
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

    // The order of the slots is the mechanism that keeps neighbouring series apart for a
    // colour-blind reader, so a series takes the slot its position names.
    @Test func seriesTakeTheirSlotInOrder() {
        #expect(TranscriptChartPalette.colour(0) == Theme.chartSeries[0])
        #expect(TranscriptChartPalette.colour(7) == Theme.chartSeries[7])
        #expect(Theme.chartSeries.count == TranscriptChartSpec.seriesLimit)
    }
}
