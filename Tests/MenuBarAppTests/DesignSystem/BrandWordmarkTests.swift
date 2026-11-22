import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct BrandWordmarkTests {
    @Test func motionStopsWhenReducedOrDetachedAndPausesWhenHidden() throws {
        let view = BrandWordmarkView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        let window = WordmarkVisibilityWindow(contentRect: view.bounds,
                                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let font = NSFont.logo(Typography.Size.wordmark)
        let colours = Theme.wordmarkColours.map { $0.resolve(in: EnvironmentValues()).cgColor }
        view.update(font: font, colours: colours, moving: true)
        let ink = try #require(view.layer?.sublayers?.first)
        let gradients = try #require(ink.sublayers)
        let mask = try #require(ink.mask)
        #expect(gradients.allSatisfy { !($0.animationKeys() ?? []).isEmpty })
        #expect((mask.animationKeys() ?? []).isEmpty)
        #expect(view.hitTest(.zero) == nil)

        window.shown = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(view.isPaused)
        window.shown = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!view.isPaused)

        view.update(font: font, colours: colours, moving: false)
        #expect(gradients.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        #expect(ink.mask === mask)
        view.update(font: font, colours: colours, moving: true)
        #expect(gradients.allSatisfy { !($0.animationKeys() ?? []).isEmpty })
        view.removeFromSuperview()
        #expect(gradients.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
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
    override var occlusionState: NSWindow.OcclusionState { shown ? [.visible] : [] }
}
