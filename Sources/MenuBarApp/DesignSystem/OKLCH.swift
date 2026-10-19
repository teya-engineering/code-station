import AppKit
import Foundation
import CodeStationCore

// A colour as lightness, chroma (how colourful) and hue, in the OKLab space by Björn
// Ottosson. Equal steps here look like equal steps to the eye, which sRGB does not: a
// fixed lightness gives yellow and indigo the same strength.
struct OKLCH: Equatable {
    var lightness: Double
    var chroma: Double
    // In degrees, 0 to 360.
    var hue: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    init(red: Double, green: Double, blue: Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let okA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let okB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        chroma = hypot(okA, okB)
        hue = (atan2(okB, okA) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    init?(_ colour: NSColor) {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return nil }
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    // Not every lightness, chroma and hue fits in sRGB. Chroma gives way first, so the
    // hue and lightness asked for are the ones that show.
    func nsColor(alpha: CGFloat = 1) -> NSColor {
        var fitted = self
        var rgb = fitted.linearRGB
        for _ in 0..<40 where !rgb.allSatisfy({ (-0.0005...1.0005).contains($0) }) {
            fitted.chroma *= 0.93
            rgb = fitted.linearRGB
        }
        let channel = rgb.map { Self.gamma(min(1, max(0, $0))) }
        return NSColor(srgbRed: channel[0], green: channel[1], blue: channel[2], alpha: alpha)
    }

    private var linearRGB: [Double] {
        let radians = hue * .pi / 180
        let okA = chroma * cos(radians), okB = chroma * sin(radians)
        let l = pow(lightness + 0.3963377774 * okA + 0.2158037573 * okB, 3)
        let m = pow(lightness - 0.1055613458 * okA - 0.0638541728 * okB, 3)
        let s = pow(lightness - 0.0894841775 * okA - 1.2914855480 * okB, 3)
        return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
