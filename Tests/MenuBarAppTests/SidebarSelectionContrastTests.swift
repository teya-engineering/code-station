import AppKit
import Testing
@testable import MenuBarApp

struct SidebarSelectionContrastTests {
    @Test func navigationLabelsAndFocusRemainReadableInBothAppearances() throws {
        for appearance in try appearances() {
            let accent = try swatch(Theme.accent, in: appearance)
            let sidebar = try swatch(Theme.sidebar, in: appearance)
            let currentRow = accent.faded(to: 0.085).over(sidebar)
            let badge = accent.faded(to: 0.09).over(currentRow)
            let card = try swatch(Theme.card, in: appearance)

            #expect(accent.contrast(against: currentRow) >= 4.5)
            #expect(accent.contrast(against: badge) >= 4.5)
            #expect(accent.contrast(against: card) >= 4.5)
            #expect(accent.contrast(against: sidebar) >= 3)
        }
    }
}
