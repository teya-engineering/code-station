import Foundation
import Testing
@testable import MenuBarApp

// Acting on several sidebar rows at once: which projects a snooze reaches, what the delete
// dialog promises, and that the delete takes everything it named.
@MainActor
struct SidebarBulkActionTests {
    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let shortcuts: ShortcutStore

    init() {
        (store, scratch) = TestStore.make()
        shortcuts = ShortcutStore(storageURL: scratch.path("shortcuts.json"),
                                  siteDefaults: SiteDefaults())
    }

    // MARK: - Selecting

    // The press that opens the selection ends in a click on the same row. Taking that
    // click as a toggle would untick the row the user just held.
    @Test func theClickThatEndsAHoldDoesNotUntickTheRow() {
        let selection = SidebarMultiSelection()
        let id = UUID()

        selection.hold(id)
        selection.click(id)

        #expect(selection.contains(id))
    }

    @Test func untickingTheLastRowClosesTheSelection() {
        let selection = SidebarMultiSelection()
        let id = UUID()

        selection.add(id)
        selection.click(id)

        #expect(!selection.isActive)
    }

    @Test func rowsThatLeaveTheSidebarLeaveTheSelection() {
        let selection = SidebarMultiSelection()
        let kept = UUID()
        selection.add(kept)
        selection.add(UUID())

        selection.keep { $0 == kept }

        #expect(selection.ids == [kept])
    }

    // MARK: - Snoozing

    @Test func aSessionSnoozesTheProjectItLivesIn() throws {
        let api = try addProject(named: "api")
        _ = try addProject(named: "web")
        let session = store.newSession(in: api.id)

        let targets = SidebarBulkAction.targets([session.id], in: store)

        #expect(SidebarBulkAction.snoozeProjects(targets, in: store).map(\.id) == [api.id])
    }

    @Test func sessionsInOneProjectSnoozeItOnce() throws {
        let api = try addProject(named: "api")
        let first = store.newSession(in: api.id)
        let second = store.newSession(in: api.id)

        let targets = SidebarBulkAction.targets([api.id, first.id, second.id], in: store)
        let menu = SidebarBulkAction.snoozeMenu(targets, in: store)
        guard case .item(let snooze) = menu.first else {
            Issue.record("Expected a snooze item")
            return
        }
        snooze.handler?()

        let deadline = try #require(store.project(api.id)?.snoozedUntil)
        #expect(ProjectSnooze.remainingDays(until: deadline) == 1)
    }

    @Test func aWorkspaceSnoozesItsLeadProject() throws {
        let api = try addProject(named: "api")
        let web = try addProject(named: "web")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [api.id, web.id],
                                                        leadProjectID: web.id))

        let targets = SidebarBulkAction.targets([workspace.id], in: store)

        #expect(SidebarBulkAction.snoozeProjects(targets, in: store).map(\.id) == [web.id])
    }

    @Test func offersToWakeOnlyWhatIsSnoozed() throws {
        let api = try addProject(named: "api")
        let web = try addProject(named: "web")
        store.snoozeCleanup(forProject: web.id)

        let menu = SidebarBulkAction.snoozeMenu(
            SidebarBulkAction.targets([api.id, web.id], in: store), in: store)

        #expect(menu.count == 2)
        guard case .item(let wake) = menu.last else {
            Issue.record("Expected a wake item")
            return
        }
        #expect(wake.label == "Wake now")
        #expect(wake.subtitle == "web")
    }

    // MARK: - What the delete promises

    @Test func namesWhatWasPickedInTheTitle() throws {
        let api = try addProject(named: "api")
        let web = try addProject(named: "web")
        let first = store.newSession(in: web.id)
        let second = store.newSession(in: web.id)

        let targets = SidebarBulkAction.targets([api.id, first.id, second.id], in: store)
        let dialog = SidebarBulkAction.confirmation(for: targets, in: store, shortcuts: shortcuts,
                                                    workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.title == "Delete 2 sessions and 1 project?")
        #expect(dialog.actions.first?.kind == .destructive)
    }

    // A session inside a picked project goes with it, so it is counted once.
    @Test func countsEachSessionOnceEvenWhenItsProjectIsPickedToo() throws {
        let api = try addProject(named: "api")
        let session = store.newSession(in: api.id, worktreePath: "/worktrees/api",
                                       worktreeBranch: "topic")
        _ = store.newSession(in: api.id)

        let targets = SidebarBulkAction.targets([api.id, session.id], in: store)
        let dialog = SidebarBulkAction.confirmation(for: targets, in: store, shortcuts: shortcuts,
                                                    workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.impact?.rows.first?.title == "2 sessions and 1 worktree")
        #expect(dialog.impact?.rows.last?.title == "Project folders stay")
        #expect(dialog.impact?.rows.last?.kept == true)
        #expect(dialog.impact?.warning == "Conversation history cannot be restored.")
    }

    @Test func showsTheProjectWhenEverySessionIsFromIt() throws {
        let api = try addProject(named: "api")
        let first = store.newSession(in: api.id)
        let second = store.newSession(in: api.id)

        let targets = SidebarBulkAction.targets([first.id, second.id], in: store)
        let dialog = SidebarBulkAction.confirmation(for: targets, in: store, shortcuts: shortcuts,
                                                    workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.impact?.subject?.name == "api")
    }

    @Test func countsTheSavedCommandsOfPickedProjects() throws {
        let api = try addProject(named: "api")
        let web = try addProject(named: "web")
        shortcuts.add(name: "Lint", text: "npm run lint", projectID: api.id)
        shortcuts.add(name: "Build", text: "make", projectID: web.id)

        let targets = SidebarBulkAction.targets([api.id], in: store)
        let dialog = SidebarBulkAction.confirmation(for: targets, in: store, shortcuts: shortcuts,
                                                    workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.impact?.rows.contains { $0.title == "1 saved shortcut" } == true)
    }

    // MARK: - The delete itself

    @Test func takesEverythingThatWasPicked() async throws {
        let api = try addProject(named: "api")
        let web = try addProject(named: "web")
        let docs = try addProject(named: "docs")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [web.id, docs.id],
                                                        leadProjectID: web.id))
        let inWorkspace = try store.insertSession(in: workspace.id, projects: [
            SessionProject(projectID: web.id, worktreePath: nil, worktreeBranch: nil),
            SessionProject(projectID: docs.id, worktreePath: nil, worktreeBranch: nil)
        ]).get()
        let loose = store.newSession(in: docs.id)
        let stays = store.newSession(in: docs.id)

        let targets = SidebarBulkAction.targets([api.id, workspace.id, loose.id], in: store)
        let result = await SidebarBulkAction.run(
            targets, in: store, runner: SessionRunner(store: store, preferences: testPreferences.store),
            shortcuts: shortcuts)

        guard case .success = result else {
            Issue.record("Expected the delete to succeed")
            return
        }
        #expect(store.project(api.id) == nil)
        #expect(store.workspace(workspace.id) == nil)
        #expect(store.session(inWorkspace.id) == nil)
        #expect(store.session(loose.id) == nil)
        #expect(store.session(stays.id) != nil)
        #expect(store.project(web.id) != nil)
    }

    // MARK: - Helpers

    private func addProject(named name: String) throws -> Project {
        let folder = scratch.path(UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(store.addProject(at: folder))
    }
}
