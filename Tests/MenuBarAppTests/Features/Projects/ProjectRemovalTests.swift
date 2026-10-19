import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

// What the app says before it takes a project out, and the order it takes it out in. Both
// are promises: the confirmation tells the reader which of their files survive, and the
// order decides whether a session can outlive the project it belongs to.
@MainActor
struct ProjectRemovalTests {
    private let testPreferences = TestPreferences()
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let shortcuts: ShortcutStore

    init() {
        (store, scratch) = TestStore.make()
        shortcuts = ShortcutStore(storageURL: scratch.path("shortcuts.json"),
                                  siteDefaults: SiteDefaults())
    }

    // MARK: - What the confirmation promises

    @Test func promisesThatAProjectFolderStaysOnDisk() throws {
        let project = try addProject(named: "checkout")

        let dialog = ProjectRemoval.confirmation(for: project, in: store) {}

        #expect(dialog.title == "Remove checkout?")
        #expect(dialog.impact?.rows.last?.title == "Original project folder stays")
        #expect(dialog.impact?.rows.last?.detail == project.collapsedPath)
        #expect(dialog.impact?.rows.last?.kept == true)
        #expect(dialog.actions.first?.label == "Remove project")
        #expect(dialog.actions.first?.kind == .destructive)
        #expect(dialog.actions.last?.kind == .cancel)
    }

