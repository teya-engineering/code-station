import Foundation
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct SelectionPersistenceTests {
    @Test func restoresTheSelectedDestinationWithoutRewritingTheIndex() throws {
        clearSelectionPreferences()
        defer { clearSelectionPreferences() }

        let scratch = ScratchDirectory(prefix: "selection-persistence")
        let writes = FileWriteRecorder()
        let index = scratch.path("projects.json")
        let store = ProjectStore(storeURL: index, files: writes.client)
        let first = try TestStore.project(in: store, named: "api")
        let second = try TestStore.project(in: store, named: "web")
        let workspace = try #require(store.addWorkspace(
            name: "Checkout", projectIDs: [first.id, second.id], leadProjectID: first.id))
        let session = store.newSession(in: first.id)
        let indexWrites = writes.count(for: index)

        store.selectSession(session.id)
        #expect(ProjectStore(storeURL: index).selection == .session(session.id))
        #expect(writes.count(for: index) == indexWrites)

        store.selectWorkspace(workspace.id)
        #expect(ProjectStore(storeURL: index).selection == .workspace(workspace.id))
        #expect(writes.count(for: index) == indexWrites)

        store.selectProject(second.id)
        let restoredProject = ProjectStore(storeURL: index)
        #expect(restoredProject.selection == nil)
        #expect(restoredProject.selectedProjectID == second.id)
        #expect(writes.count(for: index) == indexWrites)

        store.selectHome()
        #expect(store.save())
        #expect(writes.count(for: index) == indexWrites)
    }

    private func clearSelectionPreferences() {
        Preferences.selectedSessionID = nil
        Preferences.selectedWorkspaceID = nil
        Preferences.selectedProjectID = nil
    }
}

private final class FileWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writesByPath: [String: Int] = [:]

    var client: PersistentFileClient {
        PersistentFileClient(
            readIfPresent: { try PersistentFile.readIfPresent($0) },
            write: { [self] data, url in
                lock.withLock { writesByPath[url.path, default: 0] += 1 }
                try PersistentFile.write(data, to: url)
            },
            removeIfPresent: { try PersistentFile.removeIfPresent($0) })
    }

    func count(for url: URL) -> Int {
        lock.withLock { writesByPath[url.path, default: 0] }
    }
}
