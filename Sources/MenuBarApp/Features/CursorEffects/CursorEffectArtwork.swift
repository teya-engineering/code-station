import AppKit

// The ring and glass colours and facet geometry shared by the Ripple and Prism layers.
enum CursorEffectArtwork {
    static let ringStops: [CGFloat] = [0, 0.33, 0.64, 1]
    static let faceStops: [CGFloat] = [0, 0.52, 1]
    static let edgeStops: [CGFloat] = [0, 0.5, 1]

    static func ringColours(light: Bool) -> [CGColor] {
        let components: [(Double, Double, Double, Double)] = light
            ? [(32, 121, 126, 1), (26, 128, 148, 0.7), (70, 105, 132, 1), (77, 135, 110, 0.6)]
            : [(99, 178, 161, 0.7), (191, 233, 210, 1), (126, 193, 219, 0.8), (112, 152, 117, 0.4)]
        return components.map { NSColor(srgbRed: $0.0 / 255, green: $0.1 / 255, blue: $0.2 / 255, alpha: $0.3).cgColor }
    }

    static func faceColours(hue: Double, light: Bool) -> [CGColor] {
        [colour(hue, saturation: light ? 0.65 : 0.85, lightness: light ? 0.44 : 0.8, alpha: 0.2),
         colour(hue + 35, saturation: 0.85, lightness: light ? 0.47 : 0.76, alpha: 0.4),
         colour(hue - 25, saturation: 0.85, lightness: light ? 0.5 : 0.83, alpha: 0.08)]
    }

    static func edgeColours(hue: Double, light: Bool) -> [CGColor] {
        [colour(hue, saturation: 0.8, lightness: light ? 0.39 : 0.8, alpha: 0.18),
         colour(hue + 30, saturation: 0.9, lightness: light ? 0.48 : 0.89),
         colour(hue - 15, saturation: 0.9, lightness: light ? 0.44 : 0.7, alpha: 0.5)]
    }

    static func seamColour(hue: Double, light: Bool) -> CGColor {
        colour(hue + 15, saturation: 0.7, lightness: light ? 0.47 : 0.88, alpha: 0.2)
    }

    static func facetVertices(size: Double, stretch: Double = 1.3, center: CGPoint = .zero) -> [CGPoint] {
        [CGPoint(x: -0.85, y: 0.36), CGPoint(x: 0.72, y: -0.8), CGPoint(x: 0.3, y: 0.75)]
            .map { CGPoint(x: center.x + $0.x * size * stretch, y: center.y + $0.y * size) }
    }

    static func facetPath(vertices: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: vertices)
        path.closeSubpath()
        return path
    }

    static func seams(vertices: [CGPoint], center: CGPoint) -> CGPath {
        let path = CGMutablePath()
        for vertex in vertices {
            path.move(to: center)
            path.addLine(to: vertex)
        }
        return path
    }

    private static func colour(_ hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) -> CGColor {
        let hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let secondary = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let components: (Double, Double, Double) = switch hue {
        case ..<1: (chroma, secondary, 0)
        case ..<2: (secondary, chroma, 0)
        case ..<3: (0, chroma, secondary)
        case ..<4: (0, secondary, chroma)
        case ..<5: (secondary, 0, chroma)
        default: (chroma, 0, secondary)
        }
        let offset = lightness - chroma / 2
        return NSColor(srgbRed: components.0 + offset, green: components.1 + offset,
                       blue: components.2 + offset, alpha: alpha).cgColor
    }
}