    @Test func saysGeneratedDesignFilesGoWithTheProject() throws {
        let project = try addProject(named: "checkout")
        let design = store.newSession(in: project.id, seed: .init(mode: .design))
        let artifact = try #require(store.designArtifactURL(for: design))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>design</html>".utf8).write(to: artifact)

        let dialog = ProjectRemoval.confirmation(for: project, in: store) {}

        #expect(dialog.impact?.rows.contains {
            $0.title == "Generated Design files" && $0.detail == "Permanently removed from 1 session."
        } == true)
    }

    @Test func saysThatATaskFolderGoesWithTheTask() throws {
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: scratch.path("tasks")).get()

        let dialog = ProjectRemoval.confirmation(for: task, in: store) {}

        #expect(dialog.title == "Delete Sweep?")
        #expect(dialog.impact?.subject?.kind == .task)
        #expect(dialog.impact?.rows.last?.title == "Task folder")
        #expect(dialog.impact?.rows.last?.kept == false)
        #expect(dialog.impact?.warning != nil)
        #expect(dialog.actions.first?.label == "Delete task")
    }

    // A task counts runs where a project counts sessions, so it has its own singular to
    // get wrong.
    @Test func countsTheRunsThatWouldGoInWords() throws {
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: scratch.path("tasks")).get()
        #expect(ProjectRemoval.confirmation(for: task, in: store) {}
            .impact?.rows.first?.title == "0 runs")

        _ = store.newSession(in: task.id)
        #expect(ProjectRemoval.confirmation(for: task, in: store) {}
            .impact?.rows.first?.title == "1 run")

        _ = store.newSession(in: task.id)
        #expect(ProjectRemoval.confirmation(for: task, in: store) {}
            .impact?.rows.first?.title == "2 runs")
    }

    // A count that reads "1 sessions" is the kind of thing that survives a rewrite in one
    // caller and not another, which is the whole reason this wording has a single home.
    @Test func countsTheSessionsThatWouldGoInWords() throws {
        let project = try addProject(named: "checkout")
        #expect(ProjectRemoval.confirmation(for: project, in: store) {}
            .impact?.rows.first?.title == "0 sessions and 0 worktrees")

        _ = try store.insertSession(in: project.id).get()
        #expect(ProjectRemoval.confirmation(for: project, in: store) {}
            .impact?.rows.first?.title == "1 session and 0 worktrees")

        _ = try store.insertSession(in: project.id).get()
        #expect(ProjectRemoval.confirmation(for: project, in: store) {}
            .impact?.rows.first?.title == "2 sessions and 0 worktrees")
    }

    // A workspace session dies with any one of its repositories, so it counts against
    // every project it has a checkout in rather than only the one it calls home.
    @Test func countsWorkspaceSessionsAgainstEveryProjectTheyCheckOut() throws {
        let first = try addProject(named: "first")
        let second = try addProject(named: "second")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))
        _ = try store.insertSession(
            in: workspace.id,
            projects: [SessionProject(projectID: first.id, worktreePath: nil,
                                      worktreeBranch: nil),
                       SessionProject(projectID: second.id, worktreePath: nil,
                                      worktreeBranch: nil)]).get()

        #expect(ProjectRemoval.confirmation(for: second, in: store) {}
            .impact?.rows.first?.title == "1 session and 0 worktrees")
    }

    @Test func summaryCountsWorktreesAcrossRepositoriesAndOnlyOwnedShortcuts() throws {
        let first = try addProject(named: "first")
        let second = try addProject(named: "second")
        let workspace = try #require(store.addWorkspace(name: "Checkout",
                                                        projectIDs: [first.id, second.id],
                                                        leadProjectID: first.id))
        _ = try store.insertSession(in: workspace.id, projects: [
            SessionProject(projectID: first.id, worktreePath: "/worktrees/first", worktreeBranch: "topic"),
            SessionProject(projectID: second.id, worktreePath: "/worktrees/second", worktreeBranch: "topic")
        ]).get()
        shortcuts.add(name: "Build", text: "make", projectID: first.id)
        shortcuts.add(name: "Other", text: "make", projectID: second.id)

        let dialog = ProjectRemoval.confirmation(for: first, in: store, shortcuts: shortcuts) {}

        #expect(dialog.impact?.rows.first?.title == "1 session and 2 worktrees")
        #expect(dialog.impact?.rows.contains { $0.title == "1 saved shortcut" } == true)
        #expect(dialog.impact?.rows.contains { $0.title == "Generated Design files" } == false)
        #expect(dialog.impact?.warning == "Session history cannot be restored.")
    }

    @Test func emptyProjectHasNoHistoryWarning() throws {
        let project = try addProject(named: "empty")
        let dialog = ProjectRemoval.confirmation(for: project, in: store, shortcuts: shortcuts) {}
        #expect(dialog.impact?.warning == nil)
        #expect(dialog.impact?.rows.count == 2)
    }

    // MARK: - The order the work happens in

    @Test func takesTheSessionsBeforeTheProject() async throws {
        let store = store
        let project = try addProject(named: "checkout")
        let projectID = project.id
        let session = store.newSession(in: project.id,
                                       worktreePath: "/worktrees/checkout",
                                       worktreeBranch: "code-station/test")
        // Read while the checkout is being torn down: the project has to still be there,
        // because a session removal that fails must find its project intact.
        let projectWasPresent = Sealed()
        let worktrees = removal { @MainActor in
            await projectWasPresent.seal(store.project(projectID) != nil)
            return .success(())
        }

        let result = await ProjectRemoval.run(project, in: store, runner: SessionRunner(preferences: testPreferences.store),
                                              worktrees: worktrees,
                                              removeOwned: { shortcuts.removeAll(ownedBy: $0) })

        #expect(throwsNothing(result))
        #expect(await projectWasPresent.value() == true)
        #expect(store.project(project.id) == nil)
        #expect(store.session(session.id) == nil)
    }

    @Test func removesAProjectThatHasNoSessionsAtAll() async throws {
        let project = try addProject(named: "checkout")

        let result = await ProjectRemoval.run(project, in: store, runner: SessionRunner(preferences: testPreferences.store),
                                              worktrees: removal { .success(()) },
                                              removeOwned: { shortcuts.removeAll(ownedBy: $0) })

        #expect(throwsNothing(result))
        #expect(store.projects.isEmpty)
    }

    // Nothing else can reach a shortcut whose project has gone, since a folder added
    // again comes back as a new project.
    @Test func takesTheProjectsSavedCommandsWithIt() async throws {
        let project = try addProject(named: "checkout")
        let other = try addProject(named: "elsewhere")
        shortcuts.add(name: "Lint", text: "npm run lint", projectID: project.id)
        shortcuts.add(name: "Build", text: "make", projectID: other.id)
        shortcuts.add(name: "Prune", text: "docker system prune")

        let result = await ProjectRemoval.run(project, in: store, runner: SessionRunner(preferences: testPreferences.store),
                                              worktrees: removal { .success(()) },
                                              removeOwned: { shortcuts.removeAll(ownedBy: $0) })

        #expect(throwsNothing(result))
        #expect(shortcuts.shortcuts(for: project.id).isEmpty)
        #expect(shortcuts.shortcuts.map(\.name) == ["Build", "Prune"])
    }

    // MARK: - When a session refuses to go

    // A checkout that will not go leaves the project standing. The session itself is
    // already journaled for another attempt at launch, so what the reader is left with is
    // a project they can remove again once the retry has cleared the checkout.
    @Test func keepsTheProjectWhenASessionCannotBeRemoved() async throws {
        let project = try addProject(named: "checkout")
        let session = store.newSession(in: project.id,
                                       worktreePath: "/worktrees/checkout",
                                       worktreeBranch: "code-station/test")
        let worktrees = removal { .failure(GitWorktree.Failure(message: "Worktree is busy")) }

        let result = await ProjectRemoval.run(project, in: store, runner: SessionRunner(preferences: testPreferences.store),
                                              worktrees: worktrees,
                                              removeOwned: { shortcuts.removeAll(ownedBy: $0) })

        guard case .failure(let failure) = result else {
            Issue.record("Expected the removal to fail")
            return
        }
        #expect(failure.title == "Could not delete the session")
        #expect(failure.message.contains("Worktree is busy"))
        #expect(store.project(project.id) != nil)
        #expect(store.pendingSessionRemovals.map(\.id) == [session.id])
    }

    @Test func gathersEveryReasonUnderOneHeadingWhenSeveralFail() async throws {
        let project = try addProject(named: "checkout")
        for index in 0..<2 {
            _ = store.newSession(in: project.id,
                                 worktreePath: "/worktrees/checkout-\(index)",
                                 worktreeBranch: "code-station/test-\(index)")
        }
        let worktrees = removal { .failure(GitWorktree.Failure(message: "Worktree is busy")) }

        let result = await ProjectRemoval.run(project, in: store, runner: SessionRunner(preferences: testPreferences.store),
                                              worktrees: worktrees,
                                              removeOwned: { shortcuts.removeAll(ownedBy: $0) })

        guard case .failure(let failure) = result else {
            Issue.record("Expected the removal to fail")
            return
        }
        #expect(failure.title == "Could not delete some sessions")
        #expect(failure.message.components(separatedBy: "Worktree is busy").count == 3)
        #expect(store.project(project.id) != nil)
    }

    // A task's sessions are runs, and the heading over their reasons says so.
    @Test func callsThemRunsWhenTheProjectIsATask() async throws {
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: scratch.path("tasks")).get()
        for index in 0..<2 {
            _ = store.newSession(in: task.id,
                                 worktreePath: "/worktrees/sweep-\(index)",
                                 worktreeBranch: "code-station/test-\(index)")
        }
        let worktrees = removal { .failure(GitWorktree.Failure(message: "Worktree is busy")) }

        let result = await ProjectRemoval.run(task, in: store, runner: SessionRunner(preferences: testPreferences.store),
                                              worktrees: worktrees,
                                              removeOwned: { shortcuts.removeAll(ownedBy: $0) })

        guard case .failure(let failure) = result else {
            Issue.record("Expected the removal to fail")
            return
        }
        #expect(failure.title == "Could not delete some runs")
    }

    // MARK: - The one call every button makes

    @Test func asksBeforeItTakesAnythingOut() throws {
        let project = try addProject(named: "checkout")
        let dialogs = DialogPresenter()

        ProjectRemoval.confirm(project, in: store, runner: SessionRunner(preferences: testPreferences.store),
                               shortcuts: shortcuts, dialogs: dialogs,
                               worktrees: removal { .success(()) })

        #expect(dialogs.current?.title == "Remove checkout?")
        #expect(store.project(project.id) != nil)
    }

    @Test func takesTheProjectOutOnceTheQuestionIsAnswered() async throws {
        let project = try addProject(named: "checkout")
        let session = store.newSession(in: project.id,
                                       worktreePath: "/worktrees/checkout",
                                       worktreeBranch: "code-station/test")
        let dialogs = DialogPresenter()
        ProjectRemoval.confirm(project, in: store, runner: SessionRunner(preferences: testPreferences.store),
                               shortcuts: shortcuts, dialogs: dialogs,
                               worktrees: removal { .success(()) })

        dialogs.run(try #require(dialogs.current?.actions.first))

        #expect(await waitUntil(timeout: waitBudget) { store.project(project.id) == nil })
        #expect(store.session(session.id) == nil)
        #expect(dialogs.current?.title == nil)
    }

    // The reason the whole removal is one call: a caller that wired the question to the
    // work itself could leave a failure unreported, and the button would look like it did
    // nothing at all.
    @Test func reportsAFailureWithoutTheCallerHavingTo() async throws {
        let project = try addProject(named: "checkout")
        _ = store.newSession(in: project.id,
                             worktreePath: "/worktrees/checkout",
                             worktreeBranch: "code-station/test")
        let dialogs = DialogPresenter()
        ProjectRemoval.confirm(
            project, in: store, runner: SessionRunner(preferences: testPreferences.store), shortcuts: shortcuts,
            dialogs: dialogs, worktrees: removal { .failure(GitWorktree.Failure(message: "Worktree is busy")) })

        dialogs.run(try #require(dialogs.current?.actions.first))

        #expect(await waitUntil(timeout: waitBudget) {
            dialogs.current?.title == "Could not delete the session"
        })
        #expect(dialogs.current?.message?.contains("Worktree is busy") == true)
        #expect(store.project(project.id) != nil)
    }

    @Test func leavesTheProjectAloneWhenTheQuestionIsRefused() throws {
        let project = try addProject(named: "checkout")
        let dialogs = DialogPresenter()
        ProjectRemoval.confirm(project, in: store, runner: SessionRunner(preferences: testPreferences.store),
                               shortcuts: shortcuts, dialogs: dialogs,
                               worktrees: removal { .success(()) })

        dialogs.run(try #require(dialogs.current?.actions.last))

        #expect(store.project(project.id) != nil)
        #expect(dialogs.current?.title == nil)
    }

    // MARK: - Helpers

    // The wait shares the main actor with every other test in the run, so the time it
    // actually gets to poll in is a fraction of the wall clock. Twenty to match
    // WorkingTreeWatchTests, which waits the same way for the same reason: a passing run
    // never spends the budget, and a tighter one fails whenever the suite grows rather than
    // when the removal breaks.
    private let waitBudget: Duration = .seconds(20)

    // The confirmation names the project after its folder, so the folder has to carry the
    // exact name the test expects to read back.
    private func addProject(named name: String) throws -> Project {
        let folder = scratch.path(UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(store.addProject(at: folder))
    }

    private func removal(
        _ remove: @escaping @Sendable () async -> Result<Void, GitWorktree.Failure>
    ) -> WorktreeOperations {
        WorktreeOperations(
            addProject: { _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected add"))
            },
            addWorkspaceProject: { _, _, _, _, _ in
                .failure(GitWorktree.Failure(message: "Unexpected add"))
            },
            remove: { _, _, _ in await remove() })
    }

    private func throwsNothing(_ result: Result<Void, SessionLifecycle.Failure>) -> Bool {
        if case .failure(let failure) = result {
            Issue.record("Expected the removal to succeed: \(failure.message)")
            return false
        }
        return true
    }
}

// One answer read from inside a faked operation and checked once it has run.
private actor Sealed {
    private var sealed: Bool?

    func seal(_ value: Bool) {
        guard sealed == nil else { return }
        sealed = value
    }

    func value() -> Bool? { sealed }
}
