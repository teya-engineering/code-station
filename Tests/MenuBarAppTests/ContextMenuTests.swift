import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

@MainActor
struct ContextMenuTests {
    @Test func menuScrollViewCapsLongContentAndShrinksWithItsContent() {
        let model = MenuContentHeight(500)
        let host = NSHostingView(rootView: ResizingMenuContent(model: model))
        #expect(host.fittingSize.height == 300)

        model.value = 120
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        #expect(host.fittingSize.height == 120)
    }

    @Test func menuItemsMatchFiltersByNameOrSubtitle() {
        let item = MenuItem(label: "merchant-account",
                            subtitle: "~/Development/payments/merchant-account")

        #expect(item.matches("MERCHANT"))
        #expect(item.matches("payments"))
        #expect(item.matches("  "))
        #expect(!item.matches("checkout"))
    }

    @Test func menuRowRunsItsHandlerAndDismissesTheMenu() {
        var selected = false
        let item = MenuItem(label: "merchant-account", handler: { selected = true })
        let presenter = MenuPresenter()
        presenter.show([.item(item)], at: .zero)

        presenter.run(item)

        #expect(selected)
        #expect(!presenter.isOpen)
    }

    @Test func refreshesTheCurrentMenuWithoutReplacingANewerMenu() {
        let presenter = MenuPresenter()
        let firstGeneration = presenter.show([
            .cards([MenuCardItem(label: "Docker", icon: "shippingbox.fill",
                                 detail: "checking…")])
        ], at: .zero)

        presenter.replaceEntries([
            .cards([MenuCardItem(label: "Docker", icon: "shippingbox.fill",
                                 detail: "2 running")])
        ], ifGeneration: firstGeneration)

        guard case .cards(let refreshedItems) = presenter.entries.first else {
            Issue.record("Expected refreshed menu cards")
            return
        }
        #expect(refreshedItems.first?.detail == "2 running")

        presenter.show([
            .cards([MenuCardItem(label: "Other", icon: "wrench", detail: "open")])
        ], at: .zero)

        presenter.replaceEntries([
            .cards([MenuCardItem(label: "Docker", icon: "shippingbox.fill",
                                 detail: "2 running")])
        ], ifGeneration: firstGeneration)

        guard case .cards(let items) = presenter.entries.first else {
            Issue.record("Expected menu cards")
            return
        }
        #expect(items.first?.label == "Other")
        #expect(items.first?.detail == "open")
    }

    @Test func detailActionDoesNotMakeTheWholeRowInteractive() {
        var revocations = 0
        let entry = MenuEntry.item("All projects", detail: "Revoke", detailAction: {
            revocations += 1
        })
        guard case .item(let item) = entry else {
            Issue.record("Expected a menu item")
            return
        }
        let presenter = MenuPresenter()
        presenter.show([entry], at: .zero)

        presenter.run(item)

        #expect(presenter.isOpen)
        #expect(revocations == 0)

        presenter.runDetail(item)

        #expect(!presenter.isOpen)
        #expect(revocations == 1)
    }

    @Test func topEdgeMenuOpensAboveItsControl() {
        let attachment = MenuVerticalAttachment.control(edge: .top, oppositeY: 544)

        #expect(attachment.y(originY: 500, menuHeight: 80, boundsHeight: 660) == 420)
    }

    @Test func topEdgeMenuUsesTheOtherSideWhenThereIsNoRoomAbove() {
        let attachment = MenuVerticalAttachment.control(edge: .top, oppositeY: 84)

        #expect(attachment.y(originY: 40, menuHeight: 80, boundsHeight: 660) == 84)
    }
}

@MainActor
@Observable
private final class MenuContentHeight {
    var value: CGFloat

    init(_ value: CGFloat) {
        self.value = value
    }
}

private struct ResizingMenuContent: View {
    let model: MenuContentHeight

    var body: some View {
        MenuContentScrollView(maxHeight: 300) {
            Color.clear.frame(width: 100, height: model.value)
        }
    }
}
