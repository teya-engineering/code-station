import Foundation
import Testing
@testable import MenuBarApp

// The expanded URL is what actually goes on the wire, so the rules that matter are:
// params fold into the template without touching {{env}}, disabled rows stay out,
// and nothing a user types can change the URL's shape by accident.
struct SavedRequestParamsTests {

    @Test func appendsQueryParams() {
        let request = SavedRequest(name: "r", url: "https://host/path",
                                   queryParams: [HeaderField(key: "limit", value: "5000")])
        #expect(request.expandedURL == "https://host/path?limit=5000")
    }

    @Test func joinsWithExistingQuery() {
        let request = SavedRequest(name: "r", url: "https://host/path?a=1",
                                   queryParams: [HeaderField(key: "b", value: "2")])
        #expect(request.expandedURL == "https://host/path?a=1&b=2")
    }

    @Test func skipsDisabledAndEmptyKeys() {
        let request = SavedRequest(name: "r", url: "https://host/path",
                                   queryParams: [
                                       HeaderField(key: "off", value: "1", enabled: false),
                                       HeaderField(key: "", value: "orphan")
                                   ])
        #expect(request.expandedURL == "https://host/path")
    }

    @Test func encodesQueryValues() {
        let request = SavedRequest(name: "r", url: "https://host/path",
                                   queryParams: [HeaderField(key: "q", value: "a b&c")])
        #expect(request.expandedURL == "https://host/path?q=a%20b%26c")
    }

    @Test func leavesEnvInsideValues() {
        let request = SavedRequest(name: "r", url: "https://host/path",
                                   queryParams: [HeaderField(key: "env", value: "{{env}}")])
        #expect(request.expandedURL == "https://host/path?env={{env}}")
    }

    @Test func fillsPathParams() {
        let request = SavedRequest(name: "r", url: "https://host/merchants/:id/sessions",
                                   pathParams: [HeaderField(key: "id", value: "m-42")])
        #expect(request.expandedURL == "https://host/merchants/m-42/sessions")
    }

    @Test func longerPathNamesWinOverPrefixes() {
        let request = SavedRequest(name: "r", url: "https://host/:idType/:id",
                                   pathParams: [
                                       HeaderField(key: "id", value: "42"),
                                       HeaderField(key: "idType", value: "merchant")
                                   ])
        #expect(request.expandedURL == "https://host/merchant/42")
    }

    @Test func emptyPathValueLeavesThePlaceholder() {
        let request = SavedRequest(name: "r", url: "https://host/merchants/:id",
                                   pathParams: [HeaderField(key: "id", value: "")])
        #expect(request.expandedURL == "https://host/merchants/:id")
    }

    @Test func oldFilesLoadWithoutParams() throws {
        let json = #"[{"name": "old", "url": "https://host"}]"#
        let requests = try JSONDecoder().decode([SavedRequest].self, from: Data(json.utf8))
        #expect(requests.count == 1)
        #expect(requests[0].queryParams.isEmpty)
        #expect(requests[0].pathParams.isEmpty)
        #expect(requests[0].expandedURL == "https://host")
    }
}
