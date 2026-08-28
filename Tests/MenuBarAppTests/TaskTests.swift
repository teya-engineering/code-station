import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct TaskTests {
    private let scratch = ScratchDirectory(prefix: "code-station-task-tests")

    private var storeURL: URL { scratch.path("projects.json") }
    private var tasksURL: URL { scratch.path("tasks") }

    @Test func createsANamedTaskWithItsPromptInANewEmptyDirectory() throws {
        let store = ProjectStore(storeURL: storeURL)

        let project = try store.addTask(named: "  Release notes  ",
                                        prompt: "  Draft the release notes.  ",
                                        in: tasksURL).get()

        #expect(project.name == "Release notes")
        #expect(project.kind == .adHoc)
        #expect(project.task == TaskSpec(prompt: "Draft the release notes."))
        #expect(project.url.deletingLastPathComponent() == tasksURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        #expect(store.selectedProjectID == project.id)
        #expect(ProjectStore(storeURL: storeURL).project(project.id) == project)
    }

    @Test func rejectsATaskWithoutANameBeforeCreatingItsDirectory() {
        // A folder of its own, so the check that nothing was written has something to
        // look for that the scratch folder itself would not satisfy.
        let root = scratch.path("root")
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))

        let result = store.addTask(named: " \n ", prompt: "Do something",
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

    @Test func reworksThePromptBetweenRuns() throws {
        let store = ProjectStore(storeURL: storeURL)
        let project = try store.addTask(named: "Sweep", prompt: "First idea",
                                        in: tasksURL).get()

        let reworked = TaskSpec(prompt: "Second idea")
        store.setTaskSpec(reworked, for: project.id)

        #expect(store.project(project.id)?.task == reworked)
        #expect(ProjectStore(storeURL: storeURL).project(project.id)?.task == reworked)
    }

    @Test func ignoresATaskSpecOnANormalProject() throws {
        let store = ProjectStore(storeURL: storeURL)
        let project = try TestStore.project(in: store, named: "repo")

        store.setTaskSpec(TaskSpec(prompt: "Not a task"), for: project.id)

        #expect(store.project(project.id)?.task == nil)
    }

    @Test func runningATaskStartsASessionWithTheSavedPrompt() throws {
        let store = ProjectStore(storeURL: storeURL)
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: tasksURL).get()
        // No executables: the run records its prompt but no process can start.
        let runner = SessionRunner(paths: [:])

        let session = try TaskRun.run(task, store: store, runner: runner,
                                      agentAvatarName: nil).get()

        #expect(session.projectID == task.id)
        let transcript = store.transcript(of: session.id)
        #expect(transcript.contains { $0.role == .user && $0.text == "Do the thing." })
    }

    @Test func runningATaskUsesItsOwnAgentOverTheAppDefault() throws {
        let store = ProjectStore(storeURL: storeURL)
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: tasksURL).get()
        let runner = SessionRunner(paths: [:])
        runner.agent = .claudeCode

        store.setTaskSpec(TaskSpec(prompt: "Do the thing.", agent: .codex), for: task.id)
        let overridden = try TaskRun.run(try #require(store.project(task.id)), store: store,
                                         runner: runner, agentAvatarName: nil).get()
        #expect(overridden.agent == .codex)

        store.setTaskSpec(TaskSpec(prompt: "Do the thing."), for: task.id)
        let following = try TaskRun.run(try #require(store.project(task.id)), store: store,
                                        runner: runner, agentAvatarName: nil).get()
        #expect(following.agent == .claudeCode)
    }

    @Test func deletingATaskRemovesItsFolderFromDisk() throws {
        let store = ProjectStore(storeURL: storeURL)
        let task = try store.addTask(named: "Sweep", prompt: "Do the thing.",
                                     in: tasksURL).get()
        #expect(FileManager.default.fileExists(atPath: task.path))

        store.removeProject(task.id)

        #expect(store.project(task.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: task.path))
    }
}
