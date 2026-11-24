import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct BrandWordmarkTests {
    @Test func hoverOwnsColourPlaybackWithoutMovingTheTextOrRestartingOnPointerTravel() throws {
        let view = BrandWordmarkView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        let window = WordmarkVisibilityWindow(contentRect: view.bounds,
                                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let environment = EnvironmentValues()
        let accent = Theme.accent.resolve(in: environment).cgColor
        let colours = Theme.wordmarkColours.map { $0.resolve(in: environment).cgColor }
        func update(_ input: BrandHover.Input, pointer: CGPoint = .zero) {
            view.update(font: .logo(Typography.Size.wordmark), accent: accent, colours: colours,
                        input: input, pointer: pointer)
        }
        update(.init())
        let ink = try #require(view.layer?.sublayers?.first)
        let colour = try #require(ink.sublayers?.first)
        let gradient = try #require(colour.sublayers?.first as? CAGradientLayer)
        let gleam = try #require(colour.sublayers?.last)
        let mask = try #require(ink.mask as? CATextLayer)
        let maskFrame = mask.frame
        let text = try #require(mask.string as? NSAttributedString)
        #expect(text.string == "Code Station")
        #expect(text.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat == Typography.wordmarkKerning)
        #expect(ink.backgroundColor == accent)
        #expect(colour.opacity == 0)
        #expect((gradient.animationKeys() ?? []).isEmpty)
        update(.init(hovered: true))
        #expect(colour.opacity == 1)
        let flow = try #require(gradient.animation(forKey: "flow"))
        #expect(flow.repeatCount == .infinity)
        #expect(flow.duration == Motion.wordmarkPeriod)
        #expect(gleam.animation(forKey: "entry")?.repeatCount == 0)
        let start = gradient.startPoint
        update(.init(hovered: true), pointer: CGPoint(x: 1, y: -1))
        #expect(gradient.startPoint != start)
        #expect(gradient.animation(forKey: "flow")?.beginTime == flow.beginTime)
        #expect(mask.frame == maskFrame)
        #expect(CATransform3DIsIdentity(mask.transform))
        #expect((mask.animationKeys() ?? []).isEmpty)
        #expect(view.hitTest(.zero) == nil)
        update(.init())
        #expect(colour.opacity == 0)
        #expect(gradient.animation(forKey: "flow") == nil)
        #expect(gleam.animation(forKey: "entry") == nil)
        #expect(colour.animation(forKey: "fade")?.duration == Motion.leaveDuration)
        window.active = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect([colour, gradient, gleam].allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        window.active = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        update(.init(hovered: true))
        #expect(gradient.animation(forKey: "flow") != nil)
        update(.init(hovered: true, reducedMotion: true))
        #expect(colour.opacity == 1)
        #expect([colour, gradient, gleam].allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        let stillStart = gradient.startPoint
        update(.init(hovered: true, reducedMotion: true), pointer: CGPoint(x: -1, y: 1))
        #expect(gradient.startPoint == stillStart)
        update(.init(hovered: true))
        #expect(colour.opacity == 0)
        #expect(gradient.animation(forKey: "flow") == nil)
        for notification in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didResignKeyNotification] {
            update(.init())
            update(.init(hovered: true))
            window.shown = notification != NSWindow.didChangeOcclusionStateNotification
            window.active = notification != NSWindow.didResignKeyNotification
            NotificationCenter.default.post(name: notification, object: window)
            #expect(colour.opacity == 0)
            #expect([colour, gradient, gleam].allSatisfy { ($0.animationKeys() ?? []).isEmpty })
            window.shown = true
            window.active = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            update(.init(hovered: true))
            #expect(colour.opacity == 0)
            #expect(gradient.animation(forKey: "flow") == nil)
        }
        update(.init())
        update(.init(hovered: true))
        view.removeFromSuperview()
        #expect(colour.opacity == 0)
        #expect([colour, gradient, gleam].allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    @Test func gradientRemainsReadableOnTheSidebar() throws {
        for appearance in try appearances() {
            let sidebar = try swatch(Theme.sidebar, in: appearance)
            let hover = try swatch(Theme.field, in: appearance).over(sidebar)
            let colours = try Theme.wordmarkColours.map { try swatch($0, in: appearance) }
            for from in colours {
                for to in colours {
                    for step in 0...10 {
                        let ink = from.faded(to: Double(step) / 10).over(to)
                        #expect(ink.contrast(against: sidebar) >= 4.5)
                        #expect(ink.contrast(against: hover) >= 4.5)
                    }
                }
            }
        }
    }
}

private final class WordmarkVisibilityWindow: NSWindow {
    var shown = true
    var active = true
    override var isKeyWindow: Bool { active }
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
