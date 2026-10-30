import AppKit

// The colour of light at a temperature, as a gain on each channel. White under neutral
// daylight stays white; under a 3400K lamp it keeps all its red, loses a quarter of its
// green and nearly half its blue. Multiplying a screen's channels by these is what f.lux
// does to the whole display, and it is what SunlightFilter does to the window.
struct SunlightTint: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let neutral = SunlightTint(red: 1, green: 1, blue: 1)

    // Gains for a temperature, relative to neutral daylight. The theme never goes cooler
    // than daylight, so anything above it is daylight.
    init(kelvin: Double) {
        let light = Self.blackbody(min(kelvin, Sunlight.dayKelvin))
        let day = Self.blackbody(Sunlight.dayKelvin)
        red = min(1, light.0 / day.0)
        green = min(1, light.1 / day.1)
        blue = min(1, light.2 / day.2)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var isNeutral: Bool { self == .neutral }

    // Tanner Helland's fit of the black-body curve, in sRGB on 0 to 1. Good to a few
    // percent between 1000K and 40000K, which is far more range than a day needs.
    private static func blackbody(_ kelvin: Double) -> (Double, Double, Double) {
        let temperature = min(400, max(10, kelvin / 100))
        let red: Double, green: Double, blue: Double
        if temperature <= 66 {
            red = 255
            green = 99.4708025861 * log(temperature) - 161.1195681661
            blue = temperature <= 19 ? 0 : 138.5177312231 * log(temperature - 10) - 305.0447927307
        } else {
            red = 329.698727446 * pow(temperature - 60, -0.1332047592)
            green = 288.1221695283 * pow(temperature - 60, -0.0755148492)
            blue = 255
        }
        func clamp(_ value: Double) -> Double { min(255, max(0, value)) / 255 }
        return (clamp(red), clamp(green), clamp(blue))
    }
}
