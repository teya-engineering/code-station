import Foundation
import Testing
@testable import MenuBarApp

struct SavedRequestFolderTests {

    @Test @MainActor func migratesAFlatRequestListIntoDefault() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("postman-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let oldRequest = SavedRequest(name: "Existing", url: "https://example.test")
        try JSONEncoder().encode([oldRequest]).write(to: file)

        let store = PostmanStore(storeURL: file)

        #expect(store.folders == [.default])
        #expect(store.requests[0].id == oldRequest.id)
        #expect(store.requests[0].folderID == RequestFolder.defaultID)
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
        #expect(saved.folders == [.default, folder])
        #expect(saved.requests[0].folderID == folder.id)

        store.removeFolder(folder.id)

        #expect(store.folders == [.default])
        #expect(store.requests(in: RequestFolder.defaultID).map(\.id) == [request.id])
    }

    @Test @MainActor func newAndUnknownRequestsUseDefault() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("postman-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let unknownFolderID = UUID()
        let saved = SavedRequestCollection(
            requests: [SavedRequest(name: "Unknown folder", folderID: unknownFolderID)])
        try JSONEncoder().encode(saved).write(to: file)

        let store = PostmanStore(storeURL: file)
        let newRequest = store.add()

        #expect(store.folders == [.default])
        #expect(store.requests.allSatisfy { $0.folderID == RequestFolder.defaultID })
        #expect(newRequest.folderID == RequestFolder.defaultID)
    }

    @Test @MainActor func defaultFolderCannotBeRenamedOrRemoved() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("postman-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = PostmanStore(storeURL: file)
        let request = store.add()

        store.renameFolder(RequestFolder.defaultID, to: "Other")
        store.removeFolder(RequestFolder.defaultID)

        #expect(store.folders == [.default])
        #expect(store.requests[0].id == request.id)
        #expect(store.requests[0].folderID == RequestFolder.defaultID)
    }
}
