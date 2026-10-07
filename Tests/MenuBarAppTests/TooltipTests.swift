import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct TooltipTests {
    @Test func focusedTooltipUpdatesWithContentAndHidesOnBlur() async {
        let presenter = TooltipPresenter()
        func source(_ text: String, focused: Bool) -> some View {
            Text("Design")
                .appTooltip(text, isFocused: focused)
                .environment(presenter)
        }
        let hosting = NSHostingController(rootView: source("Design has content", focused: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        await settle(hosting.view)

        hosting.rootView = source("Design has content", focused: true)
        await settle(hosting.view)
        #expect(presenter.current?.title == "Design has content")

        hosting.rootView = source("No design content", focused: true)
        await settle(hosting.view)
        #expect(presenter.current?.title == "No design content")

        hosting.rootView = source("No design content", focused: false)
        await settle(hosting.view)
        #expect(presenter.current == nil)
    }

    @Test func descriptionCanBeReopenedByActivationWithoutChangingFocus() async {
        let presenter = TooltipPresenter()
        func source(activation: Int) -> some View {
            Text("Info")
                .appTooltip("Full description", persistsOnHover: true, activation: activation)
                .environment(presenter)
        }
        let hosting = NSHostingController(rootView: source(activation: 0))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        await settle(hosting.view)

        hosting.rootView = source(activation: 1)
        await settle(hosting.view)
        #expect(presenter.current?.title == "Full description")
        presenter.hideAll()
        hosting.rootView = source(activation: 2)
        await settle(hosting.view)
        #expect(presenter.current?.title == "Full description")
        presenter.hideAll()
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }

    @Test func plainTooltipHidesAsSoonAsItsSourceIsExited() {
        let presenter = TooltipPresenter()
        let owner = UUID()
        presenter.show(Tooltip(title: "Refresh"), from: .zero, owner: owner)

        presenter.hide(owner: owner)

        #expect(presenter.current == nil)
    }

    @Test func descriptionTooltipStaysVisibleWhileHovered() async {
        let presenter = TooltipPresenter()
        let owner = UUID()
        let description = String(repeating: "Full package description. ", count: 30)
        presenter.show(Tooltip(title: description, persistsOnHover: true), from: .zero, owner: owner)

        presenter.hide(owner: owner)
        presenter.keepInteractiveTooltipVisible()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(presenter.current?.title == description)

        presenter.hideInteractiveTooltip()
        #expect(presenter.current == nil)
    }

    @Test func descriptionTooltipDismissesOnBlurAndIgnoresOtherOwners() {
        let presenter = TooltipPresenter()
        let owner = UUID()
        presenter.show(Tooltip(title: "Description", persistsOnHover: true), from: .zero, owner: owner)

        presenter.hide(owner: UUID(), immediately: true)
        #expect(presenter.current != nil)
        presenter.hide(owner: owner, immediately: true)
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
