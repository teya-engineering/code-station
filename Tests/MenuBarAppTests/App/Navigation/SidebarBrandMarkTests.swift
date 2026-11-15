import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct SidebarBrandMarkTests {
    @Test(arguments: AppMarkGesture.allCases)
    func reduceMotionAndOcclusionRemoveEveryAnimation(_ gesture: AppMarkGesture) throws {
        let mark = SidebarBrandMarkView(frame: NSRect(x: 0, y: 0, width: 41, height: 41))
        let window = MarkVisibilityWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(mark)
        defer { window.close() }
        let environment = EnvironmentValues()
        func update(_ input: AppMarkMotion.Input) {
            mark.update(input, tile: AppMark.tile.resolve(in: environment).cgColor,
                        dot: AppMark.dot.resolve(in: environment), accent: AppMark.accent.resolve(in: environment).cgColor,
                        choose: { _ in gesture })
        }
        let drawing = try #require(mark.layer?.sublayers?.first)
        let layers = descendants(of: drawing)
        update(.init(hovered: true))
        #expect(!(drawing.animationKeys() ?? []).isEmpty)
        if gesture == .flipSide {
            let edge = try #require(drawing.sublayers?.first)
            #expect(edge.zPosition < 0)
            let opacity = try #require(edge.animation(forKey: "opacity") as? CAKeyframeAnimation)
            #expect(opacity.values?.contains { ($0 as? Double) == 1 } == true)
            let turn = try #require(drawing.animation(forKey: "transform") as? CAKeyframeAnimation)
            let transforms = try #require(turn.values as? [NSValue]).map(\.caTransform3DValue)
            #expect(transforms.contains { $0.m11 < 0 })
            #expect(transforms.last?.m11 == 0.41)
        }
        for layer in layers {
            for key in layer.animationKeys() ?? [] {
                let animation = try #require(layer.animation(forKey: key))
                #expect(animation.repeatCount == 0)
                #expect(animation.duration <= 1.4)
            }
        }
        update(.init(hovered: true, reducedMotion: true))
        #expect(mark.motion.playback == nil)
        #expect(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        update(.init())
        update(.init(hovered: true))
        #expect(mark.motion.playback != nil)
        window.shown = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(mark.motion.playback == nil)
        #expect(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        window.shown = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(mark.motion.playback == nil)
        update(.init())
        update(.init(focused: true))
        #expect(mark.motion.playback != nil)
        mark.removeFromSuperview()
        #expect(mark.motion.playback == nil)
        #expect(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    @Test(arguments: [AppMarkGesture.magnetic, .flipSide])
    func tiltedArtworkStaysOnOneFaceAfterPlayback(_ gesture: AppMarkGesture) throws {
        let mark = SidebarBrandMarkView(frame: NSRect(x: 0, y: 0, width: 41, height: 41))
        let window = MarkVisibilityWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(mark)
        defer { window.close() }
        mark.layoutSubtreeIfNeeded()
        let environment = EnvironmentValues()
        let pointer = CGPoint(x: 1, y: -1)
        mark.update(.init(hovered: true, pointer: pointer), tile: AppMark.tile.resolve(in: environment).cgColor,
                    dot: AppMark.dot.resolve(in: environment), accent: AppMark.accent.resolve(in: environment).cgColor,
                    choose: { _ in gesture })

        let drawing = try #require(mark.layer?.sublayers?.first as? CATransformLayer)
        let surfaces = try #require(drawing.sublayers)
        #expect(surfaces.count == 2)
        let edge = try #require(surfaces.first as? CAShapeLayer)
        let face = try #require(surfaces.last)
        #expect(!(face is CATransformLayer))
        #expect(face.frame == drawing.bounds)
        #expect(!face.masksToBounds)
        #expect(edge.zPosition < face.zPosition)
        let artwork = try #require(face.sublayers)
        #expect(artwork.count == 12)
        #expect(artwork.allSatisfy { $0.zPosition == 0 && $0.contentsScale == drawing.contentsScale })
        let dots = try #require(Array(artwork.suffix(9)) as? [CAShapeLayer])
        let finalPose = gesture.pose(at: 1, pointer: pointer)

        // Completed keyframes are removed by Core Animation. The held artwork must
        // come from the model layers, without relying on animation fill modes.
        for layer in descendants(of: drawing) { layer.removeAllAnimations() }
        for (dot, pose) in zip(dots, finalPose.dots) {
            #expect(dot.position == CGPoint(x: pose.x * 100, y: pose.y * 100))
            #expect(abs(dot.transform.m11 - pose.radius * 100) < 0.000001)
            #expect(abs(dot.transform.m22 - pose.radius * pose.stretch * 100) < 0.000001)
            #expect(dot.opacity == 1)
            #expect(dot.fillColor != nil)
        }
        #expect(mark.motion.pose(at: CACurrentMediaTime() + 30) == finalPose)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func restingArtworkMatchesTheExistingCanvas(_ appearance: ColorScheme) throws {
        let side = 123.0
        let hosting = NSHostingView(rootView: HStack(spacing: 0) {
            AppMark().frame(width: side, height: side)
            SidebarBrandMark(input: .init()).frame(width: side, height: side)
        }.preferredColorScheme(appearance))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side * 2, height: side),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let pixelSide = bitmap.pixelsWide / 2
        for y in AppMark.centres {
            for x in AppMark.centres {
                let px = Int(x * Double(pixelSide))
                let py = Int(y * Double(pixelSide))
                let original = try #require(bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
                let animated = try #require(bitmap.colorAt(x: px + pixelSide, y: py)?.usingColorSpace(.sRGB))
                #expect(abs(original.redComponent - animated.redComponent) < 0.01)
                #expect(abs(original.greenComponent - animated.greenComponent) < 0.01)
                #expect(abs(original.blueComponent - animated.blueComponent) < 0.01)
                #expect(animated.alphaComponent > 0.99)
            }
        }
    }

    @Test func anUnattachedOrHiddenMarkNeverStartsPlayback() {
        let mark = SidebarBrandMarkView(frame: NSRect(x: 0, y: 0, width: 41, height: 41))
        let environment = EnvironmentValues()
        func hover() {
            mark.update(.init(hovered: true), tile: AppMark.tile.resolve(in: environment).cgColor,
                        dot: AppMark.dot.resolve(in: environment), accent: AppMark.accent.resolve(in: environment).cgColor)
        }
        hover()
        #expect(mark.motion.playback == nil)
        #expect(mark.motion.lastGesture == nil)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(mark)
        hover()
        #expect(mark.motion.playback == nil)
        #expect(mark.hitTest(CGPoint(x: 20, y: 20)) == nil)
        #expect(!mark.isAccessibilityElement())
        mark.removeFromSuperview()
    }

    private func descendants(of layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap { descendants(of: $0) }
    }
}

private final class MarkVisibilityWindow: NSWindow {
    var shown = true
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
