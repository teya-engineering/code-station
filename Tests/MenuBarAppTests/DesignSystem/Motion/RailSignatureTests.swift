import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The rail stays still until a hand reaches for it, and lets go as soon as the hand
// leaves. These hold the glyph's acts and the wash's hand-off between seats to that.
@MainActor
struct RailSignatureTests {
    private static let drawnTools: [RailTool] = [.preview, .terminal, .find, .export, .recap, .ask, .more]

    @Test func aGlyphActsOnlyWhilePointedAt() {
        for tool in Self.drawnTools {
            let glyph = RailGlyphView(tool: tool)
            glyph.frame = NSRect(x: 0, y: 0, width: RailGlyph.side, height: RailGlyph.side)
            glyph.update(colour: .black, caret: nil, glow: .black, lit: false, playing: false)
            #expect(glyph.acts.isEmpty, "\(tool) moved at rest")

            glyph.update(colour: .black, caret: nil, glow: .black, lit: true, playing: true)
            #expect(glyph.acts.contains { $0.hasPrefix("act.") }, "\(tool) did not act")

            // Leaving eases every part back to rest rather than carrying on.
            glyph.update(colour: .black, caret: nil, glow: .black, lit: false, playing: false)
            #expect(!glyph.acts.contains { $0.hasPrefix("act.") }, "\(tool) kept acting")
            #expect(glyph.acts.allSatisfy { $0 == "settle" }, "\(tool) left \(glyph.acts)")
        }
    }

    // A colour change alone, such as keyboard focus, never starts an act.
    @Test func colourAloneDoesNotAct() {
        let glyph = RailGlyphView(tool: .preview)
        glyph.update(colour: .black, caret: nil, glow: .black, lit: false, playing: false)
        glyph.update(colour: .white, caret: nil, glow: .black, lit: true, playing: false)
        #expect(glyph.acts.isEmpty)
    }

    @Test func eachToolDrawsTheSymbolItStandsFor() {
        #expect(RailTool.preview.draws("globe"))
        #expect(RailTool.recap.draws("lightbulb"))
        // A recap still being written shows an hourglass, which keeps the system symbol.
        #expect(!RailTool.recap.draws("hourglass"))
        #expect(!RailTool.export.draws("hourglass"))
        #expect(RailTool.opinion.symbol == nil)
    }

    // Open-in and the overflow have no colour of their own, so their hints carry no dot.
    @Test func onlyAToolWithAColourMarksItsHint() {
        #expect(RailTool.more.tint.colour == nil)
        for tool in [RailTool.opinion, .preview, .terminal, .find, .export, .recap, .ask] {
            #expect(tool.tint.colour != nil, "\(tool)")
        }
    }

    @Test func theWashFollowsThePointerFromSeatToSeat() async throws {
        let wash = RailWash()
        let find = RailWash.Seat(id: "find", tool: .find, radius: 8)
        let preview = RailWash.Seat(id: "preview", tool: .preview, radius: 8)

        wash.point(at: find, true)
        #expect(wash.seat == find)

        // Leaving one seat and landing on the next hands the wash over without a gap.
        wash.point(at: find, false)
        wash.point(at: preview, true)
        try await Task.sleep(for: .seconds(Motion.railHandoff * 3))
        #expect(wash.seat == preview)

        // A late exit from a seat the wash has already left does not take it away.
        wash.point(at: find, false)
        try await Task.sleep(for: .seconds(Motion.railHandoff * 3))
        #expect(wash.seat == preview)
    }

    @Test func theWashLeavesWithThePointer() async throws {
        let wash = RailWash()
        let ask = RailWash.Seat(id: "ask", tool: .ask, radius: 8)
        wash.point(at: ask, true)
        wash.point(at: ask, false)
        #expect(wash.seat == ask, "the wash should wait a moment for the next seat")
        try await Task.sleep(for: .seconds(Motion.railHandoff * 3))
        #expect(wash.seat == nil)
    }
}
