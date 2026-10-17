import Foundation
import Testing
@testable import MenuBarApp

struct SiteDefaultsServicesTests {
    private func decode(_ json: String) throws -> SiteDefaults {
        try SiteDefaults.decode(Data(json.utf8), from: URL(fileURLWithPath: "/tmp/site.json"))
    }

    @Test func readsAService() throws {
        let defaults = try decode(#"""
        {"services":[{"name":"orders","lokiSelector":"{app=\"orders\"}","logFormat":"logfmt",
          "levelField":"level","levelValues":["INFO","ERROR"],"traceField":"traceId",
          "fields":{"logger":"class name"},"prometheusSelector":"namespace=\"orders\"",
          "notes":"PII is masked."}]}
        """#)
        let service = try #require(defaults.services?.first)
        #expect(service.name == "orders")
        #expect(service.lokiSelector == #"{app="orders"}"#)
        #expect(service.logFormat == .logfmt)
        #expect(service.levelValues == ["INFO", "ERROR"])
        #expect(service.traceField == "traceId")
        #expect(service.fields == ["logger": "class name"])
        #expect(service.prometheusSelector == #"namespace="orders""#)
        #expect(service.notes == "PII is masked.")
    }

    @Test func leavesServicesOutWhenTheFileHasNone() throws {
        #expect(try decode(#"{"environments":[{"name":"dev"}]}"#).services == nil)
    }

    @Test func dropsABrokenEntryAndKeepsTheRestOfTheFile() throws {
        let defaults = try decode(#"""
        {"environments":[{"name":"dev"}],
         "services":[{"name":"no-selector","logFormat":"logfmt"},
                     {"name":"bad-format","lokiSelector":"{a=\"b\"}","logFormat":"xml"},
                     {"name":"good","lokiSelector":"{a=\"b\"}","logFormat":"json"}]}
        """#)
        #expect(defaults.services?.map(\.name) == ["good"])
        #expect(defaults.environments?.map(\.name) == ["dev"])
    }

    @Test func keepsTheFirstOfTwoServicesWithTheSameName() throws {
        let defaults = try decode(#"""
        {"services":[{"name":"a","lokiSelector":"{x=\"1\"}","logFormat":"json"},
                     {"name":"a","lokiSelector":"{x=\"2\"}","logFormat":"json"}]}
        """#)
        #expect(defaults.services?.map(\.lokiSelector) == [#"{x="1"}"#])
    }

    @Test func writesServicesBack() throws {
        let defaults = SiteDefaults(services: [
            .init(name: "a", lokiSelector: #"{x="1"}"#, logFormat: .json)
        ])
        let data = try JSONEncoder().encode(defaults)
        #expect(try decode(String(decoding: data, as: UTF8.self)).services == defaults.services)
    }

    private static let orders = SiteDefaults.Service(name: "orders", lokiSelector: #"{app="orders"}"#,
                                                     logFormat: .logfmt)

    @Test func offersServicesAsAnAspectWhenTheFileHasThem() {
        #expect(SiteConfigurationPlan(SiteDefaults(services: [Self.orders])).aspects == [.services])
        #expect(SiteConfigurationPlan(SiteDefaults()).aspects.isEmpty)
        #expect(SiteConfigurationAspect.services.detail(in: SiteDefaults(services: [Self.orders]))
                == "1 service")
    }

    @Test func resettingServicesTakesTheImportedOnesAndLeavesTheRest() {
        let current = SiteDefaults(environments: [.init(name: "dev")])
        let imported = SiteDefaults(environments: [.init(name: "other")], services: [Self.orders])
        let result = SiteConfigurationPlan.resetting([.services], in: current, to: imported)
        #expect(result.services == [Self.orders])
        #expect(result.environments?.map(\.name) == ["dev"])
    }

    private func call(_ name: String, _ query: String) throws -> GrafanaToolCall {
        let key = name.hasSuffix("query_prometheus") ? "expr" : "logql"
        let data = try JSONSerialization.data(withJSONObject: [key: query])
        var tool = ToolUse(id: "c", name: name, input: String(decoding: data, as: UTF8.self))
        tool.result = "{}"
        return try #require(GrafanaToolCall(tool: tool))
    }

    private static let tki = SiteDefaults.Service(
        name: "payments", lokiSelector: #"{tki="payments"}"#, logFormat: .logfmt,
        prometheusSelector: #"namespace="payments""#)

    @Test func matchesTheSameSelectorWrittenDifferently() throws {
        let loki = "mcp__grafana-cde-dev__query_loki_logs"
        #expect(Self.tki.matches(try call(loki, #"{tki="payments"} |= "x""#)))
        #expect(Self.tki.matches(try call(loki, #"{ level="ERROR" , tki = "payments" } | logfmt"#)))
    }

    @Test func doesNotMatchAnotherServiceOrALineFilter() throws {
        let loki = "mcp__grafana-cde-dev__query_loki_logs"
        #expect(!Self.tki.matches(try call(loki, #"{tki="orders"}"#)))
        #expect(!Self.tki.matches(try call(loki, #"{app="x"} |= "tki=\"payments\"""#)))
    }

    @Test func matchesAPrometheusQueryThatUsesTheSelector() throws {
        let prom = "mcp__grafana-cde-dev__query_prometheus"
        #expect(Self.tki.matches(try call(prom, #"sum(rate(http_requests_total{namespace = "payments", status=~"5.."}[5m]))"#)))
        #expect(!Self.tki.matches(try call(prom, #"up{namespace="orders"}"#)))
    }

    @Test func readsTheMatchersOfTheStreamSelectorOnly() {
        #expect(SiteDefaults.Service.streamMatchers(in: #"{a="1", b=~"x,y"} |= "{c=\"2\"}""#)
                == [#"a="1""#, #"b=~"x,y""#])
    }

    @Test func readsAScopeAndATraceName() throws {
        let defaults = try decode(#"""
        {"services":[{"name":"payments","lokiSelector":"{app=\"payments\"}","logFormat":"json",
          "scope":"non-platform","traceServiceName":"payments-api"}]}
        """#)
        let service = try #require(defaults.services?.first)
        #expect(service.scope == "non-platform")
        #expect(service.traceServiceName == "payments-api")
        #expect(service.traceName == "payments-api")
    }

    @Test func aServiceWithoutATraceNameGoesByItsName() {
        let service = SiteDefaults.Service(name: "orders", lokiSelector: #"{app="orders"}"#,
                                           logFormat: .json)
        #expect(service.traceName == "orders")
        #expect(service.scope == nil)
    }

    @Test func theScopeReachesTheAgent() {
        let service = SiteDefaults.Service(name: "orders", lokiSelector: #"{app="orders"}"#,
                                           logFormat: .logfmt, scope: "cde")
        #expect(service.promptContext.contains("- Grafana scope: cde"))
    }
}
