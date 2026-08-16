import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct TooltipTests {
    @Test func plainTooltipHidesAsSoonAsItsSourceIsExited() {
        let presenter = TooltipPresenter()
        let owner = UUID()
        presenter.show(Tooltip(title: "Refresh"), from: .zero, owner: owner)

        presenter.hide(owner: owner)

        #expect(presenter.current == nil)
    }

    @Test func interactiveTooltipSurvivesTheMoveFromItsSource() {
        let presenter = TooltipPresenter()
        let owner = UUID()
        presenter.show(Tooltip(title: "Open in Finder", action: {}),
                       from: .zero,
                       owner: owner)

        presenter.hide(owner: owner)
        #expect(presenter.current?.title == "Open in Finder")

        presenter.keepInteractiveTooltipVisible()

        #expect(presenter.current?.title == "Open in Finder")
    }

    @Test func interactiveTooltipHidesAfterThePointerLeavesIt() {
        let presenter = TooltipPresenter()
        let owner = UUID()
        presenter.show(Tooltip(title: "Open in Finder", action: {}),
                       from: .zero,
                       owner: owner)

        presenter.keepInteractiveTooltipVisible()
        presenter.hideInteractiveTooltip()

        #expect(presenter.current == nil)
    }
}
