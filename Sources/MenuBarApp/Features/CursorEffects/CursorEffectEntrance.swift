import AppKit
import QuartzCore

// Geometry is sampled once for Core Animation and evaluated directly for inspection.
@MainActor
enum CursorEffectEntrance {
    static func make(effect: CursorEffect, intensity: Double, scale: CGFloat,
                     progress inspectionProgress: Double? = nil,
                     colour: (Double) -> NSColor,
                     satellite: (Int, Double) -> CGPoint) -> CALayer {
        let root = CALayer()
        root.name = "cursor-entrance"
        let duration = effect.entranceDuration
        guard duration > 0 else { return root }
        let extent = 0.55 + intensity * 0.82
        let brightness = 0.4 + intensity * 0.8
        let progress = (0...60).map { Double($0) / 60 }

        func animate(_ layer: CALayer, _ key: String, values: [Any]) {
            guard inspectionProgress == nil else { return }
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.duration = duration
            animation.beginTime = .leastNonzeroMagnitude
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "entrance-\(key)")
        }

        func mark(_ name: String, tint: NSColor, width: CGFloat = 0.8, filled: Bool = false, fillOpacity: CGFloat = 0.2,
                  frame: (Double) -> (CGPath, Double)) {
            let layer = CAShapeLayer()
            layer.name = name
            layer.contentsScale = scale
            layer.strokeColor = tint.cgColor
            layer.fillColor = filled ? tint.withAlphaComponent(fillOpacity).cgColor : nil
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
            let selected = frame(inspectionProgress ?? 1)
            layer.path = selected.0
            layer.opacity = Float(max(0, min(1, selected.1 * brightness)))
            if inspectionProgress == nil {
                let frames = progress.map(frame)
                animate(layer, "path", values: frames.map { $0.0 })
                animate(layer, "opacity", values: frames.map { max(0, min(1, $0.1 * brightness)) })
            }
            root.addSublayer(layer)
        }

        func glow(radius: Double, tint: NSColor, opacity: @escaping (Double) -> Double) {
            let layer = CAGradientLayer()
            layer.name = "entrance-glow"
            layer.type = .radial
            layer.colors = [tint.cgColor, tint.withAlphaComponent(0.45).cgColor, tint.withAlphaComponent(0).cgColor]
            layer.locations = [0, 0.25, 1]
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
            let r = radius * extent
            layer.frame = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
            layer.opacity = Float(inspectionProgress.map { opacity($0) * brightness } ?? 0)
            animate(layer, "opacity", values: progress.map { opacity($0) * brightness })
            root.addSublayer(layer)
        }

