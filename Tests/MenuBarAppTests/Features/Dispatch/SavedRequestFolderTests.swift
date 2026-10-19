import Foundation
import Testing
@testable import CodeStationCore
@testable import MenuBarApp

struct SavedRequestFolderTests {
    private let scratch = ScratchDirectory(prefix: "saved-request-folders")
    private var file: URL { scratch.path("dispatch.json") }

    @Test @MainActor func migratesAFlatRequestListIntoDefault() throws {
        let oldRequest = SavedRequest(name: "Existing", url: "https://example.test")
        try JSONEncoder().encode([oldRequest]).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())

        #expect(store.folders == [.default])
        #expect(store.requests[0].id == oldRequest.id)
        #expect(store.requests[0].folderID == RequestFolder.defaultID)
        #expect(store.selected == nil)
    }

    @Test @MainActor func persistsFoldersAndKeepsRequestsWhenAFolderIsRemoved() throws {
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
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
        let unknownFolderID = UUID()
        let saved = SavedRequestCollection(
            requests: [SavedRequest(name: "Unknown folder", folderID: unknownFolderID)])
        try JSONEncoder().encode(saved).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        let newRequest = store.add()

        #expect(store.folders == [.default])
        #expect(store.requests.allSatisfy { $0.folderID == RequestFolder.defaultID })
        #expect(newRequest.folderID == RequestFolder.defaultID)
        #expect(store.selected?.id == newRequest.id)
    }

    @Test @MainActor func defaultFolderCannotBeRenamedOrRemoved() throws {
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        let request = store.add()

        store.renameFolder(RequestFolder.defaultID, to: "Other")
        store.removeFolder(RequestFolder.defaultID)

        #expect(store.folders == [.default])
        #expect(store.requests[0].id == request.id)
        #expect(store.requests[0].folderID == RequestFolder.defaultID)
    }

    @Test @MainActor func foldersOpenClosedUnlessTheUserLeftThemOpen() throws {
        let opened = RequestFolder(name: "Payments")
        let closed = RequestFolder(name: "Refunds")
        let saved = SavedRequestCollection(folders: [.default, opened, closed],
                                           requests: [])
        try JSONEncoder().encode(saved).write(to: file)

        // A file written before folders remembered their state opens everything closed.
        let first = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        #expect(!first.isExpanded(RequestFolder.defaultID))
        #expect(!first.isExpanded(opened.id))

        first.toggleFolder(opened.id)
        first.save()

        let second = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        #expect(second.isExpanded(opened.id))
        #expect(!second.isExpanded(closed.id))
        #expect(!second.isExpanded(RequestFolder.defaultID))
    }

    @Test @MainActor func aDeletedFolderIsForgottenRatherThanReopened() throws {
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        let folder = store.addFolder(named: "Payments")
        #expect(store.isExpanded(folder.id))
        store.removeFolder(folder.id)

        let saved = try JSONDecoder().decode(SavedRequestCollection.self,
                                              from: Data(contentsOf: file))
        #expect(saved.expandedFolderIDs.isEmpty)
    }

    @Test @MainActor func deletingTheSelectedRequestLeavesTheDetailEmpty() throws {
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        let first = store.add(SavedRequest(name: "First"))
        store.add(SavedRequest(name: "Second"))
        store.selectedID = first.id

        store.remove(first.id)

        #expect(store.requests.map(\.name) == ["Second"])
        #expect(store.selected == nil)
    }

    @Test @MainActor func reorderingPlacesARequestBesideAnotherAndTakesItsFolder() throws {
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        let first = store.add(SavedRequest(name: "First"))
        let second = store.add(SavedRequest(name: "Second"))
        let third = store.add(SavedRequest(name: "Third"))
        let folder = store.addFolder(named: "Payments")
        let other = store.add(SavedRequest(name: "Other"), to: folder.id)

        store.move(third.id, beside: first.id, after: false)
        #expect(store.requests(in: RequestFolder.defaultID).map(\.name) == ["Third", "First", "Second"])

        store.move(third.id, beside: second.id, after: true)
        #expect(store.requests(in: RequestFolder.defaultID).map(\.name) == ["First", "Second", "Third"])

        store.move(first.id, beside: other.id, after: false)
        #expect(store.requests(in: folder.id).map(\.name) == ["First", "Other"])
        #expect(store.requests(in: RequestFolder.defaultID).map(\.name) == ["Second", "Third"])

        let saved = try JSONDecoder().decode(SavedRequestCollection.self,
                                              from: Data(contentsOf: file))
        #expect(saved.requests.map(\.name) == ["Second", "Third", "First", "Other"])
    }

    @Test @MainActor func movingIntoAFolderPutsTheRequestLast() throws {
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        let moved = store.add(SavedRequest(name: "Moved"))
        let folder = store.addFolder(named: "Payments")
        store.add(SavedRequest(name: "Already there"), to: folder.id)

        store.move(moved.id, to: folder.id)

        #expect(store.requests(in: folder.id).map(\.name) == ["Already there", "Moved"])
    }

    @Test @MainActor func renamingTrimsTheNameAndIgnoresABlankOne() throws {
        try JSONEncoder().encode(SavedRequestCollection()).write(to: file)

        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        let request = store.add(SavedRequest(name: "Old"))

        store.rename(request.id, to: "  Create payment  ")
        store.rename(request.id, to: "   ")

        #expect(store.requests[0].name == "Create payment")
        let saved = try JSONDecoder().decode(SavedRequestCollection.self,
                                              from: Data(contentsOf: file))
        #expect(saved.requests[0].name == "Create payment")
    }
}
