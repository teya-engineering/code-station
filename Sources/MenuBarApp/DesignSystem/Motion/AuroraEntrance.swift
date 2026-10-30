import AppKit
import QuartzCore

@MainActor
enum AuroraEntrance {
    static let streakCount = 54
    static let pointCount = 52

    static func make(intensity: Double, scale: CGFloat, progress: Double?,
                     colour: (Double) -> NSColor) -> CALayer {
        let root = CALayer()
        root.name = "cursor-entrance"
        let duration = CursorEffect.aurora.entranceDuration
        let release = Motion.popDuration * 2
        let spread = Motion.revealDuration
        let fadeDuration = duration - release - spread
        let standard = CursorEffectsSettings().intensity
        let extent = (0.55 + intensity * 0.82) / (0.55 + standard * 0.82)
        let burstScale = 0.85
        let brightness = (0.4 + intensity * 0.8) / (0.4 + standard * 0.8)
        let light = colour(0).brightnessComponent < 0.9
        let times = progress.map { [$0 * duration] } ?? (0...60).map { Double($0) / 60 * duration }
        let center = CGPoint(x: 7, y: 10)

        func tint(_ fraction: Double, alpha: Double = 1) -> CGColor {
            let hue = colour(clamp(fraction)).hueComponent
            let saturation = light ? 0.56 : 0.78
            let luminance = light ? 0.43 : 0.72
            let chroma = (1 - abs(2 * luminance - 1)) * saturation
            let x = chroma * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
            let m = luminance - chroma / 2
            let rgb: (Double, Double, Double) = switch Int(hue * 6) {
            case 0: (chroma, x, 0)
            case 1: (x, chroma, 0)
            case 2: (0, chroma, x)
            case 3: (0, x, chroma)
            case 4: (x, 0, chroma)
            default: (chroma, 0, x)
            }
            return NSColor(srgbRed: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m,
                           alpha: clamp(alpha)).cgColor
        }
        func animate(_ layer: CALayer, _ key: String, values: [Any]) {
            guard progress == nil else { return }
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.duration = duration
            animation.beginTime = .leastNonzeroMagnitude
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "entrance-\(key)")
        }
        func opacity(_ layer: CALayer, _ values: [Double]) {
            let values = values.map { clamp($0 * brightness) }
            layer.opacity = Float(values.last!)
            animate(layer, "opacity", values: values)
        }
        func position(_ angle: Double, _ radius: Double, flat: Double = 1) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius * extent,
                    y: center.y + sin(angle) * radius * flat * extent)
        }
        func burst(_ time: Double) -> (travel: Double, drift: Double, fade: Double, ignition: Double, flash: Double) {
            let t = time - release
            let ignition = smooth(t / (Motion.controlDuration / 10))
            let fadeDelay = Motion.leaveDuration * 2 / 3
            let fade = t < 0 ? 0 : 1 - smooth((t - fadeDelay) / (duration - release - fadeDelay))
            let flashPeak = spread * (38.0 / 180)
            let flashWidth = spread * (92.0 / 180)
            return (ease(t / spread), ease((t - spread) / fadeDuration), fade, ignition,
                    exp(-pow((t - flashPeak) / flashWidth, 2)) * ignition)
        }
        func additive(_ layer: CALayer) {
            if !light { layer.compositingFilter = CIFilter(name: "CIAdditionCompositing") }
        }
        func glow(_ name: String, colours: [CGColor], stops: [NSNumber], additiveBlend: Bool = false,
                  frame: (Double) -> (radius: Double, opacity: Double)) {
            let frames = times.map(frame)
            let layer = CAGradientLayer()
            layer.name = name
            layer.contentsScale = scale
            layer.type = .radial
            layer.colors = colours
            layer.locations = stops
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
            layer.position = center
            let bounds = frames.map { CGRect(x: 0, y: 0, width: $0.radius * extent * 2, height: $0.radius * extent * 2) }
            layer.bounds = bounds.last!
            animate(layer, "bounds", values: bounds.map { NSValue(rect: $0) })
            opacity(layer, frames.map(\.opacity))
            if additiveBlend { additive(layer) }
            root.addSublayer(layer)
        }
        func stroke(_ name: String, colours: [CGColor], stops: [NSNumber], bands: [(Double, Double)],
                    additiveBlend: Bool = false, frame: (Double) -> (points: [CGPoint], opacity: Double)) {
            let frames = times.map(frame)
            let paths = frames.map { frame in
                let path = CGMutablePath()
                path.addLines(between: frame.points)
                return path
            }
            let padding = bands.map(\.0).max()! * extent
            let bounds = paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
                .insetBy(dx: -padding, dy: -padding)
            let gradient = CAGradientLayer()
            gradient.name = name
            gradient.frame = bounds
            gradient.contentsScale = scale
            gradient.colors = colours
            gradient.locations = stops
            func coordinate(_ point: CGPoint) -> NSValue {
                NSValue(point: CGPoint(x: (point.x - bounds.minX) / bounds.width,
                                       y: (point.y - bounds.minY) / bounds.height))
            }
            let starts = frames.map { coordinate($0.points.first!) }
            let ends = frames.map { coordinate(CGPoint(x: $0.points.last!.x + 0.01, y: $0.points.last!.y)) }
            gradient.startPoint = starts.last!.pointValue
            gradient.endPoint = ends.last!.pointValue
            animate(gradient, "startPoint", values: starts)
            animate(gradient, "endPoint", values: ends)
            var translation = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            let localPaths = paths.map { $0.copy(using: &translation)! }
            var mask: CAShapeLayer?
            let energy = additiveBlend && !light ? bands.reduce(0) { $0 + $1.1 } : 1
            var accumulated = 0.0
            for (width, alpha) in bands {
                let band = CAShapeLayer()
                band.contentsScale = scale
                band.frame = gradient.bounds
                band.path = localPaths.last!
                band.fillColor = nil
                // One gradient carries all three widths; the mask keeps their combined light.
                let coverage = energy == 1 ? alpha : (alpha / energy) / (1 - accumulated)
                band.strokeColor = NSColor.white.withAlphaComponent(clamp(coverage)).cgColor
                accumulated += alpha / energy
                band.lineCap = .round
                band.lineJoin = .round
                band.lineWidth = width * extent
                animate(band, "path", values: localPaths)
                if let mask { mask.addSublayer(band) } else { mask = band }
            }
            gradient.mask = mask
            opacity(gradient, frames.map { $0.opacity * energy })
            if additiveBlend { additive(gradient) }
            root.addSublayer(gradient)
        }
        func streakColours(_ fraction: Double) -> [CGColor] {
            [tint(fraction, alpha: 0), tint(fraction * 0.6, alpha: 0.6),
             tint(fraction), tint(min(1, fraction + 0.12), alpha: 0.08)]
        }

        glow("entrance-charge-glow", colours: [tint(0.75), tint(0.5, alpha: 0.32), tint(0.3, alpha: 0)],
             stops: [0, 0.3, 1]) { time in
            (37, smooth(time / release / 0.45) * (1 - smooth((time - release) / Motion.leaveDuration)) * 0.34)
        }
        let coreColours = [NSColor(srgbRed: light ? 238.0 / 255 : 240.0 / 255, green: 1,
                                   blue: light ? 249.0 / 255 : 252.0 / 255, alpha: light ? 0.82 : 0.9).cgColor,
                           tint(0.2, alpha: 0.7), tint(0.5, alpha: 0.32), tint(0.9, alpha: 0.1), tint(0.9, alpha: 0)]
        for index in 0..<12 {
            let angle = Double(index) * .pi * 2 / 12 + noise(index) * 0.24
            stroke("entrance-charge-wisp", colours: streakColours(noise(index + 9)),
                   stops: [0, 0.22, 0.68, 1], bands: [(0.7, 1)]) { time in
                let charge = clamp(time / release)
                let reach = 34 + (1 - ease(charge)) * (35 + noise(index + 4) * 25)
                let points = (0...17).map { step in
                    let t = Double(step) / 17
                    return position(angle + sin(t * .pi) * 0.18, reach + (11 - reach) * t)
                }
                return (points, smooth(charge / 0.45) * (1 - smooth((time - release) / Motion.leaveDuration)) * 0.44)
            }
        }
        glow("entrance-charge-core", colours: coreColours, stops: [0, 0.12, 0.36, 0.7, 1]) { time in
            (25, time < release + Motion.leaveDuration ? smooth((time / release - 0.65) / 0.35) * 0.5 : 0)
        }
        glow("entrance-burst-core", colours: coreColours, stops: [0, 0.12, 0.36, 0.7, 1], additiveBlend: true) { time in
            let frame = burst(time)
            return ((58 + frame.travel * 62) * burstScale, frame.flash * 0.95 + frame.fade * 0.12)
        }
        for index in 0..<streakCount {
            let angle = Double(index) * 2.399963 + noise(index + 30) * 0.13
            let fraction = 0.06 + 0.92 * (sin(angle) + 1) / 2
            stroke("entrance-burst-streak", colours: streakColours(fraction), stops: [0, 0.22, 0.68, 1],
                   bands: [(7.5, 0.07), (2.3, 0.42), (0.6 + noise(index + 5) * 0.7, 1)], additiveBlend: true) { time in
                let frame = burst(time)
                let reach = (65 + noise(index + 4) * 75) * frame.travel + frame.drift * 20
                let tail = reach * (0.13 + noise(index + 14) * 0.44) + frame.drift * 30
                let bend = (noise(index + 64) - 0.5) * 0.17
                let points = (0...14).map { step in
                    let t = Double(step) / 14
                    return position(angle + bend * t, (tail + (reach - tail) * t) * burstScale, flat: 0.86)
                }
                return (points, frame.fade * frame.ignition * (0.35 + noise(index + 74) * 0.65))
            }
        }
        for index in 0..<pointCount {
            let point = CAShapeLayer()
            point.name = "entrance-burst-point"
            point.contentsScale = scale
            let size = (0.35 + noise(index + 11) * 0.95) * extent
            point.path = CGPath(ellipseIn: CGRect(x: -size, y: -size, width: size * 2, height: size * 2), transform: nil)
            point.fillColor = tint(noise(index + 9))
            let frames = times.map(burst)
            let positions = frames.map { frame in
                NSValue(point: position(Double(index) * 2.399963 + 0.64,
                    ((50 + noise(index + 8) * 105) * frame.travel + frame.drift * 25) * burstScale, flat: 0.84))
            }
            point.position = positions.last!.pointValue
            animate(point, "position", values: positions)
            opacity(point, frames.map { $0.fade * $0.ignition * (0.25 + noise(index + 20) * 0.75) })
            additive(point)
            root.addSublayer(point)
        }
        let wave = CAShapeLayer()
        wave.name = "entrance-burst-wave"
        wave.contentsScale = scale
        wave.strokeColor = tint(0.25)
        wave.fillColor = nil
        wave.lineWidth = 0.7 * extent
        var tilt = CGAffineTransform(rotationAngle: -0.15).concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        let paths = times.map { time in
            let travel = burst(time).travel
            let rx = (16 + travel * 104) * extent * burstScale
            let ry = (12 + travel * 77) * extent * burstScale
            return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &tilt)
        }
        wave.path = paths.last!
        animate(wave, "path", values: paths)
        opacity(wave, times.map { burst($0).ignition * (1 - smooth(($0 - release) / spread)) * 0.25 })
        additive(wave)
        root.addSublayer(wave)
        stroke("entrance-burst-flare", colours: [tint(0.2, alpha: 0), tint(0.2, alpha: 0.25),
               NSColor(srgbRed: 250.0 / 255, green: 1, blue: 1, alpha: light ? 0.8 : 1).cgColor,
               tint(0.8, alpha: 0.25), tint(0.8, alpha: 0)], stops: [0, 0.4, 0.5, 0.6, 1], bands: [(0.9, 1)],
               additiveBlend: true) { time in
            let frame = burst(time)
            let reach = 119 * frame.travel * extent * burstScale
            return ([CGPoint(x: center.x - reach, y: center.y),
                     CGPoint(x: center.x + reach, y: center.y)],
                    time < release + spread ? frame.flash : 0)
        }
        return root
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