        switch effect {
        case .none: break
        case .ember:
            glow(radius: 46, tint: colour(0.6)) { sin(.pi * $0) * 0.38 }
            for index in 0..<Int(14 + intensity * 36) {
                let angle = Double(index) * 2.39996
                mark("entrance-fleck", tint: colour(0.8), width: 0.7 + noise(index) * 0.8) { p in
                    let gather = 1 - ease(p / 0.42)
                    let release = ease((p - 0.31) / 0.69)
                    let radius = ((18 + noise(index) * 60) * gather
                        + (10 + noise(index + 20) * 62) * release) * extent
                    let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius * 0.75 - release * 14 * extent)
                    let path = CGMutablePath()
                    path.move(to: point)
                    path.addLine(to: CGPoint(x: point.x - cos(angle) * 3, y: point.y + 2 + release * 3))
                    let alpha = p < 0.36 ? smooth(p / 0.16) : 1 - smooth((p - 0.66) / 0.34)
                    return (path, alpha * (0.25 + noise(index + 100) * 0.7))
                }
            }
            mark("entrance-core", tint: colour(1), filled: true, fillOpacity: 1) { p in
                (ellipse(radius: (1.3 + sin(.pi * p) * 2) * extent),
                 smooth(p / 0.16) * (1 - smooth((p - 0.66) / 0.34)))
            }
        case .aurora:
            return AuroraEntrance.make(intensity: intensity, scale: scale,
                                       progress: inspectionProgress, colour: colour)
        case .orbit:
            for index in 0..<4 {
                let dot = CAShapeLayer()
                dot.name = "entrance-satellite"
                dot.contentsScale = scale
                dot.path = ellipse(radius: index == 0 ? 2.3 : 1.5)
                dot.fillColor = colour(Double(index % 2)).cgColor
                dot.shadowColor = dot.fillColor
                dot.shadowOpacity = Float(0.4 * brightness)
                dot.shadowRadius = 4 * extent
                dot.shadowOffset = .zero
                func position(_ p: Double) -> NSValue {
                    let join = ease((p - Double(index) * 0.08) / 0.62)
                    let target = satellite(index, p * duration)
                    let reach = 1 + (1 - join) * (1.5 + noise(index)) * extent
                    return NSValue(point: CGPoint(x: 8 + (target.x - 8) * reach,
                                                  y: 10 + (target.y - 10) * reach))
                }
                let points = progress.map(position)
                dot.position = inspectionProgress.map { position($0).pointValue } ?? points.last!.pointValue
                dot.opacity = Float(inspectionProgress.map {
                    min(1, smooth($0 / 0.18) * brightness) * (1 - smooth(($0 - 0.86) / 0.14))
                } ?? 0)
                animate(dot, "position", values: points)
                animate(dot, "opacity", values: progress.map {
                    min(1, smooth($0 / 0.18) * brightness) * (1 - smooth(($0 - 0.86) / 0.14))
                })
                root.addSublayer(dot)
            }
        case .ripple:
            glow(radius: 26, tint: colour(0.5)) { sin(.pi * $0) * 0.18 }
            mark("entrance-drop", tint: colour(0.5), filled: true, fillOpacity: 1) { p in
                (ellipse(radius: max(0.1, 3 * (1 - p / 0.3) + 0.7) * extent),
                 smooth(p / 0.12) * (1 - smooth((p - 0.2) / 0.1)))
            }
            mark("entrance-wave", tint: colour(0.5), width: 0.85) { p in
                let wave = clamp((p - 0.25) / 0.75)
                return (ellipse(radius: (8 + ease(wave) * 77) * extent, flat: 0.85), sin(.pi * wave) * 0.7)
            }
        case .prism:
            glow(radius: 38, tint: colour(0.5)) { sin(.pi * $0) * 0.12 }
            for index in 0..<6 {
                mark("entrance-facet", tint: colour(Double(index % 3) / 2), filled: true) { p in
                    let open = sin(p * .pi)
                    let settle = ease((p - 0.55) / 0.45)
                    let angle = Double(index) * .pi / 3 + p * 0.9
                    let radius = (15 + open * 29) * extent
                    let point = CGPoint(x: cos(angle) * radius * (1 - settle * 0.65) - settle * 15 * extent,
                                        y: sin(angle) * radius * (1 - settle * 0.65) + settle * 9 * extent)
                    let size = (10 + open * 9) * extent
                    let path = CGMutablePath()
                    path.addLines(between: [CGPoint(x: size, y: -size * 0.35),
                                           CGPoint(x: -size * 0.75, y: -size * 0.55),
                                           CGPoint(x: -size * 0.35, y: size * 0.7)])
                    path.closeSubpath()
                    var transform = CGAffineTransform(rotationAngle: angle + .pi / 2 + p * 0.6)
                        .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
                    return (path.copy(using: &transform)!, open * 0.68)
                }
            }
        }
        return root
    }

    private static func ellipse(radius: Double, flat: Double = 1) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -radius, y: -radius * flat, width: radius * 2, height: radius * 2 * flat), transform: nil)
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func ease(_ value: Double) -> Double { 1 - pow(1 - clamp(value), 3) }
    private static func smooth(_ value: Double) -> Double {
        let p = clamp(value)
        return p * p * (3 - 2 * p)
    }
    private static func noise(_ index: Int) -> Double {
        let value = sin(Double(index) * 127.1 + 311.7) * 43758.5453
        return value - floor(value)
    }
}
