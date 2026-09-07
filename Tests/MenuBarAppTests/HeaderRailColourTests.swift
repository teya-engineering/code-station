import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The rail says its states in colour, on a 13pt glyph, which is the least a colour can be
// asked to carry. What keeps that readable is the seat under the glyph, so these measure
// the pairs rather than trusting that the two greens look different enough.
struct HeaderRailColourTests {
    // A seat is a fill, not text, so what it has to do is read as a different surface from
    // the bare header once the hue is taken away.
    private static let surfaceSeparation = 1.15

    @Test func aStateSeparatesFromRestWithoutItsHue() throws {
        for appearance in try appearances() {
            for header in [Theme.background, Theme.card] {
                let bare = try swatch(header, in: appearance)
                let marks: [(String, Color)] = [
                    ("open seat", try #require(HeaderRailState.open.seat)),
                    ("live seat", try #require(HeaderRailState.live.seat)),
                    ("waiting dot", Theme.attention),
                ]

                for (part, mark) in marks {
                    let drawn = try swatch(mark, in: appearance).over(bare)
                    #expect(drawn.contrast(against: bare) >= Self.surfaceSeparation,
                            "\(part) on \(appearance.name.rawValue)")
                }
            }
        }
    }

    @Test func aGlyphIsReadableOnItsOwnSeat() throws {
        for appearance in try appearances() {
            for header in [Theme.background, Theme.card] {
                let bare = try swatch(header, in: appearance)
                for state in [HeaderRailState.open, .live] {
                    let seat = try swatch(#require(state.seat), in: appearance).over(bare)
                    let glyph = try swatch(state.tint, in: appearance)
                    #expect(glyph.contrast(against: seat) >= 4.5,
                            "\(state) glyph on \(appearance.name.rawValue)")
                }
            }
        }
    }

    // Resting and working are the two states with nothing behind the glyph: at rest there
    // is nothing to say, and a job that is running is gone again in a moment.
    @Test func onlyASettledStateTakesASeat() {
        #expect(HeaderRailState.rest.seat == nil)
        #expect(HeaderRailState.working.seat == nil)
        #expect(HeaderRailState.open.seat != nil)
        #expect(HeaderRailState.live.seat != nil)
    }

    // Green on the rail has to mean a phone is on the other end. A code that is out with
    // nothing attached used to wear the same accent as an open panel.
    @Test func aShareWithNoPhoneOnItKeepsItsColourOff() {
        #expect(MobileAccessButton.rail(shared: false, connected: false) == (.rest, false))
        #expect(MobileAccessButton.rail(shared: true, connected: false) == (.rest, true))
        #expect(MobileAccessButton.rail(shared: true, connected: true) == (.live, false))
    }
}
