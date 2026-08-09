import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct AdHocTaskTests {
    @Test func createsANamedTaskInANewEmptyDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-ad-hoc-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("projects.json")
        let tasksURL = root.appendingPathComponent("tasks", isDirectory: true)
        let store = ProjectStore(storeURL: storeURL)

        let project = try store.addAdHocTask(named: "  Release notes  ", in: tasksURL).get()

        #expect(project.name == "Release notes")
        #expect(project.url.deletingLastPathComponent() == tasksURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        #expect(store.selectedProjectID == project.id)
        #expect(ProjectStore(storeURL: storeURL).project(project.id) == project)
    }

    @Test func rejectsATaskWithoutANameBeforeCreatingItsDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-ad-hoc-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(storeURL: root.appendingPathComponent("projects.json"))

        let result = store.addAdHocTask(named: " \n ", in: root.appendingPathComponent("tasks"))

        if case .success = result {
            Issue.record("A blank task name was accepted")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
