import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The Sunlight theme multiplies every pixel by the light's colour, which takes more from
// a pale surface than a dark ink. The pairs the other contrast tests guard are measured
// again here under the night colour as shipped, in both appearances, and held to the
// same marks. A warmer night is the user's own choice and is allowed to cost some
// contrast, as it does in f.lux, but only down to a floor: candlelight takes all the
// blue and half the green, and the paler inks fall to about 3.4 there.
struct SunlightContrastTests {
    private static let lamps = [
        Lamp(kelvin: Sunlight.nightKelvin, text: 4.5, mark: 3),
        Lamp(kelvin: Sunlight.nightRange.lowerBound, text: 3, mark: 2)
    ]

    struct Lamp: CustomTestStringConvertible, Sendable {
        let kelvin: Double
        let text: Double
        let mark: Double
        var tint: SunlightTint { SunlightTint(kelvin: kelvin) }
        var testDescription: String { "\(Int(kelvin))K" }
    }

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
    }

    @Test(arguments: lamps)
    func textStaysReadableUnderTheLamp(_ light: Lamp) throws {
        let lamp = light.tint
        for appearance in try appearances() {
            let card = try lit(Theme.card, in: appearance, under: lamp)
            let canvas = try lit(Theme.background, in: appearance, under: lamp)
            let label = try lit(Color(nsColor: .labelColor), in: appearance, under: lamp)
            let pairs: [(String, Swatch, Swatch)] = [
                ("body on card", label, card),
                ("body on canvas", label, canvas),
                ("secondary on card", try lit(Theme.secondaryText, in: appearance, under: lamp), card),
                ("accent on card", try lit(Theme.accent, in: appearance, under: lamp), card),
                ("warning", try lit(Theme.warningText, in: appearance, under: lamp),
                 try lit(Theme.warningBackground, in: appearance, under: lamp)),
                ("snooze", try lit(Theme.snoozeText, in: appearance, under: lamp),
                 try lit(Theme.snoozeSurface, in: appearance, under: lamp)),
                ("terminal text", try lit(Theme.terminalText, in: appearance, under: lamp),
                 try lit(Theme.terminal, in: appearance, under: lamp))
            ]
            for (part, ink, background) in pairs {
                #expect(ink.contrast(against: background) >= light.text,
                        "\(part) on \(appearance.name.rawValue) at \(Int(light.kelvin))K")
            }
        }
    }

    // A pale surface loses more under the lamp than a dark ink does, so a pair that is
    // just past 4.5 by day lands under it by night. The meaning colours, and amber words
    // on their own amber tint, which measure 3.8 at the warmest hour in light mode, are
    // held to the mark for large marks rather than body text.
    @Test(arguments: lamps)
    func meaningColoursStillShowUnderTheLamp(_ light: Lamp) throws {
        let lamp = light.tint
        for appearance in try appearances() {
            let card = try lit(Theme.card, in: appearance, under: lamp)
            for (part, colour) in [("plan", Theme.plan), ("addition", Theme.addition),
                                   ("deletion", Theme.deletion), ("showcase", Theme.showcase)] {
                #expect(try lit(colour, in: appearance, under: lamp).contrast(against: card) >= light.mark,
                        "\(part) on \(appearance.name.rawValue) at \(Int(light.kelvin))K")
            }
            let attentionTint = try lit(Theme.attention, in: appearance, under: lamp).faded(to: 0.18).over(card)
            #expect(try lit(Theme.attentionText, in: appearance, under: lamp).contrast(against: attentionTint) >= light.mark,
                    "attention words on \(appearance.name.rawValue) at \(Int(light.kelvin))K")
        }
    }

    private func lit(_ colour: Color, in appearance: NSAppearance, under lamp: SunlightTint) throws -> Swatch {
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
