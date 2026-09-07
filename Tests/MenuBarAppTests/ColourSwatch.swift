import AppKit
import SwiftUI
import Testing

// A colour flattened to numbers. Adaptive colours only pick a side while an appearance is
// current, so anything measuring them has to read them in there rather than carry the
// dynamic colour out and look at it afterwards.
struct Swatch {
    let red: Double
    let green: Double
    let blue: Double
    var alpha: Double = 1

    func faded(to alpha: Double) -> Swatch {
        Swatch(red: red, green: green, blue: blue, alpha: self.alpha * alpha)
    }

    func over(_ backdrop: Swatch) -> Swatch {
        func mix(_ top: Double, _ bottom: Double) -> Double {
            top * alpha + bottom * (1 - alpha)
        }
        return Swatch(red: mix(red, backdrop.red),
                      green: mix(green, backdrop.green),
                      blue: mix(blue, backdrop.blue))
    }

    // WCAG relative luminance, which weights the channels by how much the eye takes from
    // each rather than treating them alike. This is also what a colour is worth once the
    // hue is taken away, so it stands in for reading the screen in greyscale.
    var luminance: Double {
        func light(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * light(red) + 0.7152 * light(green) + 0.0722 * light(blue)
    }

    func contrast(against other: Swatch) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}

extension Swatch {
    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: Double(red), green: Double(green), blue: Double(blue),
                  alpha: Double(alpha))
    }
}

// Both appearances, so a pair that only works in one of them cannot pass.
func appearances() throws -> [NSAppearance] {
    [try #require(NSAppearance(named: .aqua)), try #require(NSAppearance(named: .darkAqua))]
}

func swatch(_ color: Color, in appearance: NSAppearance) throws -> Swatch {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(color).usingColorSpace(.sRGB)
    }
    let colour = try #require(resolved)
    return Swatch(red: colour.redComponent,
                  green: colour.greenComponent,
                  blue: colour.blueComponent,
                  alpha: colour.alphaComponent)
}
