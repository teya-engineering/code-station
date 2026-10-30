import AppKit
import QuartzCore
import SwiftUI

struct CursorEffectOverlay: NSViewRepresentable {
    let settings: CursorEffectsSettings
    let activity: CursorEffectActivity
    var turnStarted: Date? = nil
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CursorEffectLayerView {
        CursorEffectLayerView()
    }

    func updateNSView(_ view: CursorEffectLayerView, context: Context) {
        view.setEnabled(enabled)
        view.configure(settings: settings, activity: activity, reduceMotion: reduceMotion, turnStarted: turnStarted)
    }

    static func dismantleNSView(_ view: CursorEffectLayerView, coordinator: ()) {
        view.stop()
    }
}

// Pointer events only place layers. Core Animation owns their decay and every loop,
// so an idle pointer never asks SwiftUI to lay out the window again.
final class CursorEffectLayerView: LoopLayerView {
    static let particleLimit = 320
    private static let lifetime = Motion.popDuration * 3
    private static let orbitPeriod = Breath.period * 30

    private(set) var settings = CursorEffectsSettings()
    private(set) var activity = CursorEffectActivity.inactive
    private var reduced = false
    private var environmentReduced = false
    private var pointerInside = false
    private var point = CGPoint.zero
    private var previous: CGPoint?
    private var ribbonStart: CGPoint?
    private var lastEmission: CFTimeInterval = 0
    private var monitor: Any?
    private var tracking: NSTrackingArea?
    private var observing = false
    private var foreground = false
    private var foregroundSince: Date?
    private var lastSize = CGSize.zero
    private let ornament = CALayer()
    private var particles: [CAShapeLayer] = []
    private var nextParticle = 0
    var tracksPointerEvents = true
    private var sampleParticles: [CAShapeLayer]?
    var automaticallyPlaysEntrance = true
    private var enabled = true
    private var turnStarted: Date?
    private(set) var entrance: CALayer?
    private var entranceEnd: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        layer?.addSublayer(ornament)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }

    func configure(settings: CursorEffectsSettings, activity: CursorEffectActivity,
                   reduceMotion: Bool, turnStarted: Date? = nil) {
        let appearanceChanged = self.settings != settings || environmentReduced != reduceMotion
        let turnChanged = turnStarted != nil && self.turnStarted != turnStarted
        let changed = appearanceChanged || self.activity != activity || turnChanged
        let wasActive = self.activity == .running || self.activity == .waiting
        let active = activity == .running || activity == .waiting
        // A background start can reach SwiftUI after focus returns.
        let startedInForeground = turnStarted.map { $0 >= (foregroundSince ?? .distantFuture) } ?? foreground
        let activate = active && (self.settings.effect != settings.effect
            || ((!wasActive || turnChanged) && startedInForeground))
        let preserveTrails = !appearanceChanged && !turnChanged && wasActive && active
        let completed = wasActive && activity == .finished && self.settings.effect == settings.effect
        let presentedPoint = ornament.presentation()?.position ?? point
        if self.settings.effect != settings.effect {
            layerUsesCoreImageFilters = settings.effect == .aurora
            particles.forEach { $0.removeFromSuperlayer() }
            particles.removeAll()
            nextParticle = 0
        }
        self.settings = settings
        self.activity = activity
        self.turnStarted = turnStarted
        environmentReduced = reduceMotion
        if changed {
            reduced = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            clear(preservingTrails: preserveTrails && !reduced)
            if activate && tracksPointerEvents, foreground, let window {
                let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                pointerInside = visibleRect.contains(location)
                if pointerInside { point = location }
            }
            rebuild()
            if activate && automaticallyPlaysEntrance { startEntrance() }
            if completed && foreground && !reduced && settings.effect != .none && pointerInside {
                ring(at: presentedPoint, finished: true)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { stop(); return }
        if !observing {
            observing = true
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSView.boundsDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        if tracksPointerEvents && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged,
                .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.receive(event) }
                return event
            }
        }
        synchronize()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stop() }
        super.viewWillMove(toWindow: newWindow)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observing = false
        foreground = false
        pointerInside = false
        clear()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        if tracksPointerEvents { receive(event) }
    }

    override func mouseExited(with event: NSEvent) {
        if tracksPointerEvents { leavePointer() }
    }

    func leavePointer() {
        pointerInside = false
        clear(preservingTrails: true)
    }

    override func layoutLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != lastSize {
            lastSize = bounds.size
            previous = nil
            clear()
        }
        if !pointerInside { point = CGPoint(x: bounds.width * 0.6, y: bounds.height * 0.55) }
        synchronize()
    }

    override func restartLoops() { synchronize() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        clear()
        rebuild()
    }

    @objc private func visibilityChanged() { synchronize() }

    @objc private func motionChanged() {
        reduced = environmentReduced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        clear()
        rebuild()
    }

    private var isForegroundVisible: Bool {
        guard enabled, observing, let window else { return false }
        return NSApp.isActive && WindowKeyMonitor.frontmostWindow === window
            && window.isVisible && window.occlusionState.contains(.visible)
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }

    private func synchronize() {
        setForeground(isForegroundVisible)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        synchronize()
    }

    func setForeground(_ visible: Bool) {
        if foreground != visible {
            foreground = visible
            foregroundSince = visible ? Date() : nil
            previous = nil
            clear()
            if visible, tracksPointerEvents, let window {
                let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                pointerInside = visibleRect.contains(location)
                if pointerInside { point = location }
            }
        }
        if visible { rebuild() }
    }

    private func receive(_ event: NSEvent) {
        guard event.window === window, isForegroundVisible, settings.effect != .none else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(location) else {
            if pointerInside { mouseExited(with: event) }
            return
        }
        movePointer(to: location)
        if event.type == .leftMouseDown || event.type == .rightMouseDown { click() }
    }

    func movePointer(to location: CGPoint, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard foreground, location.x.isFinite, location.y.isFinite, bounds.contains(location),
              settings.effect != .none else { return }
        if !pointerInside {
            pointerInside = true
            previous = nil
            ribbonStart = nil
        }
        let from = previous ?? location
        point = location
        LayerLoop.still {
            ornament.position = location
        }
        rebuild()
        if entrance != nil {
            previous = location
            return
        }
        if activity == .running && !reduced {
            let spacing: Double = switch settings.effect {
            case .ripple: 14 - settings.intensity * 4
            case .prism: 9 - settings.intensity * 4
            default: 2
            }
            let interval: Double = switch settings.effect {
            case .ripple: 0.1 - settings.intensity * 0.04
            case .prism: 0.044 - settings.intensity * 0.024
            default: 1.0 / 90
            }
            if hypot(location.x - from.x, location.y - from.y) > spacing && time - lastEmission > interval {
                emit(from: from, to: location, elapsed: max(1.0 / 90, min(0.1, time - lastEmission)))
                lastEmission = time
                previous = location
            } else if previous == nil {
                previous = location
            }
        }
    }

    private func clear(preservingTrails: Bool = false) {
        finishEntrance()
        previous = nil
        ribbonStart = nil
        lastEmission = 0
        LayerLoop.still {
            ornament.removeAllAnimations()
            ornament.sublayers?.forEach { $0.removeFromSuperlayer() }
            if !preservingTrails {
                for particle in particles {
                    particleLayers(particle).forEach { $0.removeAllAnimations() }
                    particle.opacity = 0
                }
            }
        }
    }

    func playEntrance(at location: CGPoint, speed: Double = 1, progress: Double? = nil) {
        guard foreground, bounds.contains(location), location.x.isFinite, location.y.isFinite else { return }
        clear()
        point = location
        pointerInside = true
        rebuild()
        startEntrance(speed: speed, progress: progress)
    }

    private func startEntrance(speed: Double = 1, progress: Double? = nil) {
        guard foreground, pointerInside, !reduced, settings.effect != .none,
              activity == .running || activity == .waiting else { return }
        finishEntrance()
        if settings.effect == .aurora {
            // The entrance replaces the cleared trail, so both pools need not occupy the layer budget.
            particles.forEach { $0.removeFromSuperlayer() }
            particles.removeAll()
            nextParticle = 0
        }
        let speed = speed == 0.25 ? 0.25 : 1
        let duration = settings.effect.entranceDuration
        let now = CACurrentMediaTime()
        let fraction = progress.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        let root = CursorEffectEntrance.make(effect: settings.effect, intensity: settings.intensity,
            scale: window?.backingScaleFactor ?? 2, progress: fraction, colour: colour) { index, elapsed in
                let phase = (now + elapsed / speed).truncatingRemainder(dividingBy: Self.orbitPeriod) / Self.orbitPeriod
                return self.satellite(index, phase: phase, radius: 24 + self.settings.intensity * 17)
            }
        if settings.effect == .orbit {
            for track in ornament.sublayers?.compactMap({ $0.name == "orbit-track" ? $0 as? CAShapeLayer : nil }) ?? [] {
                guard let path = track.path, let stroke = track.strokeColor,
                      let tint = NSColor(cgColor: stroke) else { continue }
                let arrival = shape(path: path, colour: tint, width: track.lineWidth)
                arrival.name = "entrance-track"
                arrival.opacity = 0
                let reveal = CAKeyframeAnimation(keyPath: "opacity")
                reveal.values = [0, 0, track.opacity, track.opacity, 0]
                reveal.keyTimes = [0, 0.25, 0.65, 0.86, 1]
                reveal.duration = duration
                reveal.beginTime = .leastNonzeroMagnitude
                reveal.fillMode = .both
                reveal.isRemovedOnCompletion = false
                if let fraction {
                    let capture = min(1, max(0, (fraction - 0.25) / 0.4))
                    let handoff = min(1, max(0, (fraction - 0.86) / 0.14))
                    arrival.opacity = track.opacity * Float(capture * (1 - handoff))
                } else {
                    arrival.add(reveal, forKey: "entrance-track")
                }
                root.insertSublayer(arrival, at: 0)
            }
        }
        LayerLoop.still {
            root.position = point
            root.beginTime = root.convertTime(now, from: nil)
            root.speed = Float(speed)
            layer?.addSublayer(root)
            entrance = root
            let handoffStart = settings.effect == .aurora
                ? (Motion.popDuration * 2 + Motion.revealDuration) / duration
                : settings.effect == .orbit ? 0.86 : 0.66
            let reveal = CAKeyframeAnimation(keyPath: "opacity")
            reveal.values = [0, 0, 1]
            reveal.keyTimes = [0, NSNumber(value: handoffStart), 1]
            if settings.effect == .aurora {
                reveal.keyTimes = nil
                reveal.values = (0...60).map { frame in
                    let p = min(1, max(0, (Double(frame) / 60 - handoffStart) / (1 - handoffStart)))
                    return p * p * (3 - 2 * p)
                }
            }
            reveal.duration = duration / speed
            reveal.beginTime = ornament.convertTime(now, from: nil)
            reveal.fillMode = .both
            if let fraction {
                root.speed = 0
                root.timeOffset = fraction * duration
                let handoff = min(1, max(0, (fraction - handoffStart) / (1 - handoffStart)))
                ornament.opacity = Float(settings.effect == .aurora ? handoff * handoff * (3 - 2 * handoff) : handoff)
                let phase = (now + fraction * duration / speed)
                    .truncatingRemainder(dividingBy: Self.orbitPeriod) / Self.orbitPeriod
                let positions = (0..<4).map { satellite($0, phase: phase, radius: 24 + settings.intensity * 17) }
                let satellites = ornament.sublayers?.filter { $0.name == "orbit-satellite" } ?? []
                for (index, satellite) in satellites.enumerated() { satellite.position = positions[index] }
                for mark in ornament.sublayers ?? [] {
                    if mark.animation(forKey: "constellation") != nil, let shape = mark as? CAShapeLayer {
                        let path = CGMutablePath()
                        path.addLines(between: positions)
                        path.closeSubpath()
                        shape.path = path
                    }
                    mark.removeAllAnimations()
                }
            } else {
                ornament.add(reveal, forKey: "entrance-handoff")
            }
        }
        if progress == nil {
            let work = DispatchWorkItem { [weak self] in self?.finishEntrance() }
            entranceEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration / speed, execute: work)
        }
    }

    func finishEntrance() {
        entranceEnd?.cancel()
        entranceEnd = nil
        LayerLoop.still {
            entrance?.removeFromSuperlayer()
            entrance = nil
            ornament.removeAnimation(forKey: "entrance-handoff")
            ornament.opacity = 1
        }
    }

    private func rebuild() {
        guard foreground, settings.effect != .none, activity == .running, pointerInside else { return }
        guard ornament.sublayers?.isEmpty != false else { return }
        LayerLoop.still {
            ornament.position = point
            if reduced {
                let tint = NSColor(Theme.dotOnText)
                let halo = shape(path: CGPath(ellipseIn: CGRect(x: -8, y: -5, width: 30, height: 30), transform: nil),
                                 colour: tint.withAlphaComponent(0.6), width: 1.2)
                ornament.addSublayer(halo)
                let dot = shape(path: CGPath(ellipseIn: CGRect(x: 16.7, y: 18.7, width: 4.6, height: 4.6), transform: nil),
                                colour: tint, width: 0)
                dot.fillColor = tint.cgColor
                ornament.addSublayer(dot)
            } else if settings.effect == .orbit {
                addOrbits()
            } else if settings.effect == .ember || settings.effect == .aurora {
                let radius = settings.effect == .ember ? 26 + settings.intensity * 13 : 22
                ornament.addSublayer(glow(at: CGPoint(x: 7, y: 10), radius: radius,
                                         colour: colour(settings.effect == .ember ? 0.4 : 1).withAlphaComponent(0.16)))
            }
        }
    }

    private func colour(_ fraction: Double) -> NSColor {
        let dark = Theme.isDark(effectiveAppearance)
        switch settings.effect {
        case .none: return Theme.accentNSColor
        case .ember: return NSColor(calibratedHue: 0.07 + fraction * 0.07, saturation: 0.85,
                                   brightness: dark ? 1 : 0.8, alpha: 1)
        case .aurora: return NSColor(calibratedHue: 0.47 + fraction * 0.28, saturation: 0.55,
                                    brightness: dark ? 1 : 0.7, alpha: 1)
        case .orbit: return NSColor(calibratedHue: 0.5 + fraction * 0.16, saturation: 0.35,
                                   brightness: dark ? 1 : 0.65, alpha: 1)
        case .ripple: return NSColor(calibratedHue: 0.47, saturation: 0.15 + fraction * 0.35,
                                    brightness: dark ? 0.95 : 0.48, alpha: 1)
        case .prism: return NSColor(calibratedHue: 0.49 + fraction * 0.41, saturation: dark ? 0.45 : 0.65,
                                   brightness: dark ? 1 : 0.7, alpha: 1)
        }
    }

    private func shape(path: CGPath, colour: NSColor, width: CGFloat) -> CAShapeLayer {
        let result = CAShapeLayer()
        result.path = path
        result.fillColor = nil
        result.strokeColor = colour.cgColor
        result.lineWidth = width
        result.lineCap = .round
        result.lineJoin = .round
        result.contentsScale = window?.backingScaleFactor ?? 2
        return result
    }

    private func transient() -> CAShapeLayer {
        // Masks count toward the budget as well as their gradient and container layers.
        let cost = settings.effect == .prism ? 5 : settings.effect == .ripple ? 3 : 1
        let capacity = Self.particleLimit / cost
        let particle: CAShapeLayer
        if particles.count < capacity {
            particle = CAShapeLayer()
            particle.contentsScale = window?.backingScaleFactor ?? 2
            for _ in 0..<(cost / 2) {
                let gradient = CAGradientLayer()
                let mask = CAShapeLayer()
                mask.contentsScale = particle.contentsScale
                mask.lineJoin = .round
                gradient.mask = mask
                particle.addSublayer(gradient)
            }
            particles.append(particle)
            layer?.insertSublayer(particle, below: ornament)
        } else {
            particle = particles[nextParticle]
            nextParticle = (nextParticle + 1) % capacity
        }
        particleLayers(particle).forEach { $0.removeAllAnimations() }
        particle.sublayers?.forEach { $0.isHidden = true }
        particle.name = nil
        particle.opacity = 0
        particle.position = .zero
        particle.transform = CATransform3DIdentity
        particle.bounds = .zero
        particle.path = nil
        particle.fillColor = nil
        particle.strokeColor = nil
        particle.lineCap = .round
        particle.lineJoin = .round
        sampleParticles?.append(particle)
        return particle
    }

    private func particleLayers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(particleLayers) + (layer.mask.map(particleLayers) ?? [])
    }

    private func gradient(in particle: CAShapeLayer, at index: Int, colours: [CGColor], stops: [CGFloat],
                          path: CGPath, filled: Bool) -> (CAGradientLayer, CAShapeLayer) {
        let gradient = particle.sublayers![index] as! CAGradientLayer
        let mask = gradient.mask as! CAShapeLayer
        gradient.isHidden = false
        gradient.frame = particle.bounds
        gradient.colors = colours
        gradient.locations = stops.map { NSNumber(value: Double($0)) }
        gradient.startPoint = .zero
        gradient.endPoint = CGPoint(x: 1, y: 1)
        mask.frame = gradient.bounds
        mask.path = path
        mask.fillColor = filled ? NSColor.white.cgColor : nil
        mask.strokeColor = filled ? nil : NSColor.white.cgColor
        mask.lineWidth = 0.8
        return (gradient, mask)
    }

    private func emit(from start: CGPoint, to end: CGPoint, elapsed: CFTimeInterval) {
        let velocity = CGVector(dx: (end.x - start.x) / elapsed, dy: (end.y - start.y) / elapsed)
        let speed = min(2500, hypot(velocity.dx, velocity.dy))
        let origin = CGPoint(x: end.x + 7, y: end.y + 10)
        LayerLoop.still {
            if settings.effect == .ripple {
                ripple(at: end, radius: 24 + settings.intensity * 24,
                       duration: 1 + settings.intensity * 0.22, opacity: 0.42 + settings.intensity * 0.35)
            } else if settings.effect == .prism {
                let angle = atan2(velocity.dy, velocity.dx)
                let scatter = Double.random(in: -7...7)
                let position = CGPoint(x: end.x - sin(angle) * scatter, y: end.y + cos(angle) * scatter)
                facet(at: position, angle: angle, fraction: Double.random(in: 0...1), burst: false)
            } else if settings.effect == .aurora {
                let control = CGPoint(x: start.x + 7, y: start.y + 10)
                let midpoint = CGPoint(x: (control.x + origin.x) / 2, y: (control.y + origin.y) / 2)
                let path = CGMutablePath()
                path.move(to: ribbonStart ?? control)
                path.addQuadCurve(to: midpoint, control: control)
                ribbonStart = midpoint
                for index in 0..<4 {
                    let ribbon = transient()
                    styleRibbon(ribbon, path: path, band: index)
                    let tint = CABasicAnimation(keyPath: "strokeColor")
                    tint.fromValue = colour(1).cgColor
                    tint.toValue = colour(0).cgColor
                    tint.duration = Self.lifetime
                    ribbon.add(tint, forKey: "ribbon-colour")
                    let taper = CABasicAnimation(keyPath: "lineWidth")
                    taper.fromValue = ribbon.lineWidth
                    taper.toValue = 0.1
                    taper.duration = Self.lifetime
                    ribbon.add(taper, forKey: "ribbon-taper")
                    let flow = CAKeyframeAnimation(keyPath: "position")
                    let now = CACurrentMediaTime()
                    flow.values = (0...24).map { frame in
                        let age = Double(frame) / 24
                        let wave = sin((1 - age) * 7 - (now + age * Self.lifetime) * 3 + Double(index) * 0.9)
                            * age * 13 * settings.intensity
                        return NSValue(point: CGPoint(x: 0, y: wave))
                    }
                    flow.duration = Self.lifetime
                    ribbon.add(flow, forKey: "ribbon-flow")
                    fade(ribbon, opacity: [0.05, 0.16, 0.65, 0.65][index])
                }
            } else {
                let count = settings.effect == .ember
                    ? min(11, Int(ceil(speed / 140 * (0.8 + settings.intensity * 2.8))))
                    : max(1, Int(settings.intensity * 3))
                for _ in 0..<count {
                    if settings.effect == .orbit {
                        let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.orbitPeriod) / Self.orbitPeriod
                        let offset = satellite(Int.random(in: 0..<4), phase: phase, radius: 24 + settings.intensity * 17)
                        spark(at: CGPoint(x: end.x + offset.x, y: end.y + offset.y), spread: 18, velocity: velocity)
                    } else {
                        spark(at: origin, spread: 9 + settings.intensity * 58, velocity: velocity)
                    }
                }
            }
        }
    }

    private func styleRibbon(_ ribbon: CAShapeLayer, path: CGPath, band: Int) {
        ribbon.name = "aurora-ribbon"
        ribbon.path = path
        ribbon.lineWidth = [30, 12, 3.7, 1.1][band] * settings.intensity
        ribbon.strokeColor = colour(1).cgColor
        ribbon.lineCap = .round
        ribbon.lineJoin = .round
    }

    private func spark(at origin: CGPoint, spread: Double, velocity: CGVector = .zero) {
        let particle = transient()
        particle.name = "cursor-spark"
        let angle = Double.random(in: 0...(2 * .pi))
        let speed = Double.random(in: spread * 0.2...spread)
        let dx = cos(angle) * speed - max(-2500, min(2500, velocity.dx)) * 0.13
        let dy = sin(angle) * speed - max(-2500, min(2500, velocity.dy)) * 0.13 - 20
        let duration = Self.lifetime * Double.random(in: 0.35...1)
        let gravity = settings.effect == .ember ? 65.0 : 5.0
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: -dx * 0.025, y: -dy * 0.025))
        if Double.random(in: 0...1) > 0.89 {
            path.move(to: CGPoint(x: -2.6, y: 0))
            path.addLine(to: CGPoint(x: 2.6, y: 0))
            path.move(to: CGPoint(x: 0, y: -2.6))
            path.addLine(to: CGPoint(x: 0, y: 2.6))
        }
        particle.path = path
        particle.lineWidth = Double.random(in: 0.5...1.75)
        particle.strokeColor = colour(1).cgColor
        let flight = CAKeyframeAnimation(keyPath: "position")
        flight.values = (0...12).map { frame in
            let time = duration * Double(frame) / 12
            return NSValue(point: CGPoint(x: origin.x + dx * (1 - exp(-0.9 * time)) / 0.9,
                                          y: origin.y + dy * time + gravity * time * time / 2))
        }
        flight.duration = duration
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.9
        opacity.toValue = 0
        opacity.duration = duration
        let cooling = CABasicAnimation(keyPath: "strokeColor")
        cooling.fromValue = particle.strokeColor
        cooling.toValue = colour(0).withAlphaComponent(0.2).cgColor
        cooling.duration = duration
        let thinning = CABasicAnimation(keyPath: "lineWidth")
        thinning.fromValue = particle.lineWidth
        thinning.toValue = 0.1
        thinning.duration = duration
        let group = CAAnimationGroup()
        group.animations = [flight, opacity, cooling, thinning]
        group.duration = duration
        particle.add(group, forKey: "decay")
    }

    private func glow(at point: CGPoint, radius: CGFloat, colour: NSColor) -> CAGradientLayer {
        let glow = CAGradientLayer()
        glow.name = "cursor-glow"
        glow.type = .radial
        glow.colors = [colour.cgColor, colour.cgColor, colour.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.22, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        return glow
    }

    private func fade(_ layer: CALayer, opacity: Float) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        fade.duration = Self.lifetime
        layer.add(fade, forKey: "decay")
    }

    func click() {
        guard foreground, pointerInside, entrance == nil, settings.effect != .none, activity == .running, !reduced else { return }
        LayerLoop.still {
            let origin = sampleParticles == nil ? ornament.presentation()?.position ?? point : point
            let center = CGPoint(x: origin.x + 7, y: origin.y + 10)
            switch settings.effect {
            case .ripple:
                for index in 0..<3 {
                    ripple(at: origin, radius: 63 + settings.intensity * 37 - Double(index) * 12,
                           duration: 1.25, opacity: (0.5 + settings.intensity * 0.2) - Double(index) * 0.13,
                           delay: Double(index) * 0.1)
                }
            case .prism:
                for index in 0..<7 {
                    let angle = Double(index) / 7 * .pi * 2
                    let position = CGPoint(x: origin.x + cos(angle) * 6, y: origin.y + sin(angle) * 6)
                    facet(at: position, angle: angle,
                          fraction: Double(index) / 6, burst: true)
                }
            default:
                for _ in 0..<Int(12 + settings.intensity * 20) { spark(at: center, spread: 175) }
                ring(at: origin, finished: false)
            }
        }
    }

    private func ripple(at origin: CGPoint, radius: Double, duration: Double, opacity: Double, delay: Double = 0) {
        let ring = transient()
        ring.name = "ripple-ring"
        ring.position = origin
        let extent = radius + 1
        ring.bounds = CGRect(x: 0, y: 0, width: extent * 2, height: extent * 1.88)
        let opening = CGPath(ellipseIn: CGRect(x: extent - 3, y: (extent - 3) * 0.94, width: 6, height: 5.64), transform: nil)
        let closing = CGPath(ellipseIn: CGRect(x: 1, y: 0.94, width: radius * 2, height: radius * 1.88), transform: nil)
        let (colour, mask) = gradient(in: ring, at: 0,
            colours: CursorEffectArtwork.ringColours(light: !Theme.isDark(effectiveAppearance)),
            stops: CursorEffectArtwork.ringStops, path: closing, filled: false)
        let easeOut = CAMediaTimingFunction(controlPoints: 1.0 / 3, 1, 2.0 / 3, 1)
        let expansion = CABasicAnimation(keyPath: "path")
        expansion.fromValue = opening
        expansion.toValue = closing
        expansion.timingFunction = easeOut
        let thinning = CABasicAnimation(keyPath: "lineWidth")
        thinning.fromValue = 1
        thinning.toValue = 0.45
        let startColour = CABasicAnimation(keyPath: "startPoint")
        startColour.fromValue = NSValue(point: CGPoint(x: 0.5 - 1.5 / extent, y: 0.5 - 1.5 / extent))
        startColour.toValue = NSValue(point: .zero)
        startColour.timingFunction = easeOut
        let endColour = CABasicAnimation(keyPath: "endPoint")
        endColour.fromValue = NSValue(point: CGPoint(x: 0.5 + 1.5 / extent, y: 0.5 + 1.5 / extent))
        endColour.toValue = NSValue(point: CGPoint(x: 1, y: 1))
        endColour.timingFunction = easeOut
        let birth = ring.convertTime(CACurrentMediaTime(), from: nil) + delay
        for (layer, animations, key) in [(ring as CALayer, [dissolve(opacity: opacity)] as [CAAnimation], "decay"),
                                        (mask, [expansion, thinning], "ripple-shape"),
                                        (colour, [startColour, endColour], "ripple-colour")] {
            let group = CAAnimationGroup()
            animations.forEach { $0.duration = duration }
            group.animations = animations
            group.duration = duration
            group.beginTime = birth
            layer.add(group, forKey: key)
        }
    }

    private func facet(at origin: CGPoint, angle: Double, fraction: Double, burst: Bool) {
        let size = (burst ? 8 : Double.random(in: 5...12)) + settings.intensity * (burst ? 9 : 5)
        let duration = 0.47 + settings.intensity * 0.32
        let drift = burst ? 25 + settings.intensity * 20 : -8.0
        let rotation = angle + (burst ? 0.4 : .pi * 0.1)
        let hue = burst ? 172 + fraction * 156 : 175 + fraction * 140
        let light = !Theme.isDark(effectiveAppearance)
        let shard = transient()
        shard.name = "prism-facet"
        let extent = size * 1.3 + 1
        let center = CGPoint(x: extent, y: extent)
        shard.bounds = CGRect(x: 0, y: 0, width: extent * 2, height: extent * 2)
        let vertices = CursorEffectArtwork.facetVertices(size: size, center: center)
        let outline = CursorEffectArtwork.facetPath(vertices: vertices)
        let (face, _) = gradient(in: shard, at: 0,
            colours: CursorEffectArtwork.faceColours(hue: hue, light: light),
            stops: CursorEffectArtwork.faceStops, path: outline, filled: true)
        face.name = "prism-face"
        let (edge, _) = gradient(in: shard, at: 1,
            colours: CursorEffectArtwork.edgeColours(hue: hue, light: light),
            stops: CursorEffectArtwork.edgeStops, path: outline, filled: false)
        edge.name = "prism-edge"
        edge.startPoint = CGPoint(x: 0, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 0.5)
        shard.path = CursorEffectArtwork.seams(vertices: vertices,
            center: CGPoint(x: extent + size * 0.026, y: extent + size * 0.02))
        shard.strokeColor = CursorEffectArtwork.seamColour(hue: hue, light: light)
        shard.lineWidth = 0.5
        let flight = CABasicAnimation(keyPath: "position")
        flight.fromValue = NSValue(point: origin)
        flight.toValue = NSValue(point: CGPoint(x: origin.x + cos(angle) * drift, y: origin.y + sin(angle) * drift))
        flight.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 1, 2.0 / 3, 1)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.55
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = rotation
        turn.toValue = rotation + 0.13
        let decay = CAAnimationGroup()
        decay.animations = [flight, shrink, turn, dissolve(opacity: 0.65 + settings.intensity * 0.3)]
        decay.animations?.forEach { $0.duration = duration }
        decay.duration = duration
        shard.add(decay, forKey: "decay")
    }

    private func dissolve(opacity: Double) -> CAKeyframeAnimation {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = (0...24).map { opacity * pow(1 - Double($0) / 24, 1.5) }
        return fade
    }

    func playPreviewSample() {
        guard foreground, !reduced, settings.effect != .none else { return }
        clear()
        pointerInside = false
        let start = CACurrentMediaTime()
        var cursorPoints: [NSValue] = []
        // The finite sample must fit the pool before playback begins, including its click burst.
        let steps = settings.effect == .prism ? 56 : settings.effect == .ripple ? 90 : 30
        for index in 0...steps {
            let progress = Double(index) / Double(steps)
            let location = CGPoint(x: bounds.width * (0.24 + 0.52 * progress),
                                   y: bounds.height * (0.6 - sin(progress * .pi * 2) * 0.16))
            sampleParticles = []
            movePointer(to: location, at: start + progress * 3.6)
            if index == Int(ceil(Double(steps) * 0.63)) { click() }
            for particle in (sampleParticles ?? []).flatMap(particleLayers) {
                for key in particle.animationKeys() ?? [] {
                    guard let animation = particle.animation(forKey: key)?.copy() as? CAAnimation else { continue }
                    let delay = animation.beginTime > 0 ? max(0, animation.beginTime - start) : 0
                    animation.beginTime = particle.convertTime(start, from: nil) + progress * 3.6 + delay
                    particle.add(animation, forKey: key)
                }
            }
            cursorPoints.append(NSValue(point: location))
        }
        sampleParticles = nil
        let cursor = CGMutablePath()
        cursor.addLines(between: [.zero, CGPoint(x: 4, y: 19), CGPoint(x: 9, y: 13), CGPoint(x: 16, y: 12)])
        cursor.closeSubpath()
        let mark = shape(path: cursor, colour: .darkGray, width: 1)
        mark.fillColor = NSColor.white.cgColor
        ornament.addSublayer(mark)
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.values = cursorPoints
        travel.duration = 3.6
        ornament.add(travel, forKey: "preview-path")
    }

    private func ring(at origin: CGPoint, finished: Bool) {
        LayerLoop.still {
            let ring = transient()
            ring.position = CGPoint(x: origin.x + 7, y: origin.y + 10)
            ring.strokeColor = (finished ? NSColor(Theme.dotOnText) : colour(0.5)).cgColor
            ring.lineWidth = 1
            let opening = CGPath(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24), transform: nil)
            let closing = CGPath(ellipseIn: CGRect(x: -77, y: -77, width: 154, height: 154), transform: nil)
            ring.path = closing
            let expand = CABasicAnimation(keyPath: "path")
            expand.fromValue = opening
            expand.toValue = closing
            expand.duration = Self.lifetime
            expand.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(expand, forKey: "ring")
            fade(ring, opacity: 0.6)
        }
    }

    private func addOrbits() {
        let now = CACurrentMediaTime()
        let radius = 24 + settings.intensity * 17
        let center = CGPoint(x: 8, y: 10)
        ornament.addSublayer(glow(at: center, radius: 18, colour: colour(0).withAlphaComponent(0.1)))
        for index in 0..<2 {
            var tilt = CGAffineTransform(rotationAngle: index == 0 ? -0.5 : 1.1)
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            let rx = radius * (index == 0 ? 1 : 1.22)
            let ry = radius * (index == 0 ? 0.62 : 0.58)
            let ellipse = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &tilt)
            let orbit = shape(path: ellipse, colour: colour(Double(index)), width: 0.7)
            orbit.name = "orbit-track"
            orbit.opacity = index == 0 ? 0.35 : 0.25
            ornament.addSublayer(orbit)
        }
        let frames = Int(Self.orbitPeriod * 30)
        var positions: [[CGPoint]] = []
        for index in 0..<4 {
            let points = (0...frames).map { frame in
                satellite(index, phase: Double(frame) / Double(frames), radius: radius)
            }
            positions.append(points)
            let dotRadius = index == 0 ? 2.3 : 1.5
            let dot = shape(path: CGPath(ellipseIn: CGRect(x: -dotRadius, y: -dotRadius,
                                                          width: dotRadius * 2, height: dotRadius * 2), transform: nil),
                            colour: colour(Double(index % 2)), width: 0)
            dot.name = "orbit-satellite"
            dot.fillColor = colour(Double(index % 2)).cgColor
            dot.insertSublayer(glow(at: .zero, radius: 7, colour: colour(0).withAlphaComponent(0.3)), at: 0)
            let travel = CAKeyframeAnimation(keyPath: "position")
            travel.values = points.map { NSValue(point: $0) }
            travel.duration = Self.orbitPeriod
            _ = LayerLoop.repeating(travel, period: Self.orbitPeriod)
            travel.beginTime = now
            travel.timeOffset = now.truncatingRemainder(dividingBy: Self.orbitPeriod)
            dot.add(travel, forKey: "orbit")
            ornament.addSublayer(dot)
        }
        let paths = (0...frames).map { frame in
            let path = CGMutablePath()
            path.addLines(between: positions.map { $0[frame] })
            path.closeSubpath()
            return path
        }
        let constellation = shape(path: paths[0], colour: colour(0).withAlphaComponent(0.14), width: 0.55)
        let links = CAKeyframeAnimation(keyPath: "path")
        links.values = paths
        links.duration = Self.orbitPeriod
        _ = LayerLoop.repeating(links, period: Self.orbitPeriod)
        links.beginTime = now
        links.timeOffset = now.truncatingRemainder(dividingBy: Self.orbitPeriod)
        constellation.add(links, forKey: "constellation")
        ornament.insertSublayer(constellation, at: 0)
    }

    private func satellite(_ index: Int, phase: Double, radius: Double) -> CGPoint {
        let reverse = index.isMultiple(of: 2) ? 1.0 : -1.0
        let angle = phase * .pi * 2 * Double(6 + index) * reverse + Double(index) * .pi / 2
        let rx = radius * (index.isMultiple(of: 2) ? 1 : 1.15)
        let ry = radius * 0.65
        let tilt = index.isMultiple(of: 2) ? -0.5 : 1.1
        return CGPoint(x: 8 + cos(angle) * rx * cos(tilt) - sin(angle) * ry * sin(tilt),
                       y: 10 + cos(angle) * rx * sin(tilt) + sin(angle) * ry * cos(tilt))
    }
}
