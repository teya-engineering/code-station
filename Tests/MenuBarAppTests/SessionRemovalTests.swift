import Foundation
import Testing
@testable import MenuBarApp

// What the app says before it deletes a session. The action is offered from the sidebar
// and from every detail pane, and the confirmation is the only place the reader is told
// what goes with it, so each promise is measured here rather than trusted to the screen
// that happens to be open.
@MainActor
struct SessionRemovalTests {
    private let store: ProjectStore
    private let scratch: ScratchDirectory
    private let project: Project

    init() throws {
        (store, scratch) = TestStore.make()
        project = try TestStore.project(in: store, named: "checkout")
    }

    @Test func namesTheSessionAndKeepsTheDeletionDestructive() {
        let session = store.newSession(in: project.id)
        store.renameSession(session.id, to: "Fix the parser")

        let dialog = SessionRemoval.confirmation(for: store.session(session.id)!, in: store,
                                                 workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.title == "Delete this session?")
        #expect(dialog.message == "Fix the parser")
        #expect(dialog.width == 420)
        #expect(dialog.impact?.compact == true)
        #expect(dialog.impact?.subject?.name == project.name)
        #expect(dialog.impact?.rows.first?.title == "Conversation history")
        #expect(dialog.impact?.rows.last?.title == "Project folder stays")
        #expect(dialog.impact?.rows.last?.detail == project.collapsedPath)
        #expect(dialog.impact?.rows.last?.kept == true)
        #expect(dialog.actions.first?.label == "Delete session")
        #expect(dialog.actions.first?.kind == .destructive)
        #expect(dialog.actions.last?.kind == .cancel)
    }

    // The reason this lives in one place: three of the four screens that offer the
    // deletion used to leave this out while deleting the files anyway.
    @Test func saysGeneratedDesignFilesAreRemoved() throws {
        let session = store.newSession(in: project.id, seed: .init(mode: .design))
        let artifact = try #require(store.designArtifactURL(for: session))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>design</html>".utf8).write(to: artifact)

        let dialog = SessionRemoval.confirmation(for: session, in: store,
                                                 workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.impact?.rows.contains {
            $0.title == "Generated Design files" && !$0.kept
        } == true)
        #expect(dialog.actions.first?.label == "Delete session and Design files")
    }

    @Test func countsTheWorktreesThatGoWithIt() {
        let session = store.newSession(in: project.id, worktreePath: "/tmp/one",
                                       worktreeBranch: "session/one")

        let dialog = SessionRemoval.confirmation(for: session, in: store,
                                                 workingTrees: WorkingTreeWatch()) {}

        let row = dialog.impact?.rows.first { $0.title == "1 worktree" }
        #expect(row?.detail == "Removed from disk. Branches are kept if they have unmerged commits.")
        #expect(dialog.impact?.rows.contains { $0.title == "Project folder stays" } == false)
        #expect(dialog.actions.first?.label == "Delete session and worktrees")
    }

    @Test func warnsThatUncommittedWorkInAWorktreeIsLost() async {
        let session = store.newSession(in: project.id, worktreePath: "/tmp/dirty",
                                       worktreeBranch: "session/dirty")
        let workingTrees = WorkingTreeWatch(inspect: { _ in 3 })
        workingTrees.refresh(["/tmp/dirty"])
        #expect(await waitUntil { workingTrees.isDirty("/tmp/dirty") })

        let dialog = SessionRemoval.confirmation(for: session, in: store,
                                                 workingTrees: workingTrees) {}

        let row = dialog.impact?.rows.first { $0.title == "1 worktree" }
        #expect(row?.detail == "Removed from disk. 1 has uncommitted changes that will be lost.")
        #expect(dialog.impact?.warning?.contains("Uncommitted changes") == true)
    }

    // A run writes into the task's own folder, which outlives the run, so the deletion
    // has to say the files stay rather than leaving the reader to guess.
    @Test func promisesThatFilesInTheTaskFolderStay() throws {
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: scratch.path("tasks")).get()
        let run = store.newSession(in: task.id)

        let dialog = SessionRemoval.confirmation(for: run, in: store,
                                                 workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.impact?.subject?.kind == .task)
        #expect(dialog.impact?.rows.last?.title == "Task folder stays")
        #expect(dialog.impact?.rows.last?.kept == true)
        #expect(dialog.actions.first?.label == "Delete run")
    }
}
