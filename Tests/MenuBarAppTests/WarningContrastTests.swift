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
            let surface = try swatch(ChatColor.warningBackground, in: appearance)
            let tint = try swatch(ChatColor.warningText, in: appearance)

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

    private func appearances() throws -> [NSAppearance] {
        [try #require(NSAppearance(named: .aqua)), try #require(NSAppearance(named: .darkAqua))]
    }

    // A dynamic colour only picks a side while an appearance is current, so it is flattened
    // to numbers in there rather than carried out and read afterwards.
    private func swatch(_ color: Color, in appearance: NSAppearance) throws -> Swatch {
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
}

private struct Swatch {
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
    // each rather than treating them alike.
    private var luminance: Double {
        func light(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * light(red) + 0.7152 * light(green) + 0.0722 * light(blue)
    }

    func contrast(against other: Swatch) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}

private extension Swatch {
    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: Double(red), green: Double(green), blue: Double(blue),
                  alpha: Double(alpha))
    }
}
