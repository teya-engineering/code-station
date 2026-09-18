import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The strip sits in the stack above the composer, which offers it the whole pane. It is
// one line of text with pills beside it, so it has to take a row's worth of that and
// leave the rest, however much room it is handed. Measured against a real offer rather
// than by asking for an ideal size, since a greedy row answers the ideal question well
// and only swells once a parent hands it the room.
@MainActor
struct PromptSuggestionStripSizeTests {
    @Test func staysOneRowTallInASpaceThatOffersFarMore() {
        for hasDraft in [false, true] {
            let measured = Measured()
            let pane = VStack(spacing: 0) {
                PromptSuggestionStrip(
                    suggestion: "add me to the admins group in the dev config",
                    hasDraft: hasDraft, edit: {}, send: {}, dismiss: {})
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { measured.height = proxy.size.height }
                    })
                Color.clear
            }
            .environment(TooltipPresenter())

            let view = NSHostingView(rootView: pane)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            for _ in 0..<4 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                view.layoutSubtreeIfNeeded()
            }

            #expect(measured.height > 0)
            #expect(measured.height <= 48)
        }
    }

    @MainActor private final class Measured {
        var height: CGFloat = 0
    }
}
