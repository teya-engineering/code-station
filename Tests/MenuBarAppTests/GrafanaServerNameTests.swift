import Testing
@testable import MenuBarApp

struct GrafanaServerNameTests {
    @Test func readsAPlainScopeAndEnvironment() {
        #expect(Grafana.scope(from: "grafana-cde-dev") == "cde")
        #expect(Grafana.environment(from: "grafana-cde-dev") == "dev")
    }

    @Test func readsAScopeWithAHyphenOfItsOwn() {
        #expect(Grafana.scope(from: "grafana-non-platform-prd") == "non-platform")
        #expect(Grafana.environment(from: "grafana-non-platform-prd") == "prd")
    }

    @Test func rejectsNamesMissingEitherPart() {
        #expect(Grafana.scope(from: "grafana-platform") == nil)
        #expect(Grafana.environment(from: "grafana-platform") == nil)
        #expect(Grafana.environment(from: "grafana-") == nil)
        #expect(Grafana.environment(from: "grafana--dev") == nil)
        #expect(Grafana.environment(from: "grafana-cde-") == nil)
        #expect(Grafana.scope(from: "some-other-server") == nil)
    }

    @Test func buildsAServerName() {
        #expect(Grafana.serverName(scope: "edge", environment: "prd") == "grafana-edge-prd")
        #expect(Grafana.serverName(scope: "non-platform", environment: "dev") == "grafana-non-platform-dev")
    }
}
