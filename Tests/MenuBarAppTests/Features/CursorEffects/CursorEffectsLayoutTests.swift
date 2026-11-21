import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct CursorEffectsLayoutTests {
    @Test(arguments: [CGFloat(722), 460, 340], [TextSize.standard, .large])
    func fitsTheSettingsPane(width: CGFloat, textSize: TextSize) {
        let scratch = ScratchDirectory()
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: scratch.preferences.store)
        settings.textSize = textSize
        settings.cursorEffects.effect = .prism
        let host = NSHostingView(rootView: CursorEffectsSection().environment(settings).padding(14).frame(width: width))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == width)
        #expect(host.fittingSize.height < (width < 600 ? 1200 : 800))
    }

    @Test func rendersAppearanceChoicesForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CURSOR_EFFECTS_PREVIEWS"] else { return }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let scratch = ScratchDirectory()
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: scratch.preferences.store)
        for width: CGFloat in [722, 460, 340] {
            for dark in [false, true] {
                for effect in CursorEffect.allCases {
                    settings.cursorEffects.effect = effect
                    let host = NSHostingView(rootView: CursorEffectsSection()
                        .environment(settings)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .padding(18).frame(width: width)
                        .background(Theme.background))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
                    host.layoutSubtreeIfNeeded()
                    host.setFrameSize(CGSize(width: width, height: host.fittingSize.height))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(
                        to: destination.appendingPathComponent("\(effect.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
        }
    }
}
