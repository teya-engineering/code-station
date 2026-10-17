import Foundation
import Testing
@testable import MenuBarApp

private actor Script {
    private var replies: [String: [MCPHTTPClient.ToolResult]]
    private(set) var tools: [String] = []
    private(set) var arguments: [String] = []
    private let failure: MCPHTTPClient.Failure?

    init(_ replies: [String: [MCPHTTPClient.ToolResult]], failure: String? = nil) {
        self.replies = replies
        self.failure = failure.map { .rpc($0) }
    }

    init(_ replies: [String: [MCPHTTPClient.ToolResult]], throwing failure: MCPHTTPClient.Failure) {
        self.replies = replies
        self.failure = failure
    }

    func answer(_ tool: String, _ data: Data) throws -> MCPHTTPClient.ToolResult {
        tools.append(tool)
        arguments.append(String(decoding: data, as: UTF8.self))
        if let failure, tool == "grafana_api_request" { throw failure }
        guard var queue = replies[tool], !queue.isEmpty else {
            throw MCPHTTPClient.Failure.rpc("no reply for \(tool)")
        }
        let reply = queue.removeFirst()
        replies[tool] = queue
        return reply
    }
}

struct TraceFetcherTests {
    private static let id = "0af7651916cd43dd8448eb211c80319c"
    private static let tempo = #"[{"uid":"TEMPO-1","name":"Tempo","type":"tempo"},{"uid":"LOKI-1","name":"Loki","type":"loki"}]"#

    private static func ok(_ text: String) -> MCPHTTPClient.ToolResult { .init(text: text, isError: false) }
    private static func error(_ text: String) -> MCPHTTPClient.ToolResult { .init(text: text, isError: true) }

    private func fetch(_ script: Script, known: TraceFetcher.Datasource? = nil) async -> TraceFetcher.Outcome {
        await TraceFetcher.fetch(traceID: Self.id, datasource: known) { try await script.answer($0, $1) }
    }

    @Test func findsTheTempoDatasourceThenTheTrace() async throws {
        let script = Script(["list_datasources": [Self.ok(Self.tempo)],
                             "grafana_api_request": [Self.ok(TraceParserTests.v2)]])
        let outcome = await fetch(script)
        guard case .found(let trace, let datasource) = outcome else {
            Issue.record("expected a trace, got \(outcome)")
            return
        }
        #expect(trace.traceID == Self.id)
        #expect(datasource == .init(uid: "TEMPO-1", name: "Tempo"))
        #expect(await script.tools == ["list_datasources", "grafana_api_request"])

        let sent = await script.arguments
        let request = try #require(try JSONSerialization.jsonObject(with: Data(sent[1].utf8)) as? [String: Any])
        #expect(request["endpoint"] as? String == "/api/datasources/proxy/uid/TEMPO-1/api/traces/\(Self.id)")
        #expect(request["method"] as? String == "GET")
        #expect((request["headers"] as? [String: String])?["Accept"] == "application/json")
        #expect(sent[0].contains(#""type":"tempo""#))
    }

    @Test func skipsTheLookupWhenTheDatasourceIsKnown() async {
        let script = Script(["grafana_api_request": [Self.ok(TraceParserTests.v1)]])
        let outcome = await fetch(script, known: .init(uid: "T", name: "Tempo"))
        if case .found = outcome {} else { Issue.record("expected a trace, got \(outcome)") }
        #expect(await script.tools == ["grafana_api_request"])
    }

