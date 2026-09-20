import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

// Both cleanup strips sit in the sidebar's bottom bar, which is 318pt wide less 14pt of
// padding on each side. They only appear once sessions have gone stale or a worktree has
// been orphaned, so nobody sees them during ordinary work and a strip that outgrew that
// column would ship clipped. Measured against a real offer rather than an ideal size,
// since a row answers the ideal question well and only swells once it is handed room.
@MainActor
struct CleanupStripSizeTests {
    private static let column: CGFloat = 318 - 28

    private func strip(title: String, detail: String, isUrgent: Bool,
                       countdownAt: Date?) -> CleanupStrip {
        CleanupStrip(title: title, detail: detail, isUrgent: isUrgent,
                     countdownAt: countdownAt,
                     countdownLabel: "Automatic deletion countdown",
                     hoverTitle: "Click to review",
                     label: "Review old sessions",
                     action: {})
    }

    // The longest wording either strip produces, with the countdown beside it taking room
    // the text cannot have.
    @Test func theWordiestStripStillFitsTheSidebarColumnInOneRow() {
        let wordy = strip(
            title: "128 sessions will be deleted",
            detail: "Older than 30 days · 96 kept for review · 12 projects snoozed",
            isUrgent: true,
            countdownAt: Date().addingTimeInterval(59 * 60))

        let height = measuredHeight(of: wordy)

        #expect(height > 0)
        #expect(height <= 56, "the strip wrapped to \(height)pt in the sidebar column")
    }

    // A calm strip with no countdown is the common case and must not be taller than the
    // urgent one, or the bottom bar would jump as a cohort settles.
    @Test func aCalmStripIsNoTallerThanAnUrgentOne() {
        let calm = measuredHeight(of: strip(
            title: "4 sessions older than 30 days",
            detail: "2 sessions would lose work",
            isUrgent: false, countdownAt: nil))
        let urgent = measuredHeight(of: strip(
            title: "4 sessions will be deleted",
            detail: "Older than 30 days",
            isUrgent: true, countdownAt: Date().addingTimeInterval(600)))

        #expect(calm > 0)
        #expect(calm == urgent, "calm drew \(calm)pt against urgent's \(urgent)pt")
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
