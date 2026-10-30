import Foundation

// How much of the day's sun is up at a moment, and the colour of the light that goes
// with it. This is what Sunlight follows: the window is neutral daylight when the sun is
// at the top of that day's arc, and warms as it sinks, reaching the colour of a lamp
// once the last light has gone from the sky.
struct SunReading: Equatable, Sendable {
    // Degrees above the horizon.
    let altitude: Double
    // 1 at that day's solar noon, 0 from the end of civil twilight until it starts
    // again before dawn, and in between the share of the way the sun has climbed.
    let fraction: Double

    // The colour temperature of the light, in kelvin, given the colour the night reaches.
    func kelvin(night: Double = Sunlight.nightKelvin) -> Double {
        Sunlight.kelvin(for: fraction, night: night)
    }

    static let night = SunReading(altitude: Sunlight.floorAltitude, fraction: 0)
}

// Whether the warmth follows the sun through the day or is held at the chosen colour.
enum SunlightMode: String, CaseIterable, Identifiable {
    case followsSun
    case fixed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followsSun: "With the sun"
        case .fixed: "Always"
        }
    }
}

enum Sunlight {
    // The warm end as shipped, the colour f.lux settles on after sunset. The slider in
    // Settings moves it anywhere in `nightRange`.
    static let nightKelvin = 3400.0
    // From candlelight to a cool white, named the way f.lux names them.
    static let nightRange = 1900.0...5500.0
    // Neutral daylight, where the screen draws nothing over the palette.
    static let dayKelvin = 6500.0
    // Full warmth is reached at the end of civil twilight rather than at the horizon, so
    // the last of the warming happens over the half hour after the sun goes down.
    static let floorAltitude = SolarClock.civilTwilightAltitude

    static func reading(at moment: Date, from place: Coordinates,
                        calendar: Calendar = .current) -> SunReading {
        let altitude = SolarClock.altitude(at: moment, from: place)
        var noon = SolarClock.solarNoon(on: moment, from: place, calendar: calendar)
        // The nearest noon, so the hours after midnight read against the coming day's arc
        // rather than the one that has gone.
        if moment.timeIntervalSince(noon) > 43_200 { noon = noon.addingTimeInterval(86_400) }
        if noon.timeIntervalSince(moment) > 43_200 { noon = noon.addingTimeInterval(-86_400) }
        let ceiling = SolarClock.altitude(at: noon, from: place)
        // A day the sun never clears the horizon has no sun to measure against: the polar
        // night is twilight at best, and reads as night throughout.
        guard ceiling > SolarClock.horizonAltitude else {
            return SunReading(altitude: altitude, fraction: 0)
        }
        // Where the sun never gets as low as twilight, as in a polar summer, the bottom of
        // its arc is the warmest the day gets.
        let midnight = noon.addingTimeInterval(moment < noon ? -43_200 : 43_200)
        let floor = max(floorAltitude, SolarClock.altitude(at: midnight, from: place))
        guard ceiling > floor + 0.01 else { return SunReading(altitude: altitude, fraction: 0) }
        let fraction = min(1, max(0, (altitude - floor) / (ceiling - floor)))
        return SunReading(altitude: altitude, fraction: fraction)
    }

    // The two ends are mixed in mireds, the reciprocal of kelvin, which is the scale on
    // which equal steps look equal; mixed in kelvin the warm end would arrive in a rush.
    static func kelvin(for fraction: Double, night: Double = nightKelvin) -> Double {
        let clamped = min(1, max(0, fraction))
        let mired = (1_000_000 / night) * (1 - clamped) + (1_000_000 / dayKelvin) * clamped
        return 1_000_000 / mired
    }

    // What f.lux calls a temperature, for the slider's readout.
    static func name(for kelvin: Double) -> String {
        switch kelvin {
        case ..<2300: "Candle"
        case ..<3000: "Tungsten"
        case ..<3800: "Halogen"
        case ..<4800: "Fluorescent"
        default: "Daylight"
        }
    }
}
