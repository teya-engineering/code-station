import SwiftUI
import Testing
@testable import MenuBarApp

// A switch says which way it is set by where its knob sits. The two track colours are one
// hue apart and carry nothing on their own, so the knob is the part that has to move, and
// the only way to know it does is to draw the control and find the white in the pixels.
@MainActor
struct AppSwitchTests {
    // Anything this bright in a switch is the knob: the darkest thing it can sit on is
    // the grey of an off track, well under this.
    private static let white = 235

    @Test func theKnobSitsAtOppositeEndsOfTheTrack() throws {
        let off = try knob(isOn: false)
        let on = try knob(isOn: true)
        #expect(off.centre < off.width / 2, "an off switch holds its knob left of centre")
        #expect(on.centre > on.width / 2, "an on switch holds its knob right of centre")
        #expect(on.centre - off.centre >= 12,
                "the knob barely moved: \(off.centre) to \(on.centre)")
    }

    @Test func theKnobStaysInsideTheTrack() throws {
        for isOn in [false, true] {
            let knob = try knob(isOn: isOn)
            #expect(knob.first >= 1, "the knob ran off the leading end when isOn=\(isOn)")
            #expect(knob.last <= knob.width - 2,
                    "the knob ran off the trailing end when isOn=\(isOn)")
        }
    }

    // MARK: - Reading the knob back

    private struct Knob {
        let width: Double
        let first: Double
        let last: Double

        var centre: Double { (first + last) / 2 }
    }

    private func knob(isOn: Bool) throws -> Knob {
        let renderer = ImageRenderer(content: Toggle(isOn: .constant(isOn)) { EmptyView() }
            .toggleStyle(.appSwitch))
        // Points and pixels have to be the same thing for a column to name a place in the
        // control rather than a place on whatever display the tests happen to run on.
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the switch did not render")

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let columns = (0..<width).filter { x in
            (0..<height).contains { y in
                let offset = (y * width + x) * 4
                return bytes[offset ..< offset + 4].allSatisfy { Int($0) >= Self.white }
            }
        }
        #expect(!columns.isEmpty, "no knob was drawn when isOn=\(isOn)")
        return Knob(width: Double(width),
                    first: Double(columns.first ?? 0),
                    last: Double(columns.last ?? 0))
    }
}
