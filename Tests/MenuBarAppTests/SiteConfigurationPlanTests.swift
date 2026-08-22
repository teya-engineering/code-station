import Foundation
import Testing
@testable import MenuBarApp

struct SiteConfigurationPlanTests {
    private let file = """
    {
      "environments": [
        { "name": "dev", "title": "Dev" },
        { "name": "prd", "title": "Prod", "danger": true }
      ],
      "dispatch": {
        "oauth": { "tokenURL": "https://id.example/token", "clientID": "code-station" },
        "requests": [
          { "name": "Health", "method": "GET", "url": "https://api.example/health" },
          { "name": "Orders", "method": "POST", "url": "https://api.example/orders" }
        ]
      },
      "mcp": {
        "presets": [
          { "name": "one", "environment": "prd", "url": "https://one.example" },
          { "name": "two", "environment": "prd", "command": "mcp-two" }
        ]
      },
      "skills": { "name": "Team", "marketplace": "team", "repository": "example/skills" },
      "shortcuts": [{ "name": "Run service", "command": "./gradlew bootRun" }]
    }
    """

    private func defaults(_ text: String) throws -> SiteDefaults {
        try SiteDefaults.decode(Data(text.utf8), from: URL(fileURLWithPath: "/tmp/site.json"))
    }

    @Test func listsEveryResettableAspectOnce() throws {
        let plan = SiteConfigurationPlan(try defaults(file))

        #expect(plan.aspects == [.environments, .apiAccess, .requests, .mcp,
                                 .skills, .shortcuts])
        #expect(plan.everything == Set(SiteConfigurationAspect.allCases))
    }

    @Test func includesAnExplicitlyEmptyAspect() throws {
        let plan = SiteConfigurationPlan(try defaults(
            #"{ "environments": [], "shortcuts": [] }"#))

        #expect(plan.aspects == [.environments, .shortcuts])
        #expect(SiteConfigurationAspect.shortcuts.detail(in: try defaults(
            #"{ "shortcuts": [] }"#)) == "0 shortcuts")
    }

    @Test func resettingSelectedAspectsKeepsEverythingElseCurrent() throws {
        let current = try defaults("""
        {
          "environments": [{ "name": "local", "title": "Local" }],
          "dispatch": {
            "oauth": { "clientID": "personal" },
            "requests": [{ "name": "Personal", "url": "https://personal.example" }]
          },
          "skills": { "name": "Personal", "marketplace": "personal", "repository": "personal/repo" },
          "shortcuts": [{ "name": "Personal", "command": "make personal" }]
        }
        """)
        let imported = try defaults(file)

        let reset = SiteConfigurationPlan.resetting([.skills, .shortcuts],
                                                    in: current,
                                                    to: imported)

        #expect(reset.environments?.map(\.name) == ["local"])
        #expect(reset.dispatch?.oauth?.clientID == "personal")
        #expect(reset.dispatchRequests.map(\.name) == ["Personal"])
        #expect(reset.skills?.name == "Team")
        #expect(reset.commandShortcuts.map(\.name) == ["Run service"])
    }

    @Test func apiAccessAndRequestsResetIndependently() throws {
        let current = try defaults("""
        {
          "dispatch": {
            "oauth": { "clientID": "personal" },
            "requests": [{ "name": "Personal", "url": "https://personal.example" }]
          }
        }
        """)
        let imported = try defaults(file)

        let access = SiteConfigurationPlan.resetting([.apiAccess],
                                                     in: current,
                                                     to: imported)
        #expect(access.dispatch?.oauth?.clientID == "code-station")
        #expect(access.deployEnvironments.map(\.name) == ["staging", "production"])
        #expect(access.dispatchRequests.map(\.name) == ["Personal"])

        let requests = SiteConfigurationPlan.resetting([.requests],
                                                       in: current,
                                                       to: imported)
        #expect(requests.dispatch?.oauth?.clientID == "personal")
        #expect(requests.deployEnvironments.map(\.name) == ["staging", "production"])
        #expect(requests.dispatchRequests.map(\.name) == ["Health", "Orders"])
    }

    @Test func anEmptyImportedCollectionClearsOnlyThatCollection() throws {
        let current = try defaults(file)
        let imported = try defaults(#"{ "shortcuts": [] }"#)

        let reset = SiteConfigurationPlan.resetting([.shortcuts],
                                                    in: current,
                                                    to: imported)

        #expect(reset.shortcuts?.isEmpty == true)
        #expect(reset.skills?.name == "Team")
        #expect(reset.mcpPresets.count == 2)
    }
}
