import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// The sidebar says a session's state with a band across the top of its card, and says a
// row is pinned with a mark on its tile or its rail. These hold what the marks have to
// keep true: each live state has a band that differs from the others without its colour,
// the words on a band stay readable, the drifting stripes never leave a gap, and the pin on
// the rail takes no room from the card beside it.
@MainActor
struct SidebarStateMarksTests {
    @Test func everyLiveStateHasABandAndIdleHasNone() {
        #expect(SessionTone.idle.band == nil)
        #expect(SessionTone.needsYou.band != nil)
        #expect(SessionTone.running.band != nil)
        #expect(SessionTone.waiting.band != nil)
    }

    // With the colour taken away, the pattern and its motion still tell the three apart:
    // still stripes, moving stripes, no stripes.
    @Test func theBandsDifferWithoutTheirColour() throws {
        let needsYou = try #require(SessionTone.needsYou.band)
        let running = try #require(SessionTone.running.band)
        let waiting = try #require(SessionTone.waiting.band)

        #expect(needsYou.stripe != nil && !needsYou.drifts)
        #expect(running.stripe != nil && running.drifts)
        #expect(waiting.stripe == nil && !waiting.drifts)
    }

    // The drift slides the stripes one whole period to the right and starts over, so the
    // path has to reach a period further left than the band, or a gap would open at the
    // left edge just before each restart.
    @Test func theStripesCoverTheBandWhereverTheDriftHasGot() {
        let size = CGSize(width: 120, height: 18)
        let period = Stripes.period
        let still = Stripes.path(in: size, period: period).boundingRect
        let drifting = Stripes.path(in: size, period: period, lead: period).boundingRect

        #expect(still.minX <= 0 && still.maxX >= size.width)
        #expect(drifting.minX + period <= 0)
        #expect(drifting.maxX >= size.width)
    }

    // The word is drawn on the darkest part of its band: a stripe, over the band, over an
    // unselected card in the sidebar. It is a short label with the light beside it, so it
    // is held to the 3:1 asked of large text rather than the 4.5:1 of body text. The amber
    // that reads as words cannot reach 4.5:1 on any amber band light enough to see.
    @Test func theWordOnABandIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let card = try swatch(Theme.sunken, in: appearance)
                .over(try swatch(Theme.sidebar, in: appearance))

            for tone in [SessionTone.needsYou, .running, .waiting] {
                let band = try #require(tone.band)
                var surface = try swatch(band.fill, in: appearance).over(card)
                if let stripe = band.stripe {
                    surface = try swatch(stripe, in: appearance).over(surface)
                }
                let word = try swatch(band.word, in: appearance)
                #expect(word.contrast(against: surface) >= 3,
                        "\(tone.word) on \(appearance.name.rawValue): \(word.contrast(against: surface))")
            }
        }
    }

    // Held to the same 3:1 as the band word, for the same reason.
    @Test func theCountChipIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let amber = try swatch(Theme.attention, in: appearance)
            let row = try swatch(Theme.sidebar, in: appearance)
            let chip = amber.faded(to: 0.34).over(amber.faded(to: 0.16).over(row))
            let count = try swatch(Theme.attentionText, in: appearance)

            #expect(count.contrast(against: chip) >= 3,
                    "count on \(appearance.name.rawValue): \(count.contrast(against: chip))")
        }
    }

    @Test func theCountChipNamesWhatItCounts() {
        #expect(NeedsYouChip.label(1) == "1 waiting for you")
        #expect(NeedsYouChip.label(3) == "3 waiting for you")
    }

    // The pin is wider than the dot it replaces, so it has to overhang its slot rather
    // than push the card along.
    @Test func thePinOnTheRailTakesNoRoom() throws {
        func width(pinned: Bool) throws -> Int {
            let renderer = ImageRenderer(content:
                SidebarRailRow(colour: .gray, pinned: pinned) {
                    Color.clear.frame(width: 40, height: 20)
                }
                .fixedSize())
            renderer.scale = 1
            return try #require(renderer.cgImage, "the rail row did not render").width
        }
        #expect(try width(pinned: true) == width(pinned: false))
    }

    // The sidebar draws its rail one row at a time so a lazy list can skip the rows that
    // are off screen. It has to look exactly like the rail drawn as one block, with the
    // line bridging the gaps the list leaves and stopping at the last dot.
    @Test func aRailDrawnRowByRowMatchesTheWholeRail() throws {
        let heights: [CGFloat] = [30, 52, 30]
        let spacing: CGFloat = 1

        func pixels<Content: View>(_ content: Content) throws -> (width: Int, height: Int, data: Data) {
            let renderer = ImageRenderer(content: content
                .frame(width: 120, alignment: .topLeading)
                .background(Color.white)
                .fixedSize())
            renderer.scale = 2
            let image = try #require(renderer.cgImage, "the rail did not render")
            let data = try #require(image.dataProvider?.data as Data?)
            return (image.width, image.height, data)
        }

        // The row the cards hang under. In the whole rail it sits flush on the block; in
        // the list it is one more row with the list's gap after it.
        let header = Color.red.frame(height: 10)
        let whole = try pixels(
            VStack(alignment: .leading, spacing: 0) {
                header
                SidebarRail(colour: .blue) {
                    ForEach(heights.indices, id: \.self) { i in
                        SidebarRailRow(colour: .blue, pinned: i == 1) {
                            Color.clear.frame(height: heights[i])
                        }
                    }
                }
            })
        let rowByRow = try pixels(
            VStack(alignment: .leading, spacing: spacing) {
                header
                ForEach(heights.indices, id: \.self) { i in
                    SidebarRailRow(colour: .blue, pinned: i == 1) {
                        Color.clear.frame(height: heights[i])
                    }
                    .sidebarRailSegment(colour: .blue, isFirst: i == 0,
                                        isLast: i == heights.count - 1, stackSpacing: spacing)
                }
            })

        #expect(rowByRow.width == whole.width)
        #expect(rowByRow.height == whole.height)
        // The pin's symbol is smoothed a shade differently from one render to the next,
        // so its edge pixels may be one step apart. A rail line out of place is far more.
        let largestDifference = zip(rowByRow.data, whole.data)
            .map { abs(Int($0) - Int($1)) }
            .max() ?? 0
        #expect(largestDifference <= 2)
    }

    // The pin on a tile is decoration, so the row has to say it in words.
    @Test func aPinnedRowSaysSoToVoiceOver() {
        #expect(SidebarRowValue.text(current: nil, viewing: nil, pinned: false) == "")
        #expect(SidebarRowValue.text(current: nil, viewing: nil, pinned: true) == "Pinned")
        #expect(SidebarRowValue.text(current: "Current project", viewing: "Fix login",
                                     pinned: true)
            == "Current project. Viewing Fix login, Pinned")
        #expect(SidebarRowValue.text(current: "Current project", viewing: nil, pinned: false)
            == "Current project")
    }
}
