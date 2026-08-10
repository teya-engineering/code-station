import SwiftUI

// Drawn rather than loaded from AppIcon.png. The file holds a single 800px representation,
// so at the sizes used on screen AppKit rescales it live and the mark comes out soft on a
// display without a 2x backing store. Proportions match the file, margin included, so the
// Dock icon that make-icon.swift still builds from it is the same mark.
struct AppMark: View {
    private static let tile = Color(red: 0.867, green: 0.878, blue: 0.282)
    private static let dot = Color(red: 0.647, green: 0.655, blue: 0.227)
    private static let accent = Color(red: 0.082, green: 0.082, blue: 0.082)

    // Fractions of the side, measured off the art.
    private static let margin = 0.0975
    private static let corner = 0.1625
    private static let centres = [0.3356, 0.4994, 0.6631]
    private static let dotRadius = 0.0475
    private static let accentRadius = 0.0725

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let tile = CGRect(x: side * Self.margin,
                              y: side * Self.margin,
                              width: side * (1 - Self.margin * 2),
                              height: side * (1 - Self.margin * 2))
            context.fill(Path(roundedRect: tile, cornerRadius: side * Self.corner),
                         with: .color(Self.tile))

            for (row, y) in Self.centres.enumerated() {
                for (column, x) in Self.centres.enumerated() {
                    let isAccent = row == 0 && column == 2
                    let radius = side * (isAccent ? Self.accentRadius : Self.dotRadius)
                    let circle = CGRect(x: side * x - radius,
                                        y: side * y - radius,
                                        width: radius * 2,
                                        height: radius * 2)
                    context.fill(Path(ellipseIn: circle),
                                 with: .color(isAccent ? Self.accent : Self.dot))
                }
            }
        }
    }
}
