import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// The cleanup card sits in the sidebar's bottom bar, which is 318pt wide less 14pt of
// padding on each side. It only appears once sessions have gone stale, so nobody sees it
// during ordinary work and a card that outgrew that column would ship clipped. Measured
// against a real offer rather than an ideal size, since a row answers the ideal question
// well and only swells once it is handed room.
@MainActor
struct CleanupStripSizeTests {
    private static let column: CGFloat = 318 - 28

    private func parked(_ count: Int, reasons: [CleanupReason]) -> [OldSessionSweep.Parked] {
        (0..<count).map { _ in OldSessionSweep.Parked(item: .session(UUID()), reasons: reasons) }
    }

    // The wordiest card: both lines, with the countdown taking room the text cannot have.
    @Test func theWordiestCardKeepsEachLineToOneRow() {
        let status = OldSessionSweep.Status(
            deletion: .init(at: Date().addingTimeInterval(59 * 60), sessions: 128,
                            worktrees: 12),
            parked: parked(96, reasons: [.uncommittedChanges])
                + parked(88, reasons: [.unread]))

        let height = measuredHeight(of: CleanupStrip(status: status, onReview: { _ in }))

        #expect(height > 0)
        #expect(height <= 104, "the card wrapped to \(height)pt in the sidebar column")
    }

    // A card with one line is the same height whichever line it is, so the bottom bar
    // does not jump as the countdown ends and only the waiting line is left.
    @Test func eitherLineAloneIsTheSameHeight() {
        let goes = measuredHeight(of: CleanupStrip(
            status: .init(deletion: .init(at: Date().addingTimeInterval(600), sessions: 4)),
            onReview: { _ in }))
        let waits = measuredHeight(of: CleanupStrip(
            status: .init(parked: parked(3, reasons: [.unread])), onReview: { _ in }))

        #expect(goes > 0)
        #expect(goes == waits, "the countdown line drew \(goes)pt against \(waits)pt")
    }

    private func measuredHeight(of strip: CleanupStrip) -> CGFloat {
        let measured = Measured()
        let column = VStack(spacing: 0) {
            strip.background(GeometryReader { proxy in
                Color.clear.onAppear { measured.height = proxy.size.height }
            })
            Color.clear
        }

        let view = NSHostingView(rootView: column)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.column, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: Self.column, height: 400)
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
        return measured.height
    }

    @MainActor private final class Measured {
        var height: CGFloat = 0
    }
}
