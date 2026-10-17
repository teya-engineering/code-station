import Foundation
import Testing
@testable import MenuBarApp

struct TraceInputTests {
    private static let id = "0af7651916cd43dd8448eb211c80319c"

    @Test func takesATraceIdAsTyped() {
        #expect(TraceInput.traceID(from: "  0AF7651916CD43DD8448EB211C80319C \n") == Self.id)
        #expect(TraceInput.traceID(from: "b7ad6b7169203331") == "b7ad6b7169203331")
    }

    @Test func pullsTheTraceIdOutOfAGrafanaLink() {
        let explore = "https://grafana.edge-prd.example.com/explore?schemaVersion=1&panes=%7B%22a%22%3A%7B%22datasource%22%3A%22P214B5B846CF3925F%22%2C%22queries%22%3A%5B%7B%22query%22%3A%220af7651916cd43dd8448eb211c80319c%22%7D%5D%7D%7D"
        #expect(TraceInput.traceID(from: explore) == Self.id)
        #expect(TraceInput.traceID(from: "https://grafana.example.com/trace/\(Self.id)?orgId=1") == Self.id)
    }

    @Test func rejectsWhatIsNotATraceId() {
        #expect(TraceInput.traceID(from: "") == nil)
        #expect(TraceInput.traceID(from: "hello") == nil)
        #expect(TraceInput.traceID(from: String(Self.id.dropLast())) == nil)
        #expect(TraceInput.traceID(from: Self.id + "a") == nil)
        #expect(TraceInput.traceID(from: "https://grafana.example.com/explore") == nil)
    }

    @Test func linksToTheTraceInGrafanaExplore() throws {
        let url = try #require(TraceLink.explore(grafanaURL: "https://grafana.edge-prd.example.com/",
                                                 datasourceUID: "TEMPO-1", traceID: Self.id))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "grafana.edge-prd.example.com")
        #expect(components.path == "/explore")
        let panes = try #require(components.queryItems?.first { $0.name == "panes" }?.value)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(panes.utf8)) as? [String: Any])
        let pane = try #require(object["a"] as? [String: Any])
        #expect(pane["datasource"] as? String == "TEMPO-1")
        let query = try #require((pane["queries"] as? [[String: Any]])?.first)
        #expect(query["query"] as? String == Self.id)
        #expect(query["queryType"] as? String == "traceql")
    }
}
