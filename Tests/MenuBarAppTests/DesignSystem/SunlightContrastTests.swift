import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The Sunlight theme multiplies every pixel by the light's colour, which takes more from
// a pale surface than a dark ink. The pairs the other contrast tests guard are measured
// again here under the warmest light the theme reaches, in both appearances.
struct SunlightContrastTests {
    private let lamp = SunlightTint(kelvin: Sunlight.nightKelvin)

    @Test func neutralDaylightLeavesColoursAlone() {
        #expect(SunlightTint(kelvin: Sunlight.dayKelvin) == .neutral)
        #expect(SunlightTint(kelvin: 7000).isNeutral)
    }

    // The lamp keeps red, loses a quarter of green and nearly half of blue.
    @Test func theLampIsAmber() {
        #expect(lamp.red == 1)
        #expect(abs(lamp.green - 0.75) < 0.03)
        #expect(abs(lamp.blue - 0.54) < 0.03)
        let white = lamp.apply(to: .white).usingColorSpace(.sRGB)!
        #expect(white.redComponent == 1)
        #expect(white.greenComponent < white.redComponent)
        #expect(white.blueComponent < white.greenComponent)
    }

    @Test func textStaysReadableUnderTheLamp() throws {
        for appearance in try appearances() {
            let card = try lit(Theme.card, in: appearance)
            let canvas = try lit(Theme.background, in: appearance)
            let label = try lit(Color(nsColor: .labelColor), in: appearance)
            let pairs: [(String, Swatch, Swatch)] = [
                ("body on card", label, card),
                ("body on canvas", label, canvas),
                ("secondary on card", try lit(Theme.secondaryText, in: appearance), card),
                ("accent on card", try lit(Theme.accent, in: appearance), card),
                ("warning", try lit(Theme.warningText, in: appearance),
                 try lit(Theme.warningBackground, in: appearance)),
                ("snooze", try lit(Theme.snoozeText, in: appearance),
                 try lit(Theme.snoozeSurface, in: appearance)),
                ("terminal text", try lit(Theme.terminalText, in: appearance),
                 try lit(Theme.terminal, in: appearance))
            ]
            for (part, ink, background) in pairs {
                #expect(ink.contrast(against: background) >= 4.5,
                        "\(part) on \(appearance.name.rawValue)")
            }
        }
    }

    // A pale surface loses more under the lamp than a dark ink does, so a pair that is
    // just past 4.5 by day lands under it by night. The meaning colours, and amber words
    // on their own amber tint, which measure 3.8 at the warmest hour in light mode, are
    // held to the mark for large marks rather than body text.
    @Test func meaningColoursStillShowUnderTheLamp() throws {
        for appearance in try appearances() {
            let card = try lit(Theme.card, in: appearance)
            for (part, colour) in [("plan", Theme.plan), ("addition", Theme.addition),
                                   ("deletion", Theme.deletion), ("showcase", Theme.showcase)] {
                #expect(try lit(colour, in: appearance).contrast(against: card) >= 3,
                        "\(part) on \(appearance.name.rawValue)")
            }
            let attentionTint = try lit(Theme.attention, in: appearance).faded(to: 0.18).over(card)
            #expect(try lit(Theme.attentionText, in: appearance).contrast(against: attentionTint) >= 3,
                    "attention words on \(appearance.name.rawValue)")
        }
    }

    private func lit(_ colour: Color, in appearance: NSAppearance) throws -> Swatch {
        let plain = try swatch(colour, in: appearance)
        return Swatch(red: plain.red * lamp.red, green: plain.green * lamp.green,
                      blue: plain.blue * lamp.blue, alpha: plain.alpha)
    }
}

struct SunlightSettingsTests {
    @Test func theSwitchAndWarmthAreSavedAndReadBack() {
        let store = UserDefaults(suiteName: "SunlightSettingsTests")!
        store.removePersistentDomain(forName: "SunlightSettingsTests")
        #expect(!Preferences.sunlightEnabled(in: store))
        #expect(Preferences.sunlightNightKelvin(in: store) == Sunlight.nightKelvin)
        #expect(Preferences.sunlightMode(in: store) == .followsSun)
        Preferences.setSunlightEnabled(true, in: store)
        Preferences.setSunlightMode(.fixed, in: store)
        Preferences.setSunlightNightKelvin(2700, in: store)
        #expect(Preferences.sunlightEnabled(in: store))
        #expect(Preferences.sunlightMode(in: store) == .fixed)
        #expect(Preferences.sunlightNightKelvin(in: store) == 2700)
    }

    // A value written by hand is pulled back into the slider's range.
    @Test func warmthOutsideTheRangeIsClamped() {
        let store = UserDefaults(suiteName: "SunlightSettingsTests.clamp")!
        store.removePersistentDomain(forName: "SunlightSettingsTests.clamp")
        Preferences.setSunlightNightKelvin(500, in: store)
        #expect(Preferences.sunlightNightKelvin(in: store) == Sunlight.nightRange.lowerBound)
        Preferences.setSunlightNightKelvin(9000, in: store)
        #expect(Preferences.sunlightNightKelvin(in: store) == Sunlight.nightRange.upperBound)
    }

    // The slider moves the warm end; the day end stays daylight whatever it is set to.
    @Test func theNightColourMovesTheWarmEndOnly() {
        #expect(Sunlight.kelvin(for: 0, night: 2700) == 2700)
        #expect(Sunlight.kelvin(for: 1, night: 2700) == Sunlight.dayKelvin)
        #expect(SunReading.night.kelvin(night: 5500) == 5500)
        #expect(Sunlight.kelvin(for: 0.5, night: 2700) < Sunlight.kelvin(for: 0.5, night: 4200))
    }

    @Test func temperaturesAreNamedTheWayFluxNamesThem() {
        #expect(Sunlight.name(for: 1900) == "Candle")
        #expect(Sunlight.name(for: 2700) == "Tungsten")
        #expect(Sunlight.name(for: 3400) == "Halogen")
        #expect(Sunlight.name(for: 4200) == "Fluorescent")
        #expect(Sunlight.name(for: 5500) == "Daylight")
    }
}
