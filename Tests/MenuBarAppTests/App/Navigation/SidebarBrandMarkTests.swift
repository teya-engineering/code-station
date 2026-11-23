import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct SidebarBrandMarkTests {
    @Test func onlyDotsAnimateAndInterruptionsRemoveEveryAnimation() throws {
        let mark = SidebarBrandMarkView(frame: NSRect(x: 0, y: 0, width: 41, height: 41))
        let window = MarkVisibilityWindow(contentRect: mark.bounds,
                                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = mark
        defer { window.close() }
        let environment = EnvironmentValues()
        func update(_ input: BrandHover.Input) {
            mark.update(input, tile: AppMark.tile.resolve(in: environment).cgColor,
                        dot: AppMark.dot.resolve(in: environment).cgColor,
                        accent: AppMark.accent.resolve(in: environment).cgColor)
        }
        mark.layoutSubtreeIfNeeded()
        let drawing = try #require(mark.layer?.sublayers?.first)
        let artwork = try #require(drawing.sublayers)
        let tile = try #require(artwork.first)
        let dots = Array(artwork.dropFirst())
        let layers = [drawing] + artwork
        let transform = drawing.transform
        let frame = mark.frame
        update(.init())
        #expect(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        update(.init(hovered: true))
        #expect(dots.count == 9)
        #expect((drawing.animationKeys() ?? []).isEmpty)
        #expect((tile.animationKeys() ?? []).isEmpty)
        #expect(CATransform3DEqualToTransform(drawing.transform, transform))
        #expect(mark.frame == frame)
        for dot in dots {
            #expect(dot.animationKeys()?.count == 2)
            for key in dot.animationKeys() ?? [] {
                let animation = try #require(dot.animation(forKey: key))
                #expect(animation.repeatCount == 0)
                #expect(animation.duration <= Motion.brandOrbitDuration)
            }
        }
        update(.init(hovered: true, reducedMotion: true))
        #expect(mark.motion.playback == nil)
        #expect(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        update(.init(hovered: true))
        #expect(mark.motion.playback == nil)
        for notification in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didResignKeyNotification] {
            update(.init())
            update(.init(hovered: true))
            #expect(mark.motion.playback != nil)
            window.shown = notification != NSWindow.didChangeOcclusionStateNotification
            window.active = notification != NSWindow.didResignKeyNotification
            NotificationCenter.default.post(name: notification, object: window)
            #expect(mark.motion.playback == nil)
            #expect(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
            window.shown = true
            window.active = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            update(.init(hovered: true))
            #expect(mark.motion.playback == nil)
        }
        update(.init())
        update(.init(hovered: true))
        mark.removeFromSuperview()
        #expect(mark.motion.playback == nil)
        #expect(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        for (dot, pose) in zip(dots, AppMarkPose.rest.dots) {
            #expect(dot.position == CGPoint(x: pose.x * 100, y: pose.y * 100))
            #expect(abs(dot.transform.m11 - pose.radius * 100) < 0.000001)
            #expect(abs(dot.transform.m22 - pose.radius * 100) < 0.000001)
        }
        #expect(mark.hitTest(.zero) == nil)
        #expect(!mark.isAccessibilityElement())
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

    @Test func anUnattachedMarkNeverStartsPlayback() {
        let mark = SidebarBrandMarkView(frame: NSRect(x: 0, y: 0, width: 41, height: 41))
        let environment = EnvironmentValues()
        mark.update(.init(hovered: true), tile: AppMark.tile.resolve(in: environment).cgColor,
                    dot: AppMark.dot.resolve(in: environment).cgColor,
                    accent: AppMark.accent.resolve(in: environment).cgColor)
        #expect(mark.motion.playback == nil)
    }
}

private final class MarkVisibilityWindow: NSWindow {
    var shown = true
    var active = true
    override var isKeyWindow: Bool { active }
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
