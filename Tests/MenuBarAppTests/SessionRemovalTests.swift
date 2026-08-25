import Foundation
import Testing
@testable import MenuBarApp

// What the app says before it deletes a session. The action is offered from the sidebar
// and from every detail pane, and the confirmation is the only place the reader is told
// what goes with it, so each promise is measured here rather than trusted to the screen
// that happens to be open.
@MainActor
struct SessionRemovalTests {

    @Test func namesTheSessionAndKeepsTheDeletionDestructive() {
        let store = makeStore()
        let project = addProject(named: "checkout", to: store)
        let session = store.newSession(in: project.id)
        store.renameSession(session.id, to: "Fix the parser")

        let dialog = SessionRemoval.confirmation(for: store.session(session.id)!, in: store,
                                                 workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.title == "Delete \"Fix the parser\"?")
        #expect(dialog.message == "Its conversation history is removed from the app.")
        #expect(dialog.actions.first?.label == "Delete session")
        #expect(dialog.actions.first?.kind == .destructive)
        #expect(dialog.actions.last?.kind == .cancel)
    }

    // The reason this lives in one place: three of the four screens that offer the
    // deletion used to leave this out while deleting the files anyway.
    @Test func saysGeneratedDesignFilesAreRemoved() throws {
        let store = makeStore()
        let project = addProject(named: "checkout", to: store)
        let session = store.newSession(in: project.id, seed: .init(mode: .design))
        let artifact = try #require(store.designArtifactURL(for: session))
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html>design</html>".utf8).write(to: artifact)

        let dialog = SessionRemoval.confirmation(for: session, in: store,
                                                 workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.message?.contains(
            "Its generated Design files are permanently removed.") == true)
        #expect(dialog.actions.first?.label == "Delete session and Design files")
    }

    @Test func countsTheWorktreesThatGoWithIt() {
        let store = makeStore()
        let project = addProject(named: "checkout", to: store)
        let session = store.newSession(in: project.id, worktreePath: "/tmp/one",
                                       worktreeBranch: "session/one")

        let dialog = SessionRemoval.confirmation(for: session, in: store,
                                                 workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.message?.contains("Its 1 worktree goes with it.") == true)
        #expect(dialog.message?.contains("Branches are kept if they have unmerged commits.")
            == true)
        #expect(dialog.actions.first?.label == "Delete session and worktrees")
    }

    @Test func warnsThatUncommittedWorkInAWorktreeIsLost() async {
        let store = makeStore()
        let project = addProject(named: "checkout", to: store)
        let session = store.newSession(in: project.id, worktreePath: "/tmp/dirty",
                                       worktreeBranch: "session/dirty")
        let workingTrees = WorkingTreeWatch(inspect: { _ in 3 })
        workingTrees.refresh(["/tmp/dirty"])
        while !workingTrees.isDirty("/tmp/dirty") { await Task.yield() }

        let dialog = SessionRemoval.confirmation(for: session, in: store,
                                                 workingTrees: workingTrees) {}

        #expect(dialog.message?.contains("1 has uncommitted changes that will be lost.") == true)
        #expect(dialog.message?.contains("Branches are kept") == false)
    }

    // A run writes into the task's own folder, which outlives the run, so the deletion
    // has to say the files stay rather than leaving the reader to guess.
    @Test func promisesThatFilesInTheTaskFolderStay() throws {
        let store = makeStore()
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: temporaryDirectory()).get()
        let run = store.newSession(in: task.id)

        let dialog = SessionRemoval.confirmation(for: run, in: store,
                                                 workingTrees: WorkingTreeWatch()) {}

        #expect(dialog.message?.contains("Files it wrote in the task folder stay.") == true)
        #expect(dialog.actions.first?.label == "Delete run")
    }

    // MARK: - Helpers

    private func makeStore() -> ProjectStore {
        ProjectStore(storeURL: temporaryDirectory().appendingPathComponent("projects.json"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-session-removal-\(UUID().uuidString)")
    }

    private func addProject(named name: String, to store: ProjectStore) -> Project {
        store.addProject(at: temporaryDirectory().appendingPathComponent(name))!
    }
}