    @Test func saysWhenGrafanaHasNoTempo() async {
        let script = Script(["list_datasources": [Self.ok(#"[{"uid":"L","name":"Loki","type":"loki"}]"#)]])
        #expect(await fetch(script) == .noDatasource)
    }

    @Test func readsEveryWayTempoSaysNotFound() async {
        let known = TraceFetcher.Datasource(uid: "T", name: "Tempo")
        for reply in [Self.error("request failed with status 404: trace not found"),
                      Self.ok(#"{"batches":[]}"#),
                      Self.ok("trace not found")] {
            let script = Script(["grafana_api_request": [reply]])
            #expect(await fetch(script, known: known) == .notFound)
        }
    }

    // A tool the server does not have, or a transport that keeps answering 404, says
    // nothing about the trace, so it is reported as it came rather than as "not found".
    @Test func keepsFailuresThatAreNotAboutTheTrace() async {
        let known = TraceFetcher.Datasource(uid: "T", name: "Tempo")
        #expect(await fetch(Script([:], failure: "tool 'grafana_api_request' not found"), known: known)
                == .failed("tool 'grafana_api_request' not found"))
        #expect(await fetch(Script([:], throwing: .http(404)), known: known)
                == .failed("The Grafana MCP server answered HTTP 404."))
    }

    // A datasource remembered from an earlier lookup can be gone since. Grafana says so,
    // and the lookup is made once more rather than reporting the trace missing.
    @Test func looksTheDatasourceUpAgainWhenTheRememberedOneIsGone() async {
        let script = Script([
            "grafana_api_request": [Self.error(#"request failed with status 404: {"message":"Data source not found"}"#),
                                    Self.ok(TraceParserTests.v2)],
            "list_datasources": [Self.ok(Self.tempo)],
        ])
        let outcome = await fetch(script, known: .init(uid: "OLD", name: "Tempo"))
        guard case .found(_, let datasource) = outcome else {
            Issue.record("expected a trace, got \(outcome)")
            return
        }
        #expect(datasource.uid == "TEMPO-1")
        #expect(await script.tools == ["grafana_api_request", "list_datasources", "grafana_api_request"])
    }

    // As mcp-grafana answers: the body wrapped with the HTTP status beside it, and a 404 an
    // ordinary reply rather than an error.
    @Test func readsTheAPIToolsEnvelope() async {
        let known = TraceFetcher.Datasource(uid: "T", name: "Tempo")
        let wrapped = Self.ok(#"{"status":200,"headers":{"Content-Type":"application/json"},"data":"# + TraceParserTests.v2 + "}")
        let outcome = await fetch(Script(["grafana_api_request": [wrapped]]), known: known)
        guard case .found(let trace, _) = outcome else {
            Issue.record("expected a trace, got \(outcome)")
            return
        }
        #expect(trace.traceID == Self.id)
        let missing = Self.ok(#"{"status":404,"headers":{"Content-Type":""},"data":""}"#)
        #expect(await fetch(Script(["grafana_api_request": [missing]]), known: known) == .notFound)
    }

    // A body that is not a trace is reported as it came, even when it holds the digits 404
    // somewhere, as a nanosecond timestamp often does.
    @Test func digitsInABodyAreNotAStatus() async {
        let known = TraceFetcher.Datasource(uid: "T", name: "Tempo")
        let wrapped = #"{"status":200,"headers":{},"data":{"startTimeUnixNano":"1791885064683354045"}}"#
        #expect(await fetch(Script(["grafana_api_request": [Self.ok(wrapped)]]), known: known)
                == .unreadable(wrapped))
        let bare = #"{"startTimeUnixNano":"1791885064683354045"}"#
        #expect(await fetch(Script(["grafana_api_request": [Self.ok(bare)]]), known: known)
                == .unreadable(bare))
    }

    @Test func looksTheDatasourceUpAgainWhenTheEnvelopeSaysItIsGone() async {
        let gone = #"{"status":404,"headers":{"Content-Type":"application/json; charset=UTF-8"},"data":{"message":"Unable to find datasource","traceID":"efe924f92601bc67b065b6f655a64a63"}}"#
        let script = Script([
            "grafana_api_request": [Self.ok(gone), Self.ok(TraceParserTests.v2)],
            "list_datasources": [Self.ok(Self.tempo)],
        ])
        let outcome = await fetch(script, known: .init(uid: "OLD", name: "Tempo"))
        guard case .found(_, let datasource) = outcome else {
            Issue.record("expected a trace, got \(outcome)")
            return
        }
        #expect(datasource.uid == "TEMPO-1")
    }

    @Test func reportsOtherProblemsAsTheyCame() async {
        let known = TraceFetcher.Datasource(uid: "T", name: "Tempo")
        #expect(await fetch(Script(["grafana_api_request": [Self.error("permission denied")]]), known: known)
                == .failed("permission denied"))
        #expect(await fetch(Script(["grafana_api_request": [Self.ok(#"{"status":"weird"}"#)]]), known: known)
                == .unreadable(#"{"status":"weird"}"#))
        #expect(await fetch(Script([:], failure: "connection refused"), known: known)
                == .failed("connection refused"))
    }

    @Test func picksTheDatasourceByTypeThenNameInEitherListShape() {
        let wrapped = #"{"datasources":[{"uid":"B","name":"Tempo B","type":"tempo"},{"uid":"A","name":"Tempo A","type":"Tempo"}],"total":2}"#
        #expect(TraceFetcher.datasource(ofType: "tempo", in: wrapped) == .init(uid: "A", name: "Tempo A"))
        #expect(TraceFetcher.datasource(ofType: "loki", in: Self.tempo) == .init(uid: "LOKI-1", name: "Loki"))
        #expect(TraceFetcher.datasource(ofType: "tempo", in: "not json") == nil)
    }

    // The cde and edge Grafanas list five Loki datasources, and the first by name,
    // audit-loki, refuses the service account. The logs are in the one called "loki".
    @Test func prefersTheDatasourceNamedForItsTypeToOnesBeforeItByName() {
        let list = #"{"datasources":[{"id":34,"uid":"LOKI-AUDIT","name":"audit-loki","type":"loki","isDefault":false},{"id":67,"uid":"LOKI-AWS","name":"aws-logs","type":"loki","isDefault":false},{"id":2,"uid":"LOKI-MAIN","name":"loki","type":"loki","isDefault":false},{"id":68,"uid":"LOKI-COMBINED","name":"loki-combined","type":"loki","isDefault":false}],"total":4,"hasMore":false}"#
        #expect(TraceFetcher.datasource(ofType: "loki", in: list) == .init(uid: "LOKI-MAIN", name: "loki"))
    }

    @Test func prefersTheDefaultDatasourceToAnyOther() {
        let list = #"[{"uid":"LOKI-MAIN","name":"Loki","type":"loki","isDefault":false},{"uid":"LOKI-TENANT","name":"tenant-logs","type":"loki","isDefault":true}]"#
        #expect(TraceFetcher.datasource(ofType: "loki", in: list) == .init(uid: "LOKI-TENANT", name: "tenant-logs"))
    }
}
