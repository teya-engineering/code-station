import AppKit
import SwiftUI
import Testing
@testable import CodeStationCore
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

    // The shield on the composer bar says how far the agent is trusted by its colour, and
    // each level's words sit on a tint of that same colour. Every level has to read in
    // both appearances, the new blue for plan only among them.
    @Test func everyTrustLevelIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let card = try swatch(Theme.card, in: appearance)
            let field = try swatch(Theme.field, in: appearance).over(card)

            let pairs: [(String, Swatch, Swatch)] = [
                ("every step", try swatch(Theme.addition, in: appearance),
                 try swatch(Theme.addition, in: appearance).faded(to: 0.14).over(card)),
                ("risky only", try swatch(Color(nsColor: .labelColor), in: appearance), field),
                ("allow edits", try swatch(Theme.attentionText, in: appearance),
                 try swatch(Theme.attention, in: appearance).faded(to: 0.18).over(card)),
                ("plan only", try swatch(Theme.plan, in: appearance),
                 try swatch(Theme.plan, in: appearance).faded(to: 0.14).over(card)),
                ("full access", try swatch(Theme.warningText, in: appearance),
                 try swatch(Theme.deletion, in: appearance).faded(to: 0.14).over(card))
            ]

            for (part, ink, background) in pairs {
                #expect(ink.contrast(against: background) >= 4.5,
                        "\(part) on \(appearance.name.rawValue)")
            }
        }
    }

    // Each Design ambition level has its own colour: the brush in the menu sits on the
    // menu card, and the pill's words sit on the level's own tint.
    @Test func everyDesignAmbitionIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let card = try swatch(Theme.card, in: appearance)
            for ambition in DesignAmbition.allCases {
                let icon = try swatch(ambition.tint, in: appearance).over(card)
                let fill = try swatch(ambition.pillFill, in: appearance).over(card)
                let words = try swatch(ambition.pillInk, in: appearance).over(fill)

                #expect(icon.contrast(against: card) >= 3,
                        "\(ambition.title) icon on \(appearance.name.rawValue)")
                #expect(words.contrast(against: fill) >= 4.5,
                        "\(ambition.title) pill on \(appearance.name.rawValue)")
            }
        }
    }

    // Dictation's lime: the mic pill's clock on the lime fill, the notice row's words on
    // the pale lime tint, and the dotted mark under an unsure word against the card.
    @Test func listeningIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let card = try swatch(Theme.card, in: appearance)
            let fill = try swatch(Theme.listenFill, in: appearance)
            let tint = try swatch(Theme.listenTint, in: appearance).over(card)

            #expect(try swatch(Theme.listenOnFill, in: appearance).contrast(against: fill) >= 4.5,
                    "mic pill on \(appearance.name.rawValue)")
            #expect(try swatch(Theme.listenInk, in: appearance).contrast(against: tint) >= 4.5,
                    "notice on \(appearance.name.rawValue)")
            #expect(try swatch(Theme.listenEdge, in: appearance).contrast(against: card) >= 3,
                    "unsure mark on \(appearance.name.rawValue)")
        }
    }

    // All out has to stand apart from the house green, or the level that changes the
    // most looks the same as the everyday one.
    @Test func allOutDoesNotShareBalancedColour() throws {
        for appearance in try appearances() {
            let balanced = try swatch(DesignAmbition.balanced.tint, in: appearance)
            let allOut = try swatch(DesignAmbition.allOut.tint, in: appearance)
            #expect(balanced.red != allOut.red || balanced.green != allOut.green
                        || balanced.blue != allOut.blue,
                    "on \(appearance.name.rawValue)")
        }
    }

    // The header pill carries the state as a 9.5pt word and a thin rail, both on the card
    // at rest and on the sunken fill once the card opens. The word has to read as text,
    // the rail as a mark.
    @Test func sessionStatePillIsReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let card = try swatch(Theme.card, in: appearance)
            let open = try swatch(Theme.sunken, in: appearance).over(card)
            for tone in [SessionTone.running, .waiting, .needsYou, .idle] {
                let ink = try swatch(tone.wordColour, in: appearance)
                for (surface, backdrop) in [("rest", card), ("open", open)] {
                    let colour = ink.over(backdrop)
                    #expect(colour.contrast(against: backdrop) >= 4.5,
                            "\(tone.word) word at \(surface) on \(appearance.name.rawValue)")
                    #expect(colour.contrast(against: backdrop) >= 3,
                            "\(tone.word) rail at \(surface) on \(appearance.name.rawValue)")
                }
            }
        }
    }
}
