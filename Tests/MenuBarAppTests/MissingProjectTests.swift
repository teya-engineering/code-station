import Foundation
import Testing
@testable import MenuBarApp

// A project whose folder has been moved or deleted. The app cannot start a session in one,
// so the only thing left to do with it is take it out of the list - which has to work when
// the folder is already gone, and has to leave the pane that was showing it somewhere valid.
@MainActor
struct MissingProjectTests {

    private func makeStore(root: URL) -> ProjectStore {
        ProjectStore(storeURL: root.appendingPathComponent("projects.json"))
    }

    private func makeFolder(in root: URL, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("code-station-missing-project-tests-\(UUID().uuidString)")
    }

    @Test func reportsAProjectAsMissingOnceItsFolderIsGone() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let folder = try makeFolder(in: root, named: "repo")
        let project = try #require(store.addProject(at: folder))
        #expect(!store.isMissing(project))

        try FileManager.default.removeItem(at: folder)

        #expect(store.isMissing(project))
    }

    // A regular file at the configured path is unusable because an agent needs a directory.
    @Test func reportsAProjectAsMissingWhenAFileTookItsPlace() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let folder = try makeFolder(in: root, named: "repo")
        let project = try #require(store.addProject(at: folder))

        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)

        #expect(store.isMissing(project))
    }

    // A missing project remains removable after all its sessions have been cleared.
    @Test func removesAMissingProjectThatHasNoSessionsLeft() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let folder = try makeFolder(in: root, named: "repo")
        let project = try #require(store.addProject(at: folder))
        try FileManager.default.removeItem(at: folder)

        store.removeProject(project.id)

        #expect(store.project(project.id) == nil)
        #expect(store.projects.isEmpty)
        #expect(store.saveError == nil)
        // The removal has to survive a relaunch, or the project comes back on the next start.
        #expect(makeStore(root: root).project(project.id) == nil)
    }

    @Test func removingAMissingProjectDropsTheSessionsThatRanInIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let folder = try makeFolder(in: root, named: "repo")
        let project = try #require(store.addProject(at: folder))
        let session = try store.insertSession(in: project.id).get()
        try FileManager.default.removeItem(at: folder)

        store.removeProject(project.id)

        #expect(store.project(project.id) == nil)
        #expect(store.session(session.id) == nil)
        #expect(store.standaloneSessions(for: project.id).isEmpty)
    }

    // What the confirmation promises: the folder was the user's before the app knew about
    // it, so removing the project is only ever about the app's own list.
    @Test func removingAProjectLeavesItsFolderOnDisk() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let folder = try makeFolder(in: root, named: "repo")
        let project = try #require(store.addProject(at: folder))

        store.removeProject(project.id)

        #expect(store.project(project.id) == nil)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // The button lives in the pane showing the project it removes, so the selection cannot
    // stay on it: it moves to whatever else is in the list.
    @Test func removingTheSelectedProjectMovesTheSelectionToAnother() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let kept = try #require(store.addProject(at: try makeFolder(in: root, named: "kept")))
        let folder = try makeFolder(in: root, named: "gone")
        let missing = try #require(store.addProject(at: folder))
        store.selectProject(missing.id)
        try FileManager.default.removeItem(at: folder)

        store.removeProject(missing.id)

        #expect(store.selectedProjectID == kept.id)
    }

    @Test func clearsTheSelectionWhenTheLastProjectIsRemoved() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let folder = try makeFolder(in: root, named: "only")
        let project = try #require(store.addProject(at: folder))
        store.selectProject(project.id)
        try FileManager.default.removeItem(at: folder)

        store.removeProject(project.id)

        #expect(store.selectedProjectID == nil)
    }

    // A task owns its folder, so deleting it normally takes the folder too. One that has
    // already been deleted underneath the app must not stop the task from going.
    @Test func deletesATaskWhoseFolderIsAlreadyGone() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: root.appendingPathComponent("tasks")).get()
        try FileManager.default.removeItem(at: task.url)
        #expect(store.isMissing(task))

        store.removeProject(task.id)

        #expect(store.project(task.id) == nil)
        #expect(makeStore(root: root).project(task.id) == nil)
    }
}
