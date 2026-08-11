import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct TaskTests {
    @Test func createsANamedTaskWithItsPromptInANewEmptyDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-task-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("projects.json")
        let tasksURL = root.appendingPathComponent("tasks", isDirectory: true)
        let store = ProjectStore(storeURL: storeURL)

        let project = try store.addTask(named: "  Release notes  ",
                                        prompt: "  Draft the release notes.  ",
                                        repeats: true,
                                        in: tasksURL).get()

        #expect(project.name == "Release notes")
        #expect(project.kind == .adHoc)
        #expect(project.task == TaskSpec(prompt: "Draft the release notes.", repeats: true))
        #expect(project.url.deletingLastPathComponent() == tasksURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        #expect(store.selectedProjectID == project.id)
        #expect(ProjectStore(storeURL: storeURL).project(project.id) == project)
    }

    @Test func rejectsATaskWithoutANameBeforeCreatingItsDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-task-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))

        let result = store.addTask(named: " \n ", prompt: "Do something", repeats: false,
                                   in: root.appendingPathComponent("tasks"))

        if case .success = result {
            Issue.record("A blank task name was accepted")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func decodesAnExistingAdHocDirectoryAsATaskWithoutAPrompt() throws {
        let id = UUID()
        let path = AppPaths.support
            .appendingPathComponent("ad-hoc-tasks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .path
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "name": "Existing task",
            "path": path
        ])

        let project = try JSONDecoder().decode(Project.self, from: data)

        #expect(project.kind == .adHoc)
        #expect(project.task == nil)
    }

    @Test func decodesAnExistingProjectAsANormalProject() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "name": "Payments API",
            "path": "/Development/payments-api"
        ])

        let project = try JSONDecoder().decode(Project.self, from: data)

        #expect(project.kind == .project)
        #expect(project.task == nil)
    }

    @Test func reworksThePromptAndModeBetweenRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-task-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("projects.json")
        let store = ProjectStore(storeURL: storeURL)
        let project = try store.addTask(named: "Sweep", prompt: "First idea", repeats: false,
                                        in: root.appendingPathComponent("tasks")).get()

        let reworked = TaskSpec(prompt: "Second idea", repeats: true)
        store.setTaskSpec(reworked, for: project.id)

        #expect(store.project(project.id)?.task == reworked)
        #expect(ProjectStore(storeURL: storeURL).project(project.id)?.task == reworked)
    }

    @Test func ignoresATaskSpecOnANormalProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-task-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"),
                                                withIntermediateDirectories: true)
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))
        let project = try #require(store.addProject(at: root.appendingPathComponent("repo")))

        store.setTaskSpec(TaskSpec(prompt: "Not a task", repeats: true), for: project.id)

        #expect(store.project(project.id)?.task == nil)
    }

    @Test func aOneOffRetiresAfterItsFirstRunWhileARepeatableDoesNot() {
        #expect(TaskRun.canRun(repeats: false, hasRun: false))
        #expect(!TaskRun.canRun(repeats: false, hasRun: true))
        #expect(TaskRun.canRun(repeats: true, hasRun: false))
        #expect(TaskRun.canRun(repeats: true, hasRun: true))
    }

    @Test func runningATaskStartsASessionWithTheSavedPrompt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-task-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.", repeats: true,
                                     in: root.appendingPathComponent("tasks")).get()
        // No executables: the run records its prompt but no process can start.
        let runner = SessionRunner(paths: [:])

        let session = try TaskRun.run(task, store: store, runner: runner,
                                      agentAvatarName: nil).get()

        #expect(session.projectID == task.id)
        let transcript = store.transcript(of: session.id)
        #expect(transcript.contains { $0.role == .user && $0.text == "Do the thing." })
        #expect(TaskRun.hasRun(task, store: store))
    }

    @Test func deletingATaskRemovesItsFolderFromDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-task-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.", repeats: false,
                                     in: root.appendingPathComponent("tasks")).get()
        #expect(FileManager.default.fileExists(atPath: task.path))

        store.removeProject(task.id)

        #expect(store.project(task.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: task.path))
    }
}
