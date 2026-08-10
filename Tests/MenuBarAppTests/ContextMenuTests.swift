import Testing
@testable import MenuBarApp

@MainActor
struct ContextMenuTests {
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
}
