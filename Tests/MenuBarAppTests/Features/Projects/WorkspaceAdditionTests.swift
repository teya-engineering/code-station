import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct WorkspaceAdditionTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory

    init() {
        (store, scratch) = TestStore.make()
    }

    private func gitProject(named name: String) throws -> Project {
        let project = try TestStore.project(in: store, named: name)
        try FileManager.default.createDirectory(atPath: project.path + "/.git",
                                                withIntermediateDirectories: true)
        return project
    }

    private func workspace(_ ids: [UUID], worktrees: [UUID]) throws -> ProjectWorkspace {
        let workspace = try #require(store.addWorkspace(name: "Payments", projectIDs: ids,
                                                        leadProjectID: ids[0]))
        for id in ids {
            store.setUsesWorktree(worktrees.contains(id), for: id, inWorkspace: workspace.id)
        }
        return try #require(store.workspace(workspace.id))
    }

    @Test func undoRestoresTheProjectsAndCheckoutChoicesExactly() throws {
        let api = try gitProject(named: "api")
        let web = try gitProject(named: "web")
        let billing = try gitProject(named: "billing")
        let original = try workspace([api.id, web.id], worktrees: [web.id])

        let before = try #require(WorkspaceAddition.add(billing.id, to: original.id, store: store))
        #expect(store.workspace(original.id)?.projectIDs == [api.id, web.id, billing.id])
        #expect(store.workspace(original.id)?.worktreeProjectIDs == [web.id, billing.id])

        // A choice made in the receipt is taken back along with the add.
        store.setUsesWorktree(false, for: billing.id, inWorkspace: original.id)
        store.undoAddProject(billing.id, toWorkspace: before)

        let restored = try #require(store.workspace(original.id))
        #expect(restored.projectIDs == original.projectIDs)
        #expect(restored.worktreeProjectIDs == original.worktreeProjectIDs)
        #expect(restored.leadProjectID == original.leadProjectID)
    }

    @Test func addingAProjectTheWorkspaceHoldsChangesNothing() throws {
        let api = try gitProject(named: "api")
        let web = try gitProject(named: "web")
        let original = try workspace([api.id, web.id], worktrees: [])

        #expect(WorkspaceAddition.add(web.id, to: original.id, store: store) == nil)
        #expect(store.workspace(original.id) == original)
    }

    @Test func theReceiptSaysWhatWasAddedAndWhatStays() throws {
        let api = try gitProject(named: "api")
        let web = try gitProject(named: "web")
        let billing = try gitProject(named: "billing")
        let original = try workspace([api.id, web.id], worktrees: [])
        let before = try #require(WorkspaceAddition.add(billing.id, to: original.id, store: store))

        let dialog = try #require(WorkspaceAddition.receipt(for: billing.id, before: before, store: store,
                                                            onUndo: {}, onOpen: {}))
        let receipt = try #require(dialog.receipt)

        #expect(dialog.title == "Project added")
        #expect(dialog.message?.hasPrefix(billing.name) == true)
        #expect(dialog.message?.hasSuffix("is now part of Payments.") == true)
        #expect(receipt.members.map(\.name) == [api.name, web.name])
        #expect(receipt.added.name == billing.name)
        #expect(receipt.rows.map(\.added) == [true, false, false])
        #expect(receipt.rows[1].title == "Nothing else changes")
        #expect(dialog.actions.map(\.label) == ["Undo", "Open workspace", "Done"])
        #expect(dialog.actions.last?.kind == .primary)
        #expect(receipt.choice?.offReason == nil)
        #expect(receipt.choice?.selected == 0)
    }

    @Test func theCheckoutChoiceInTheReceiptIsSaved() throws {
        let api = try gitProject(named: "api")
        let web = try gitProject(named: "web")
        let billing = try gitProject(named: "billing")
        let original = try workspace([api.id, web.id], worktrees: [])
        let before = try #require(WorkspaceAddition.add(billing.id, to: original.id, store: store))
        let dialog = try #require(WorkspaceAddition.receipt(for: billing.id, before: before, store: store,
                                                            onUndo: {}, onOpen: nil))

        dialog.receipt?.choice?.choose(1)
        #expect(store.workspace(original.id)?.worktreeProjectIDs.contains(billing.id) == false)
        dialog.receipt?.choice?.choose(0)
        #expect(store.workspace(original.id)?.worktreeProjectIDs.contains(billing.id) == true)
    }

    @Test func aFolderThatIsNotARepositoryHasNoCheckoutChoice() throws {
        let api = try gitProject(named: "api")
        let web = try gitProject(named: "web")
        let notes = try TestStore.project(in: store, named: "notes")
        let original = try workspace([api.id, web.id], worktrees: [])
        let before = try #require(WorkspaceAddition.add(notes.id, to: original.id, store: store))

        let dialog = try #require(WorkspaceAddition.receipt(for: notes.id, before: before, store: store,
                                                            onUndo: {}, onOpen: nil))

        #expect(dialog.receipt?.choice?.offReason != nil)
        #expect(dialog.receipt?.choice?.selected == 1)
        // The workspace page is already open, so there is nowhere to go.
        #expect(dialog.actions.map(\.label) == ["Undo", "Done"])
    }

    @Test func undoFromTheReceiptTakesTheAddBack() throws {
        let api = try gitProject(named: "api")
        let web = try gitProject(named: "web")
        let billing = try gitProject(named: "billing")
        let original = try workspace([api.id, web.id], worktrees: [api.id])
        let before = try #require(WorkspaceAddition.add(billing.id, to: original.id, store: store))
        var undone = false
        let dialog = try #require(WorkspaceAddition.receipt(for: billing.id, before: before, store: store,
                                                            onUndo: { undone = true }, onOpen: nil))

        try #require(dialog.actions.first { $0.label == "Undo" }).handler()

        #expect(undone)
        #expect(store.workspace(original.id)?.projectIDs == original.projectIDs)
        #expect(store.workspace(original.id)?.worktreeProjectIDs == original.worktreeProjectIDs)
    }

    @Test func theReceiptCountsTheSessionsThatKeepTheirProjects() throws {
        let api = try gitProject(named: "api")
        let web = try gitProject(named: "web")
        let billing = try gitProject(named: "billing")
        let original = try workspace([api.id, web.id], worktrees: [])
        _ = try #require(store.newSession(in: original.id,
                                          projects: [SessionProject(projectID: api.id),
                                                     SessionProject(projectID: web.id)]))
        let before = try #require(WorkspaceAddition.add(billing.id, to: original.id, store: store))

        let dialog = try #require(WorkspaceAddition.receipt(for: billing.id, before: before, store: store,
                                                            onUndo: {}, onOpen: nil))

        #expect(dialog.receipt?.rows[1].title == "Open sessions stay as they are")
        #expect(dialog.receipt?.rows[1].detail == "1 session keeps the projects it started with.")
    }
}
