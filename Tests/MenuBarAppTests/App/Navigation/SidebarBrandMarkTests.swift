import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp
@testable import CodeStationCore

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
        let layers = [drawing] + (drawing.sublayers ?? [])
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
        window.contentView?.addSubview(mark)
        hover()
        #expect(mark.motion.playback == nil)
        #expect(mark.hitTest(CGPoint(x: 20, y: 20)) == nil)
        #expect(!mark.isAccessibilityElement())
        mark.removeFromSuperview()
        window.close()
    }
}

private final class MarkVisibilityWindow: NSWindow {
    var shown = true
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
