import AppKit
import Testing
@testable import MenuBarApp

@MainActor
struct CursorEntranceTests {
    private let effects: [CursorEffect] = [.ember, .aurora, .orbit, .ripple, .prism]

    @Test func selectedEntrancesHaveTheApprovedDurations() {
        #expect(effects.map(\.entranceName) == ["Kindle", "Nova burst", "Assemble", "First drop", "Crystal bloom"])
        #expect(effects.map { Int(($0.entranceDuration * 1000).rounded()) } == [600, 1200, 780, 600, 780])
        #expect(CursorEffect.none.entranceDuration == 0)
    }

    @Test(arguments: [CursorEffect.ember, .aurora, .orbit, .ripple, .prism])
    func startsOnceAndDoesNotReplayOnWaitingFocusEntryOrResize(effect: CursorEffect) throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView(effect)
        let turn = Date()
        configure(view, effect, .running, turn)
        let entrance = try #require(view.entrance)
        configure(view, effect, .running, turn)
        #expect(view.entrance === entrance)
        view.movePointer(to: CGPoint(x: 140, y: 120))
        #expect(entrance.position == CGPoint(x: 100, y: 100))
        #expect(layers(view.layer).allSatisfy { $0.animation(forKey: "decay") == nil })
        view.click()
        #expect(layers(view.layer).allSatisfy { $0.animation(forKey: "decay") == nil })
        configure(view, effect, .waiting, turn)
        configure(view, effect, .running, turn)
        #expect(view.entrance == nil)
        view.setForeground(false)
        view.setForeground(true)
        view.leavePointer()
        view.movePointer(to: CGPoint(x: 100, y: 100))
        view.setFrameSize(CGSize(width: 550, height: 320))
        #expect(view.entrance == nil)
        view.stop()
    }

    @Test(arguments: [CursorEffect.ember, .aurora, .orbit, .ripple, .prism],
          [CursorEffectActivity.running, .waiting])
    func entranceStaysAtItsStartWhileThePointerMoves(effect: CursorEffect, activity: CursorEffectActivity) throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView(effect)
        let origin = CGPoint(x: 180, y: 90)
        view.movePointer(to: origin)
        configure(view, effect, activity, Date())
        let entrance = try #require(view.entrance)
        let started = entrance.beginTime
        let ornament = try #require(layers(view.layer).first { $0.animation(forKey: "entrance-handoff") != nil })
        for location in [CGPoint(x: 250, y: 160), CGPoint(x: 400, y: 220), CGPoint(x: 60, y: 40)] {
            view.movePointer(to: location)
            #expect(view.entrance === entrance)
            #expect(entrance.position == origin)
            #expect(entrance.beginTime == started)
            #expect(ornament.position == location)
        }
        view.finishEntrance()
        #expect(view.entrance == nil && entrance.superlayer == nil)
        #expect(ornament.position == CGPoint(x: 60, y: 40))
        #expect(ornament.opacity == 1)
        view.stop()
    }

    @Test func activationOutsideTheWindowIsConsumed() {
        let view = makeView(.ember)
        view.leavePointer()
        configure(view, .ember, .running, Date())
        #expect(view.entrance == nil)
        view.movePointer(to: CGPoint(x: 100, y: 100))
        #expect(view.entrance == nil)
        view.stop()
    }

    @Test func activationWhileHiddenDoesNotReplayWhenShown() {
        let view = makeView(.ember)
        view.setForeground(false)
        configure(view, .ember, .running, Date())
        view.setForeground(true)
        view.movePointer(to: CGPoint(x: 100, y: 100))
        #expect(view.entrance == nil)
        view.stop()
    }

    @Test func aDelayedBackgroundStartDoesNotPlayWhenFocusReturns() {
        let view = makeView(.ember)
        configure(view, .ember, .running, Date())
        view.setForeground(false)
        let backgroundStart = Date().addingTimeInterval(-1)
        view.setForeground(true)
        configure(view, .ember, .running, backgroundStart)
        #expect(view.entrance == nil)
        view.stop()
    }

    @Test(arguments: [CursorEffect.ember, .aurora, .orbit, .ripple, .prism])
    func handsOffWithoutAnotherBurst(effect: CursorEffect) throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView(effect)
        configure(view, effect, .running, Date())
        let entrance = try #require(view.entrance)
        view.finishEntrance()
        #expect(view.entrance == nil && entrance.superlayer == nil)
        #expect(layers(view.layer).allSatisfy { $0.animation(forKey: "decay") == nil })
        #expect(layers(view.layer).filter { $0.name == "orbit-satellite" }.count == (effect == .orbit ? 4 : 0))
        view.movePointer(to: CGPoint(x: 200, y: 150))
        view.movePointer(to: CGPoint(x: 240, y: 160), at: CACurrentMediaTime() + 0.2)
        #expect(layers(view.layer).contains { $0.animation(forKey: "decay") != nil })
        view.stop()
    }

    @Test func orbitArrivalsLandOnTheRunningSatellites() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView(.orbit)
        configure(view, .orbit, .running, Date())
        let entrance = try #require(view.entrance)
        let arrivals = layers(entrance).filter { $0.name == "entrance-satellite" }
        let satellites = layers(view.layer).filter { $0.name == "orbit-satellite" }
        #expect(arrivals.count == satellites.count)
        for (arrival, satellite) in zip(arrivals, satellites) {
            let flight = try #require(arrival.animation(forKey: "entrance-position") as? CAKeyframeAnimation)
            let final = try #require((flight.values as? [NSValue])?.last?.pointValue)
            let orbit = try #require(satellite.animation(forKey: "orbit") as? CAKeyframeAnimation)
            let points = try #require(orbit.values as? [NSValue]).map(\.pointValue)
            let phase = (entrance.beginTime + CursorEffect.orbit.entranceDuration - orbit.beginTime + orbit.timeOffset)
                .truncatingRemainder(dividingBy: orbit.duration) / orbit.duration
            let frame = phase * Double(points.count - 1)
            let before = points[Int(frame)]
            let after = points[min(points.count - 1, Int(frame) + 1)]
            let fraction = frame - floor(frame)
            let expected = CGPoint(x: before.x + (after.x - before.x) * fraction,
                                   y: before.y + (after.y - before.y) * fraction)
            #expect(hypot(final.x - expected.x, final.y - expected.y) < 0.05)
        }
        view.stop()
    }

    @Test func changingEffectsAndStartingAnotherTurnCanPlayAgain() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView(.ember)
        let first = Date()
        configure(view, .ember, .running, first)
        let ember = try #require(view.entrance)
        configure(view, .prism, .running, first)
        let prism = try #require(view.entrance)
        #expect(ember !== prism && ember.superlayer == nil)
        configure(view, .none, .running, first)
        #expect(view.entrance == nil)
        configure(view, .ripple, .running, first)
        let ripple = try #require(view.entrance)
        configure(view, .ripple, .running, first.addingTimeInterval(1))
        #expect(view.entrance != nil && view.entrance !== ripple)
        view.stop()
    }

    @Test(arguments: [CursorEffect.aurora, .prism])
    func stopAndReducedMotionCancelWithoutLosingCompletion(effect: CursorEffect) throws {
        let view = makeView(effect)
        let turn = Date()
        configure(view, effect, .running, turn)
        view.configure(settings: CursorEffectsSettings(effect: effect),
                       activity: .running, reduceMotion: true, turnStarted: turn)
        #expect(view.entrance == nil)
        #expect(layers(view.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        configure(view, effect, .running, turn)
        #expect(view.entrance == nil)
        configure(view, effect, .finished, nil)
        #expect(view.entrance == nil)
        let rings = layers(view.layer).filter { $0.animation(forKey: "ring") != nil }
        #expect(rings.count == (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1))
        configure(view, effect, .finished, nil)
        #expect(layers(view.layer).filter { $0.animation(forKey: "ring") != nil }.count == rings.count)
        view.stop()
    }

    @Test(arguments: [CursorEffect.ember, .aurora, .orbit, .ripple, .prism], [0.1, 0.55, 1.0])
    func geometryIsFiniteAndBoundedAtEveryKeyframe(effect: CursorEffect, intensity: Double) throws {
        for dark in [false, true] {
            let root = CursorEffectEntrance.make(effect: effect, intensity: intensity, scale: 2,
                colour: { NSColor(calibratedHue: $0 * 0.8, saturation: 0.6, brightness: dark ? 1 : 0.6, alpha: 1) },
                satellite: { index, time in CGPoint(x: cos(Double(index) + time) * 33, y: sin(Double(index) + time) * 24) })
            let marks = layers(root)
            #expect(marks.count < (effect == .aurora ? CursorEffectLayerView.particleLimit : 60))
            if effect == .orbit { #expect(marks.filter { $0.name == "entrance-satellite" }.count == 4) }
            if effect == .prism { #expect(marks.filter { $0.name == "entrance-facet" }.count == 6) }
            if effect == .ripple { #expect(marks.filter { $0.name == "entrance-wave" }.count == 1) }
            for mark in marks {
                for key in mark.animationKeys() ?? [] {
                    let animation = try #require(mark.animation(forKey: key) as? CAKeyframeAnimation)
                    #expect(animation.duration == effect.entranceDuration)
                    #expect(animation.repeatCount == 0)
                    #expect(animation.values?.count == 61)
                    for value in animation.values ?? [] {
                        if animation.keyPath == "path" {
                            let bounds = (value as! CGPath).boundingBoxOfPath
                            #expect(bounds.minX.isFinite && bounds.minY.isFinite)
                            #expect(bounds.width.isFinite && bounds.height.isFinite)
                            let limit: CGFloat = effect == .aurora ? 500 : 250
                            #expect(bounds.width < limit && bounds.height < limit)
                        } else if animation.keyPath == "position" {
                            let point = (value as! NSValue).pointValue
                            #expect(point.x.isFinite && point.y.isFinite)
                        } else if animation.keyPath == "opacity" {
                            #expect((0...1).contains(try #require(value as? Double)))
                        } else if animation.keyPath == "bounds" {
                            let bounds = try #require(value as? NSValue).rectValue
                            #expect(bounds.width.isFinite && bounds.height.isFinite)
                            #expect(bounds.width > 0 && bounds.width < 500)
                            #expect(bounds.height > 0 && bounds.height < 500)
                        }
                    }
                }
            }
        }
    }

    @Test func novaGathersBurstsAndDissolvesAroundThePointer() throws {
        func frame(_ milliseconds: Double) -> [CALayer] {
            CursorEffectEntrance.make(effect: .aurora, intensity: 0.55, scale: 2,
                progress: milliseconds / 1200,
                colour: { NSColor(calibratedHue: 0.47 + $0 * 0.28, saturation: 0.55, brightness: 1, alpha: 1) },
                satellite: { _, _ in .zero }).sublayers ?? []
        }
        let start = frame(0)
        let charge = frame(520)
        let explosion = frame(700)
        let decay = frame(980)
        let end = frame(1200)
        #expect(start.allSatisfy { $0.opacity == 0 })
        #expect(end.allSatisfy { $0.opacity < 0.001 })
        #expect(charge.contains { $0.name == "entrance-charge-core" && $0.opacity > 0 })
        #expect(charge.filter { $0.name?.hasPrefix("entrance-burst") == true }.allSatisfy { $0.opacity == 0 })
        #expect(explosion.filter { $0.name == "entrance-burst-streak" }.count == 54)
        #expect(explosion.filter { $0.name == "entrance-burst-point" }.count == 52)
        let streaks = explosion.filter { $0.name == "entrance-burst-streak" }
        #expect(Set(streaks.map(\.opacity)).count > 20)
        let widths = streaks.compactMap { ($0.mask?.sublayers?.last as? CAShapeLayer)?.lineWidth }
        #expect(Set(widths).count > 20)
        #expect(explosion.filter { $0.name == "entrance-burst-flare" && $0.opacity > 0 }.count == 1)
        #expect(decay.filter { $0.name == "entrance-burst-flare" }.allSatisfy { $0.opacity == 0 })
        #expect(explosion.filter { $0.name == "entrance-burst-wave" && $0.opacity > 0 }.count == 1)
        #expect(decay.filter { $0.name == "entrance-burst-wave" }.allSatisfy { $0.opacity == 0 })
        for (before, after) in zip(explosion, decay) where before.name == "entrance-burst-streak" {
            #expect(before.opacity > after.opacity && after.opacity > 0)
            let gradient = try #require(before as? CAGradientLayer)
            let colours = try #require(gradient.colors as? [CGColor])
            #expect(colours.first?.alpha == 0)
            #expect(colours.last!.alpha < 0.1)
            #expect(colours[2].alpha == 1)
        }
        for marks in [start, charge, explosion, decay, end] {
            #expect(marks.allSatisfy { CATransform3DIsIdentity($0.transform) })
            #expect(marks.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        }
    }

    @Test func novaReplacesAFullTrailWithinTheLayerBudget() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView(.aurora)
        let turn = Date()
        configure(view, .aurora, .running, turn)
        view.finishEntrance()
        let start = CACurrentMediaTime()
        for index in 0..<500 {
            view.movePointer(to: CGPoint(x: 30 + index * 13 % 400, y: 50 + index * 17 % 200),
                             at: start + Double(index) / 60)
        }
        #expect(layers(view.layer).filter { $0.name == "aurora-ribbon" }.count == CursorEffectLayerView.particleLimit)
        configure(view, .aurora, .running, turn.addingTimeInterval(1))
        #expect(view.entrance != nil)
        #expect(layers(view.layer).count < CursorEffectLayerView.particleLimit)
        view.stop()
    }

    @Test func novaHandsOffToTheExistingGlowAndTrailWithoutChangingTheCursor() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let cursor = NSCursor.current
        let hotspot = cursor.hotSpot
        let image = cursor.image.tiffRepresentation
        let view = makeView(.aurora)
        configure(view, .aurora, .running, Date())
        #expect(view.hitTest(CGPoint(x: 100, y: 100)) == nil)
        var previousOpacity: Float = 0
        for milliseconds in [780.0, 980, 1200] {
            view.playEntrance(at: CGPoint(x: 200, y: 150), progress: milliseconds / 1200)
            let glow = try #require(layers(view.layer).first { $0.name == "cursor-glow" })
            #expect(glow.bounds.size == CGSize(width: 44, height: 44))
            let ornament = try #require(glow.superlayer)
            #expect(ornament.position == CGPoint(x: 200, y: 150))
            #expect(ornament.opacity >= previousOpacity)
            if milliseconds == 780 { #expect(ornament.opacity < 0.001) }
            if milliseconds == 1200 { #expect(ornament.opacity == 1) }
            previousOpacity = ornament.opacity
        }
        view.finishEntrance()
        view.movePointer(to: CGPoint(x: 220, y: 160))
        view.movePointer(to: CGPoint(x: 240, y: 170), at: CACurrentMediaTime() + 0.2)
        let ribbons = layers(view.layer).filter { $0.name == "aurora-ribbon" }
        #expect(!ribbons.isEmpty)
        for ribbon in ribbons {
            #expect(try #require(ribbon.animation(forKey: "decay")).duration == Motion.popDuration * 3)
        }
        #expect(NSCursor.current.hotSpot == hotspot)
        #expect(NSCursor.current.image.tiffRepresentation == image)
        view.stop()
    }

    @Test func scrubbingSpeedAndReducedMotionShareTheProductionRenderer() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let view = makeView(.ripple)
        configure(view, .ripple, .running, Date())
        view.playEntrance(at: CGPoint(x: 200, y: 150), speed: 0.25)
        #expect(view.entrance?.speed == 0.25)
        for progress in [0.0, 0.52, 1] {
            view.playEntrance(at: CGPoint(x: 200, y: 150), progress: progress)
            let root = try #require(view.entrance)
            #expect(root.speed == 0)
            #expect(root.timeOffset == progress * CursorEffect.ripple.entranceDuration)
            #expect(layers(view.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
            if progress == 0.52 {
                #expect(layers(root).contains { $0.name == "entrance-wave" && $0.opacity > 0 })
            }
        }
        view.configure(settings: CursorEffectsSettings(effect: .ripple), activity: .running, reduceMotion: true)
        view.playEntrance(at: CGPoint(x: 200, y: 150))
        #expect(view.entrance == nil)
        #expect(layers(view.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        view.stop()
    }

    @Test func intensityScalesTheEntranceCountExtentAndBrightness() throws {
        func flecks(_ intensity: Double) -> [CAShapeLayer] {
            let root = CursorEffectEntrance.make(effect: .ember, intensity: intensity, scale: 2, progress: 0.52,
                colour: { _ in .orange }, satellite: { _, _ in .zero })
            return layers(root).compactMap { $0.name == "entrance-fleck" ? $0 as? CAShapeLayer : nil }
        }
        let subtle = flecks(0.1)
        let strong = flecks(1)
        #expect(strong.count > subtle.count)
        let firstSubtle = try #require(subtle.first)
        let firstStrong = try #require(strong.first)
        #expect(firstStrong.opacity > firstSubtle.opacity)
        #expect(try #require(firstStrong.path).boundingBoxOfPath.maxX > #require(firstSubtle.path).boundingBoxOfPath.maxX)
    }

    @Test func rendersEntranceKeyframesForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CURSOR_EFFECTS_PREVIEWS"] else { return }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for dark in [false, true] {
            for effect in effects {
                let view = makeView(effect)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                configure(view, effect, .running, Date())
                let frames: [Double] = effect == .aurora
                    ? [520.0 / 1200, 700.0 / 1200, 980.0 / 1200, 1] : [0.15, 0.52, 0.85, 1]
                for progress in frames {
                    view.playEntrance(at: CGPoint(x: 250, y: 150), progress: progress)
                    let context = try #require(CGContext(data: nil, width: 500, height: 300, bitsPerComponent: 8,
                        bytesPerRow: 2000, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.setFillColor((dark ? Theme.canvasDarkNSColor : Theme.canvasLightNSColor).cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: 500, height: 300))
                    context.translateBy(x: 0, y: 300)
                    context.scaleBy(x: 1, y: -1)
                    view.layer?.render(in: context)
                    let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination
                        .appendingPathComponent("entrance-\(effect.rawValue)-\(dark ? "dark" : "light")-\(Int(progress * 100)).png"))
                }
                view.stop()
            }
        }
    }

    private func makeView(_ effect: CursorEffect) -> CursorEffectLayerView {
        let view = CursorEffectLayerView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        view.tracksPointerEvents = false
        view.layoutLayers()
        view.setForeground(true)
        configure(view, effect, .inactive, nil)
        view.movePointer(to: CGPoint(x: 100, y: 100))
        return view
    }

    private func configure(_ view: CursorEffectLayerView, _ effect: CursorEffect,
                           _ activity: CursorEffectActivity, _ turn: Date?) {
        view.configure(settings: CursorEffectsSettings(effect: effect), activity: activity,
                       reduceMotion: false, turnStarted: turn)
    }

    private func layers(_ root: CALayer?) -> [CALayer] {
        guard let root else { return [] }
        return [root] + (root.sublayers ?? []).flatMap { layers($0) } + layers(root.mask)
    }
}
