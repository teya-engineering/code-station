import Foundation
import Testing
@testable import MenuBarApp

struct SiteConfigurationPlanTests {
    private let file = """
    {
      "dispatch": {
        "oauth": { "tokenURL": "https://id.example/token", "clientID": "code-station" },
        "environments": { "staging": "sbx", "production": "live" },
        "requests": [
          { "name": "Health", "method": "GET", "url": "https://api.example/health" },
          { "name": "Orders", "method": "POST", "url": "https://api.example/orders" }
        ]
      },
      "grafana": {
        "presets": [
          { "scope": "platform", "environment": "prd", "url": "https://one.example" },
          { "scope": "edge", "environment": "prd", "url": "https://two.example" }
        ]
      },
      "skills": { "name": "Team", "marketplace": "team", "repository": "example/skills" },
      "shortcuts": [{ "name": "Run service", "command": "./gradlew bootRun" }]
    }
    """

    private func defaults(_ text: String) throws -> SiteDefaults {
        try SiteDefaults.decode(Data(text.utf8), from: URL(fileURLWithPath: "/tmp/site.json"))
    }

    private func filtered(_ chosen: Set<SiteConfigurationItem>) throws -> SiteDefaults {
        let data = try SiteConfigurationPlan.filter(Data(file.utf8), keeping: chosen)
        return try SiteDefaults.decode(data, from: URL(fileURLWithPath: "/tmp/site.json"))
    }

    @Test func listsEveryPartOfAFileOnceEach() throws {
        let plan = SiteConfigurationPlan(try defaults(file))

        #expect(plan.groups.map(\.title)
            == ["API access", "Starter requests", "Grafana presets", "Skills marketplace", "Shortcuts"])
        #expect(plan.items.count == 8)
        #expect(plan.everything.count == 8)
        #expect(plan.groups[1].items.map(\.title) == ["Health", "Orders"])
        #expect(plan.groups[2].items.map(\.title) == ["grafana-platform-prd", "grafana-edge-prd"])
    }

    @Test func skipsSectionsAFileLeavesOut() throws {
        let plan = SiteConfigurationPlan(try defaults(#"{ "shortcuts": [{ "name": "Build", "command": "make" }] }"#))

        #expect(plan.groups.map(\.title) == ["Shortcuts"])
        #expect(plan.items.map(\.id) == [.shortcut(0)])
    }

    @Test func keepsOnlyTheChosenItems() throws {
        let kept = try filtered([.request(1), .grafanaPreset(0), .shortcut(0)])

        #expect(kept.dispatchRequests.map(\.name) == ["Orders"])
        #expect(kept.grafanaPresets.map(\.name) == ["grafana-platform-prd"])
        #expect(kept.commandShortcuts.map(\.name) == ["Run service"])
        #expect(kept.skills == nil)
        #expect(kept.dispatch?.oauth == nil)
        // An unpicked section keeps the app's own values rather than the file's.
        #expect(kept.dispatchEnvValues == ("dev", "prd"))
    }

    @Test func dropsASectionNothingWasKeptFrom() throws {
        let kept = try filtered([.skills])

        #expect(kept.dispatch == nil)
        #expect(kept.grafana == nil)
        #expect(kept.shortcuts == nil)
        #expect(kept.skills?.name == "Team")
    }

    @Test func keepingEverythingMatchesTheFileItself() throws {
        let plan = SiteConfigurationPlan(try defaults(file))
        let kept = try filtered(plan.everything)

        #expect(kept.dispatchRequests.map(\.name) == ["Health", "Orders"])
        #expect(kept.grafanaPresets.count == 2)
        #expect(kept.dispatchEnvValues == ("sbx", "live"))
        #expect(kept.dispatchOAuth.clientID == "code-station")
        #expect(kept.commandShortcuts.count == 1)
        #expect(kept.skills != nil)
    }

    // A file written before the HTTP client was renamed still names the section "postman".
    @Test func filtersTheOlderNameForTheRequestSection() throws {
        let legacy = """
        {
          "postman": {
            "requests": [
              { "name": "Health", "url": "https://api.example/health" },
              { "name": "Orders", "url": "https://api.example/orders" }
            ]
          }
        }
        """
        let data = try SiteConfigurationPlan.filter(Data(legacy.utf8), keeping: [.request(0)])
        let kept = try SiteDefaults.decode(data, from: URL(fileURLWithPath: "/tmp/site.json"))

        #expect(kept.dispatchRequests.map(\.name) == ["Health"])
    }

    // The app only reads some of what a file may carry, so an import that keeps a section
    // has to hand the section over whole.
    @Test func leavesUnknownKeysInAKeptSection() throws {
        let extended = """
        { "grafana": { "presets": [ { "scope": "a", "environment": "prd", "url": "https://a.example" } ],
                       "notes": "kept" },
          "future": { "anything": true } }
        """
        let data = try SiteConfigurationPlan.filter(Data(extended.utf8), keeping: [.grafanaPreset(0)])
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect((root["grafana"] as? [String: Any])?["notes"] as? String == "kept")
        #expect(root["future"] != nil)
    }

    @Test func refusesAnEmptyChoice() throws {
        let selection = SiteConfigurationSelection(data: Data(file.utf8),
                                                   sourceName: "team.json",
                                                   defaults: try defaults(file))

        #expect(throws: ImportError.self) {
            try SiteConfigurationImporter.install(selection, keeping: [])
        }
    }
}
