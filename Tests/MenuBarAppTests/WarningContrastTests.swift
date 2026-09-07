import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// A warning surface draws adaptive text on an adaptive tint. If either half stops following
// the appearance the two collapse into each other in one mode while still compiling and
// still looking right in the other, so the pairs are measured here instead.
struct WarningContrastTests {
    // What the permission card puts on its own tint, read as ink over surface.
    @Test func permissionCardIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let surface = try swatch(Theme.warningBackground, in: appearance)
            let tint = try swatch(Theme.warningText, in: appearance)

            let pairs: [(String, Swatch, Swatch)] = [
                ("title", tint, surface),
                ("body", try swatch(Color(nsColor: .labelColor), in: appearance), surface),
                ("allow", try swatch(Theme.card, in: appearance), tint),
                ("deny", try swatch(Color(nsColor: .labelColor), in: appearance),
                 tint.faded(to: 0.18).over(surface))
            ]

            for (part, ink, background) in pairs {
                #expect(ink.contrast(against: background) >= 4.5,
                        "\(part) on \(appearance.name.rawValue)")
            }
        }
    }

    @Test func questionCardIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let accent = try swatch(Theme.accent, in: appearance)
            let surface = accent.faded(to: 0.06)
                .over(try swatch(Theme.background, in: appearance))

            let pairs: [(String, Swatch, Swatch)] = [
                ("header", accent, surface),
                ("question", try swatch(Color(nsColor: .labelColor), in: appearance), surface),
                ("submit", try swatch(Theme.card, in: appearance), accent)
            ]

            for (part, ink, background) in pairs {
                #expect(ink.contrast(against: background) >= 4.5,
                        "\(part) on \(appearance.name.rawValue)")
            }
        }
    }

    // The card a tool call is drawn as: the state word on the tinted band of a running
    // call, and the terminal body underneath, which stays dark in both appearances.
    @Test func toolCallCardIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let card = try swatch(Theme.card, in: appearance)
            let runningBand = try swatch(Theme.dotOn, in: appearance).faded(to: 0.07).over(card)
            let terminal = try swatch(Theme.terminal, in: appearance)

            let pairs: [(String, Swatch, Swatch)] = [
                ("running state", try swatch(Theme.addition, in: appearance), runningBand),
                ("argument", try swatch(Color(nsColor: .labelColor), in: appearance),
                 try swatch(Theme.statusBand, in: appearance)),
                ("terminal text", try swatch(Theme.terminalText, in: appearance), terminal),
                ("terminal prompt", try swatch(Theme.terminalDim, in: appearance), terminal),
                ("terminal failure", try swatch(Theme.terminalFailure, in: appearance), terminal)
            ]

            for (part, ink, background) in pairs {
                #expect(ink.contrast(against: background) >= 4.5,
                        "\(part) on \(appearance.name.rawValue)")
            }
        }
    }
}
