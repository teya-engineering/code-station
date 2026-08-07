import Foundation
import Testing
@testable import MenuBarApp

struct SavedRequestFolderTests {

    @Test @MainActor func migratesAFlatRequestList() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("postman-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let oldRequest = SavedRequest(name: "Existing", url: "https://example.test")
        try JSONEncoder().encode([oldRequest]).write(to: file)

        let store = PostmanStore(storeURL: file)

        #expect(store.folders.isEmpty)
        #expect(store.requests == [oldRequest])
        #expect(store.requests[0].folderID == nil)
    }

    @Test @MainActor func persistsFoldersAndKeepsRequestsWhenAFolderIsRemoved() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("postman-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = PostmanStore(storeURL: file)
        let request = store.add(SavedRequest(name: "Create payment"))
        let folder = store.addFolder(named: "Payments")
        store.move(request.id, to: folder.id)
        store.save()

        let saved = try JSONDecoder().decode(SavedRequestCollection.self,
                                              from: Data(contentsOf: file))
        #expect(saved.folders == [folder])
        #expect(saved.requests[0].folderID == folder.id)

        store.removeFolder(folder.id)

        #expect(store.folders.isEmpty)
        #expect(store.requests(in: nil).map(\.id) == [request.id])
    }
}
