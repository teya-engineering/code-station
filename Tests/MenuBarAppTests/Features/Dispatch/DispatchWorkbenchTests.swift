import Foundation
import Testing
@testable import MenuBarApp

struct DispatchWorkbenchTests {
    private let scratch = ScratchDirectory(prefix: "dispatch-workbench")

    @Test @MainActor func restoresSelectionTabsExpansionAndPaneSize() throws {
        let file = scratch.path("requests.json")
        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        let request = store.add(SavedRequest(name: "Selected"))
        store.workbench.requestTab = .auth
        store.workbench.responseTab = .table
        store.workbench.responseExpanded = true
        store.responseHeight = 410
        store.togglePin(request.id)
        store.save()

        let reopened = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        #expect(reopened.selected?.id == request.id)
        #expect(reopened.selected?.isPinned == true)
        #expect(reopened.workbench == store.workbench)
        reopened.remove(request.id)
        #expect(DispatchStore(storeURL: file, siteDefaults: SiteDefaults()).selected == nil)
    }

    @Test @MainActor func readsOldCollectionsAndDiscardsStaleSelection() throws {
        let file = scratch.path("old.json")
        try Data(#"{"folders":[],"requests":[{"name":"Old request"}]}"#.utf8).write(to: file)
        let store = DispatchStore(storeURL: file, siteDefaults: SiteDefaults())
        #expect(store.requests.count == 1)
        #expect(store.requests[0].isPinned == false)
        #expect(store.workbench.requestTab == .parameters)
        store.selectedID = UUID()
        store.save()
        #expect(DispatchStore(storeURL: file, siteDefaults: SiteDefaults()).selectedID == nil)
    }

    @Test @MainActor func searchMatchesNameMethodAndURLWithoutChangingFolderStateOrManualOrder() {
        let store = DispatchStore(storeURL: scratch.path("search.json"), siteDefaults: SiteDefaults())
        let folder = store.addFolder(named: "Payments")
        let first = store.add(SavedRequest(name: "List cafés", url: "https://example.test/payments"), to: folder.id)
        let second = store.add(SavedRequest(name: "Create", method: .post, url: "https://example.test/create"), to: folder.id)
        store.toggleFolder(folder.id)
        store.togglePin(second.id)

        #expect(store.visibleRequests(in: folder.id, matching: "").map(\.id) == [second.id, first.id])
        #expect(store.visibleRequests(in: folder.id, matching: " CAFES ").map(\.id) == [first.id])
        #expect(store.visibleRequests(in: folder.id, matching: "post").map(\.id) == [second.id])
        #expect(store.visibleRequests(in: folder.id, matching: "/payments").map(\.id) == [first.id])
        #expect(store.visibleRequests(in: folder.id, matching: "missing").isEmpty)
        #expect(!store.isExpanded(folder.id))
        store.togglePin(second.id)
        #expect(store.visibleRequests(in: folder.id, matching: "").map(\.id) == [first.id, second.id])
    }

    @Test func dividerKeepsBothPanesWithinTheAvailableHeight() {
        #expect(DispatchSplitLayout.responseHeight(800, available: 450) == 330)
        #expect(DispatchSplitLayout.responseHeight(-20, available: 450) == 120)
        #expect(DispatchSplitLayout.responseHeight(300, available: 180) == 60)
        #expect(DispatchSplitLayout.responseHeight(.infinity, available: 450) == 300)
        #expect(DispatchSplitLayout.responseHeight(300, available: 60) == 0)
    }

    @Test(arguments: ["", " ", "example.test", "file:///tmp/test", "ftp://example.test", "https://", "https://{{host}}/", "https://example.test/:id", "https://bad host.test"])
    func rejectsInvalidOrUnresolvedDestinations(url: String) {
        #expect(!DispatchRunner.isValidURL(url))
    }

    @Test(arguments: ["https://example.test", "http://localhost:8080/test", "https://example.test/a%20b?q=a%2Fb", "https://[::1]/"])
    func acceptsHTTPDestinations(url: String) { #expect(DispatchRunner.isValidURL(url)) }

    @Test func tableIncludesFieldsFromEveryRowAndNestedValues() throws {
        let document = DispatchResponseDocument(body: #"{"data":[{"id":1,"name":"First"},{"id":2,"enabled":false,"nested":{"x":null}}]}"#)
        let table = try #require(document.table)
        #expect(table.columns == ["enabled", "id", "name", "nested"])
        #expect(table.rows == [["", "1", "First", ""], ["false", "2", "", #"{"x":null}"#]])
        #expect(!table.limited)
    }

    @Test func supportsRootObjectsScalarsAndMixedArrays() {
        #expect(DispatchResponseDocument(body: "true").table?.rows == [["true"]])
        #expect(DispatchResponseDocument(body: #"{"name":"Test"}"#).table?.columns == ["name"])
        #expect(DispatchResponseDocument(body: "[]").table?.rows.isEmpty == true)
        #expect(DispatchResponseDocument(body: #"[1,null,"word"]"#).table?.rows == [["1"], ["null"], ["word"]])
    }

    @Test func keepsTextMalformedEmptyTruncatedAndLargeBodiesAsText() {
        for body in ["", "plain text", "{broken", "[Binary response]"] {
            let document = DispatchResponseDocument(body: body)
            #expect(!document.isJSON)
            #expect(document.table == nil)
        }
        #expect(DispatchResponseDocument(body: "[]", truncated: true).table == nil)
        let large = DispatchResponseDocument(body: String(repeating: " ", count: DispatchResponseDocument.structuredByteLimit + 1))
        #expect(large.structuredLimitReached)
        #expect(large.table == nil)
    }

    @Test func boundsTableWorkAndReportsTheLimit() throws {
        let body = "[" + Array(repeating: #"{"id":1}"#, count: 501).joined(separator: ",") + "]"
        let table = try #require(DispatchResponseDocument(body: body).table)
        #expect(table.rows.count == 500)
        #expect(table.totalRows == 501)
        #expect(table.limited)
        let long = #"{"text":""# + String(repeating: "a", count: 501) + #""}"#
        #expect(DispatchResponseDocument(body: long).table?.limited == true)
    }

    @Test func foldingPreservesSurroundingTextAndIgnoresBracketsInsideStrings() {
        let body = #"{"message":"[not an array]","data":[{"text":"escaped \" ]"},[1,2]],"large":12345678901234567890}"#
        #expect(DispatchResponseDocument(body: body).collapsedBody == #"{"message":"[not an array]","data":[ … ],"large":12345678901234567890}"#)
        #expect(DispatchResponseDocument(body: "[1,2]").collapsedBody == "[ … ]")
        #expect(DispatchResponseDocument(body: "[]").collapsedBody == nil)
    }
}
