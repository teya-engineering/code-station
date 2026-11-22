import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct SidebarCarryTests {
    // Waits are recorded and skipped, so a test reads the order of the steps without
    // sitting through them.
    private final class Waits {
        var asked: [Duration] = []
    }

    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let dialogs = DialogPresenter()
    private let note = TransientNote()
    private let waits = Waits()
    private let carry: SidebarCarry

    init() {
        (store, scratch) = TestStore.make()
        carry = SidebarCarry(sleep: { [waits] in waits.asked.append($0) })
    }

    private func surroundings(
        proposeWorkspace: @escaping ([UUID], String) -> Void = { _, _ in }
    ) -> SidebarCarry.Surroundings {
        SidebarCarry.Surroundings(store: store, dialogs: dialogs, note: note,
                                  openWorkspace: { _ in }, proposeWorkspace: proposeWorkspace)
    }

    private func workspace(of ids: [UUID]) throws -> ProjectWorkspace {
        try #require(store.addWorkspace(name: "Payments", projectIDs: ids, leadProjectID: ids[0]))
    }

    // Lets the steps that follow a wait run.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func action(_ label: String) throws -> Dialog.Action {
        try #require(dialogs.current?.actions.first { $0.label == label })
    }

    @Test func aDropOnAWorkspaceFliesLandsShowsItsReceiptAndIsPutAway() async throws {
        let api = try TestStore.project(in: store, named: "api")
        let web = try TestStore.project(in: store, named: "web")
        let billing = try TestStore.project(in: store, named: "billing")
        let payments = try workspace(of: [api.id, web.id])
        let around = surroundings()

        carry.join(billing.id, payments, in: around)
        #expect(store.workspace(payments.id)?.projectIDs == [api.id, web.id, billing.id])
        #expect(carry.landing?.phase == .flying)
        let flight = try #require(carry.flight)
        #expect(flight.from == .chip)
        #expect(flight.to == .slot(payments.id))

        carry.flightLanded(flight, in: around)
        #expect(carry.flight == nil)
        #expect(carry.landing?.phase == .landed)
        #expect(store.navigation.sidebarHighlight == payments.id)
        #expect(dialogs.current == nil)

        await settle()
        #expect(waits.asked == [WorkspaceAddition.receiptDelay])
        #expect(dialogs.current?.receipt != nil)
        #expect(carry.landing?.phase == .landed)

        dialogs.run(try action("Done"))
        await settle()
        #expect(waits.asked == [WorkspaceAddition.receiptDelay, .milliseconds(1_300)])
        #expect(carry.landing == nil)
    }

    @Test func undoInTheReceiptFliesTheTileHome() async throws {
        let api = try TestStore.project(in: store, named: "api")
        let web = try TestStore.project(in: store, named: "web")
        let billing = try TestStore.project(in: store, named: "billing")
        let payments = try workspace(of: [api.id, web.id])
        let around = surroundings()

        carry.join(billing.id, payments, in: around)
        carry.flightLanded(try #require(carry.flight), in: around)
        await settle()

        dialogs.run(try action("Undo"))
        #expect(store.workspace(payments.id)?.projectIDs == [api.id, web.id])
        #expect(note.text == "Removed \(billing.name) from Payments")
        #expect(carry.landing?.phase == .leaving)
        let home = try #require(carry.flight)
        #expect(home.from == .anchor(.roster(payments.id, billing.id)))
        #expect(home.to == .tile(billing.id))
        #expect(home.duration == Motion.flightHomeDuration)

        carry.flightLanded(home, in: around)
        #expect(carry.flight == nil)
        #expect(carry.landing == nil)
    }

    @Test func aSecondDropLeavesTheFirstWithoutAReceipt() async throws {
        let api = try TestStore.project(in: store, named: "api")
        let web = try TestStore.project(in: store, named: "web")
        let billing = try TestStore.project(in: store, named: "billing")
        let docs = try TestStore.project(in: store, named: "docs")
        let payments = try workspace(of: [api.id, web.id])
        let around = surroundings()

        carry.join(billing.id, payments, in: around)
        carry.flightLanded(try #require(carry.flight), in: around)
        carry.join(docs.id, try #require(store.workspace(payments.id)), in: around)
        await settle()

        #expect(dialogs.current == nil)
        #expect(carry.landing?.projectID == docs.id)
        #expect(carry.landing?.phase == .flying)
        #expect(carry.flight?.to == .slot(payments.id))
    }

    @Test func anAddMadeAwayFromTheSidebarLandsInPlace() async throws {
        let api = try TestStore.project(in: store, named: "api")
        let web = try TestStore.project(in: store, named: "web")
        let billing = try TestStore.project(in: store, named: "billing")
        let payments = try workspace(of: [api.id, web.id])
        let before = try #require(WorkspaceAddition.add(billing.id, to: payments.id, store: store))

        carry.landInPlace(WorkspaceAddition.Added(projectID: billing.id, before: before),
                          in: surroundings())
        #expect(carry.flight == nil)
        #expect(carry.landing?.phase == .landed)
        #expect(store.navigation.sidebarHighlight == payments.id)

        await settle()
        #expect(waits.asked == [WorkspaceAddition.receiptDelay])
        #expect(dialogs.current?.receipt != nil)
    }

    @Test func aDropOnAProjectStacksTheTileThenAsksForAWorkspace() async throws {
        let api = try TestStore.project(in: store, named: "api")
        let web = try TestStore.project(in: store, named: "web")
        var proposed: (ids: [UUID], name: String)?
        let around = surroundings { proposed = ($0, $1) }

        carry.pair(web.id, with: api, in: around)
        #expect(carry.pairing == SidebarPairing(targetID: api.id, projectID: web.id, stacked: false))
        let flight = try #require(carry.flight)
        #expect(flight.landsBehind)
        #expect(flight.to == .tile(api.id))

        carry.flightLanded(flight, in: around)
        #expect(carry.pairing?.stacked == true)
        #expect(proposed == nil)

        await settle()
        #expect(waits.asked == [SidebarPairing.sheetDelay])
        #expect(proposed?.ids == [api.id, web.id])
        #expect(proposed?.name == "\(api.name) + \(web.name)")

        carry.endPairing()
        #expect(carry.pairing == nil)
    }

    @Test func aProjectLetGoOnNothingFliesHome() async throws {
        let api = try TestStore.project(in: store, named: "api")
        carry.drag.itemID = api.id

        carry.dragReleased(in: surroundings())
        #expect(carry.flight == nil)

        await settle()
        #expect(waits.asked == [.milliseconds(150)])
        #expect(carry.drag == SidebarDrag())
        #expect(carry.flight?.from == .chip)
        #expect(carry.flight?.to == .tile(api.id))
        #expect(carry.flight?.duration == Motion.flightHomeDuration)
    }
}
