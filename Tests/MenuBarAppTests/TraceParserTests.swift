import Testing
@testable import MenuBarApp

struct TraceParserTests {
    // Tempo's v1 API: "batches", base64 ids, enum names as strings, and the older
    // "instrumentationLibrarySpans" in the second batch.
    static let v1 = #"""
    {"batches":[
     {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"gateway"}},
                                {"key":"k8s.namespace","value":{"stringValue":"edge"}}]},
      "scopeSpans":[{"spans":[
        {"traceId":"CvdlGRbNQ92ESOshHIAxnA==","spanId":"t61rcWkgMzE=","name":"GET /orders",
         "kind":"SPAN_KIND_SERVER",
         "startTimeUnixNano":"1790938800000000000","endTimeUnixNano":"1790938800412000000",
         "attributes":[{"key":"http.status_code","value":{"intValue":"502"}},
                       {"key":"http.retry","value":{"boolValue":true}}],
         "status":{"code":"STATUS_CODE_ERROR","message":"upstream timed out"},
         "events":[{"timeUnixNano":"1790938800400000000","name":"exception",
                    "attributes":[{"key":"exception.type","value":{"stringValue":"Timeout"}}]}]}]}]},
     {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"orders"}}]},
      "instrumentationLibrarySpans":[{"spans":[
        {"traceId":"CvdlGRbNQ92ESOshHIAxnA==","spanId":"APBnqgupArc=","parentSpanId":"t61rcWkgMzE=",
         "name":"SELECT orders","kind":"SPAN_KIND_CLIENT",
         "startTimeUnixNano":"1790938800010000000","endTimeUnixNano":"1790938800390000000",
         "status":{}}]}]}]}
    """#

    // The v2 API: a "trace" wrapper, hex ids, enums as numbers, times as numbers.
    static let v2 = #"""
    {"trace":{"resourceSpans":[
     {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"api"}}]},
      "scopeSpans":[{"spans":[
        {"traceId":"0AF7651916CD43DD8448EB211C80319C","spanId":"B7AD6B7169203331","name":"POST /pay",
         "kind":2,"startTimeUnixNano":1790938800000000000,"endTimeUnixNano":1790938800100000000,
         "status":{"code":2},
         "attributes":[{"key":"retries","value":{"intValue":3}},
                       {"key":"ratio","value":{"doubleValue":0.5}},
                       {"key":"tags","value":{"arrayValue":{"values":[{"stringValue":"a"},{"stringValue":"b"}]}}}]}]}]}]}}
    """#

    private func trace(_ text: String) throws -> Trace {
        guard case .trace(let trace) = TraceParser.parse(text) else {
            Issue.record("expected a trace")
            throw CancellationError()
        }
        return trace
    }

    @Test func readsTempoV1Batches() throws {
        let trace = try trace(Self.v1)
        #expect(trace.traceID == "0af7651916cd43dd8448eb211c80319c")
        #expect(trace.rows.map(\.id) == ["b7ad6b7169203331", "00f067aa0ba902b7"])
        #expect(trace.services == ["gateway", "orders"])

        let root = trace.rows[0].span
        #expect(root.service == "gateway")
        #expect(root.operation == "GET /orders")
        #expect(root.kind == "server")
        #expect(root.durationNanos == 412_000_000)
        #expect(root.isError)
        #expect(root.statusMessage == "upstream timed out")
        #expect(root.attributes == [.init(key: "http.status_code", value: "502"),
                                    .init(key: "http.retry", value: "true")])
        #expect(root.resourceAttributes.contains(.init(key: "k8s.namespace", value: "edge")))
        #expect(root.events == [.init(name: "exception", offsetNanos: 400_000_000,
                                      attributes: [.init(key: "exception.type", value: "Timeout")])])

        let child = trace.rows[1]
        #expect(child.depth == 1)
        #expect(child.span.parentID == "b7ad6b7169203331")
        #expect(child.span.kind == "client")
        #expect(!child.span.isError)
        #expect(child.span.statusMessage == nil)
    }

    @Test func readsTheV2Wrapper() throws {
        let trace = try trace(Self.v2)
        #expect(trace.traceID == "0af7651916cd43dd8448eb211c80319c")
        let span = trace.rows[0].span
        #expect(span.id == "b7ad6b7169203331")
        #expect(span.kind == "server")
        #expect(span.isError)
        #expect(span.durationNanos == 100_000_000)
        #expect(span.attributes == [.init(key: "retries", value: "3"),
                                    .init(key: "ratio", value: "0.5"),
                                    .init(key: "tags", value: "[a, b]")])
    }

    // mcp-grafana's API tool hands Grafana's answer back inside an envelope of its own:
    // {"status": <HTTP status>, "headers": {…}, "data": <the body>}.
    @Test func readsATraceInsideTheAPIToolsEnvelope() {
        #expect(TraceParser.parse(#"{"status":200,"headers":{"Content-Type":"application/json"},"data":"# + Self.v1 + "}")
                == TraceParser.parse(Self.v1))
        #expect(TraceParser.parse(#"{"status":200,"headers":{},"data":"# + Self.v2 + "}")
                == TraceParser.parse(Self.v2))
        #expect(TraceParser.parse(#"{"status":404,"headers":{"Content-Type":""},"data":""}"#) == .unreadable)
    }

    @Test func aTraceWithNoSpansIsEmpty() {
        #expect(TraceParser.parse(#"{"batches":[]}"#) == .empty)
        #expect(TraceParser.parse("{}") == .empty)
        #expect(TraceParser.parse(#"{"trace":null}"#) == .empty)
        #expect(TraceParser.parse(#"{"trace":{"resourceSpans":[]}}"#) == .empty)
    }

    @Test func anythingElseIsUnreadable() {
        #expect(TraceParser.parse("trace not found") == .unreadable)
        #expect(TraceParser.parse(#"{"data":[1,2,3]}"#) == .unreadable)
        #expect(TraceParser.parse("[]") == .unreadable)
    }

    @Test func turnsEitherIdFormIntoLowercaseHex() {
        #expect(TraceParser.hexID("CvdlGRbNQ92ESOshHIAxnA==") == "0af7651916cd43dd8448eb211c80319c")
        #expect(TraceParser.hexID("B7AD6B7169203331") == "b7ad6b7169203331")
    }

    @Test func readsSpanKindsInEitherForm() {
        #expect(TraceParser.kind("SPAN_KIND_PRODUCER") == "producer")
        #expect(TraceParser.kind(5) == "consumer")
        #expect(TraceParser.kind(nil) == "unspecified")
        #expect(TraceParser.kind("weird") == "unspecified")
    }
}
