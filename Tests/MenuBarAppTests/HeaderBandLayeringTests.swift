import SwiftUI
import Testing
@testable import MenuBarApp

// A band closes itself with a rule, and the session band draws the window reading along
// the same edge. That edge is also where the band's chips open their cards, so what is
// drawn over what is checked by rendering the band and reading the pixels back.
@MainActor
struct HeaderBandLayeringTests {
    private static let width: CGFloat = 200
    private static let height: CGFloat = 58
    // A card is wider than the chip it hangs from and drops past the bottom of the band.
    // The overlap is the strip the lines used to be drawn across.
    private static let cardWidth: CGFloat = 100
    private static let cardDrop: CGFloat = 30

    // Nothing in the palette is this colour, so a pixel either is the card or is something
    // drawn over it.
    private static let card = Color(.sRGB, red: 1, green: 0, blue: 1)

    // A band with a card hanging off its right half. The left half is left bare so the
    // same render says whether the lines are still drawn where nothing covers them.
    private var band: some View {
        Color.clear
            .frame(width: Self.width, height: Self.height)
            .overlay(alignment: .bottomTrailing) {
                Self.card
                    .frame(width: Self.cardWidth, height: 40)
                    .offset(y: Self.cardDrop)
            }
            .headerBand(Theme.card, height: Self.height) {
                ContextHairline(fraction: 0.95, animated: false)
            }
    }

    @Test func aCardHangingOffTheBandCoversTheLinesThatCloseIt() throws {
        let pixels = try render(band)
        let bottom = pixels.height - 1

        // Under the card, the card is what is on screen.
        #expect(isCard(pixels.colour(x: 150, y: bottom)),
                "the band drew over the card: \(pixels.colour(x: 150, y: bottom))")

        // Beside it the lines are still there, and still tell themselves apart from the
        // band's own fill.
        let beside = pixels.colour(x: 20, y: bottom)
        #expect(!isCard(beside))
        #expect(beside != pixels.colour(x: 20, y: 20),
                "no line was drawn along the bottom of the band")
    }

    // The fuse burns at the end of the reading, above the line rather than on it, so it
    // reaches further into a card than the line does and is worth its own check.
    @Test func theFuseStaysBehindTheCardToo() throws {
        let pixels = try render(band)
        // The reading runs to 95% of the width, which puts its tip inside the card's half.
        for y in (pixels.height - 10)...(pixels.height - 1) {
            let colour = pixels.colour(x: 185, y: y)
            #expect(isCard(colour), "the fuse drew over the card at y=\(y): \(colour)")
        }
    }

    // MARK: - Reading pixels back

    private func isCard(_ colour: Colour) -> Bool {
        colour.red > 200 && colour.green < 60 && colour.blue > 200
    }

    private struct Colour: Equatable {
        let red: Int
        let green: Int
        let blue: Int
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func colour(x: Int, y: Int) -> Colour {
            let offset = (y * width + x) * 4
            return Colour(red: Int(bytes[offset]),
                          green: Int(bytes[offset + 1]),
                          blue: Int(bytes[offset + 2]))
        }
    }

    private func render(_ view: some View) throws -> Bitmap {
        let renderer = ImageRenderer(content: view)
        // Points and pixels have to be the same thing for a sample to name a place in the
        // layout rather than a place on whatever display the tests happen to run on.
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the band did not render")

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
        return Bitmap(width: width, height: height, bytes: bytes)
    }
}
