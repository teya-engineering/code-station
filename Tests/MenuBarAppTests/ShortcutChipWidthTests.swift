import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The row decides which commands it can hold before it draws any of them, from widths
// read off the type rather than off the chips. That only holds the row together while
// the two agree: a chip drawn wider than it was measured overflows the strip, and the
// strip clips it into a name that reads as a different command.
//
// So every shape a chip comes in is drawn here and measured against the width the fit
// was given for it. The measured width may be generous - a chip that is passed over
// when it would have fitted only loses a slot - but it may never be short.
@MainActor
struct ShortcutChipWidthTests {
    // Widths are rounded up to whole points as they are read, so a reserve sits a point
    // or two above what is drawn. Any more than that and the row is turning commands away
    // from room it has.
    private static let slack: CGFloat = 2

    private let states: [ShortcutStore.State] = [
        .stopped,
        .running(since: .now),
        .finished(at: .now),
        .failed("no", status: 1, at: .now)
    ]

    @Test func everyChipIsDrawnWithinTheWidthTheFitSetAsideForIt() {
        let names = ["Go", "Lint", "Unit tests", "Deploy to staging",
                     "Regenerate the OpenAPI client and check it in"]
        let glyphs: [String?] = [nil, "hammer", "chevron.left.forwardslash.chevron.right",
                                 "wrench.and.screwdriver", "waveform.path.ecg"]

        for name in names {
            for glyph in glyphs {
                for state in states {
                    for tinted in [false, true] {
                        let shortcut = Shortcut(name: name, text: "true", icon: glyph)
                        let drawn = width(of: ShortcutChip(
                            shortcut: shortcut,
                            state: state,
                            tint: tinted ? Theme.projectTint(for: name) : nil,
                            open: false,
                            toggle: {}))
                        let predicted = ShortcutChipFit.chipWidth(
                            name: name, glyph: shortcut.glyph, state: state, tinted: tinted)

                        #expect(drawn <= predicted && predicted - drawn <= Self.slack,
                                "\(name) / \(glyph ?? "no icon") drew \(drawn), fit reserved \(predicted)")
                    }
                }
            }
        }
    }

    // The count chip is measured once for every command there is, since which of them end
    // up behind it is only settled after the room for it has been set aside.
    @Test func theCountChipIsDrawnWithinTheWidthReservedForTheLargestCount() {
        let reserved = ShortcutChipFit.countWidth(total: 30, badged: true)

        for count in [1, 9, 10, 30] {
            for badge in [nil, Theme.dotOn, Theme.deletion] {
                let drawn = width(of: ShortcutCountChip(count: count, badge: badge,
                                                        menu: { [] }))
                let predicted = ShortcutChipFit.countWidth(total: count, badged: badge != nil)

                #expect(drawn <= reserved,
                        "\(count) more drew \(drawn), largest count reserved \(reserved)")
                #expect(drawn <= predicted && predicted - drawn <= Self.slack,
                        "\(count) more drew \(drawn), fit reserved \(predicted)")
            }
        }
    }

    private func width(of view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view
            .environment(TooltipPresenter())
            .environment(MenuPresenter()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return host.fittingSize.width
    }
}
