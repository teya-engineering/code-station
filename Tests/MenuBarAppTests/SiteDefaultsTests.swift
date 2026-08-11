import Foundation
import Testing
@testable import MenuBarApp

// The site file decides what a fresh install starts with, and a build that ships without
// one still has to run, so both halves are pinned down here.
struct SiteDefaultsTests {

    private func file(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-defaults-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func readsEverySection() throws {
        let url = try file("""
        {
          "postman": {
            "oauth": {
              "grant": "clientCredentials",
              "authURL": "https://id.example/authorize",
              "tokenURL": "https://id.example/token",
              "clientID": "abc",
              "scope": "openid"
            },
            "requests": [
              { "name": "List things", "method": "POST", "url": "https://api.example/things" }
            ]
          },
          "grafana": {
            "presets": [
              { "scope": "platform", "environment": "dev",
                "url": "https://grafana.example", "serves": ["dev"] }
            ]
          },
          "skills": {
            "name": "Example Engineering",
            "marketplace": "example-engineering",
            "repository": "https://github.com/example/plugins"
          }
        }
        """)
        let defaults = SiteDefaults.load([url])

        #expect(defaults.loadFailure == nil)
        #expect(defaults.postmanOAuth.grant == .clientCredentials)
        #expect(defaults.postmanOAuth.tokenURL == "https://id.example/token")
        #expect(defaults.postmanOAuth.clientID == "abc")
        // Anything the file leaves out keeps the app's own default.
        #expect(defaults.postmanOAuth.callbackURL == "http://127.0.0.1:8234/callback")

        #expect(defaults.postmanRequests.count == 1)
        #expect(defaults.postmanRequests[0].name == "List things")
        #expect(defaults.postmanRequests[0].method == .post)

        #expect(defaults.grafanaPresets.count == 1)
        #expect(defaults.grafanaPresets[0].name == "grafana-platform-dev")
        #expect(defaults.skills?.marketplace == "example-engineering")
    }

    @Test func missingFileLeavesEverythingEmpty() {
        let missing = URL(fileURLWithPath: "/nowhere/site-defaults.json")
        let defaults = SiteDefaults.load([missing])

        #expect(defaults.loadFailure == nil)
        #expect(defaults.postmanRequests.isEmpty)
        #expect(defaults.grafanaPresets.isEmpty)
        #expect(defaults.skills == nil)
        #expect(defaults.postmanOAuth == OAuthConfig())
    }

    @Test func aBrokenFileIsReportedRatherThanIgnored() throws {
        let url = try file("{ \"grafana\": { \"presets\": [ { \"scope\": \"platform\" } ] } }")
        let defaults = SiteDefaults.load([url])

        #expect(defaults.loadFailure != nil)
        #expect(defaults.grafanaPresets.isEmpty)
    }

    @Test func theFirstFileThatExistsWins() throws {
        let missing = URL(fileURLWithPath: "/nowhere/site-defaults.json")
        let first = try file(#"{ "skills": { "name": "First", "marketplace": "first", "repository": "https://example.test/first" } }"#)
        let second = try file(#"{ "skills": { "name": "Second", "marketplace": "second", "repository": "https://example.test/second" } }"#)

        #expect(SiteDefaults.load([missing, first, second]).skills?.name == "First")
    }

    @Test func anInstanceServesTheEnvironmentsItLists() throws {
        let url = try file("""
        {
          "grafana": {
            "presets": [
              { "scope": "platform", "environment": "prd", "url": "https://a.example",
                "serves": ["prod"] },
              { "scope": "shared", "environment": "shared", "url": "https://b.example",
                "serves": ["dev", "prod"] },
              { "scope": "edge", "environment": "dev", "url": "https://c.example" }
            ]
          }
        }
        """)
        let defaults = SiteDefaults.load([url])

        let platform = try #require(defaults.grafanaPreset(named: "grafana-platform-prd"))
        #expect(platform.serves("prod"))
        #expect(!platform.serves("dev"))

        let shared = try #require(defaults.grafanaPreset(named: "grafana-shared-shared"))
        #expect(shared.serves("dev"))
        #expect(shared.serves("prod"))

        // Listing nothing means the instance is offered everywhere.
        let edge = try #require(defaults.grafanaPreset(named: "grafana-edge-dev"))
        #expect(edge.serves("dev"))
        #expect(edge.serves("prod"))
    }

    // A typo here would only show up as an app that quietly starts with nothing set up.
    @Test func theFileShippedWithTheAppParses() throws {
        let url = try #require(SiteDefaults.bundledURL)
        let defaults = SiteDefaults.load([url])

        #expect(defaults.loadFailure == nil)
    }

    @Test func serverNamesAreReadBackWithoutTheSiteFile() {
        #expect(Grafana.environment(from: "grafana-platform-dev") == "dev")
        #expect(Grafana.environment(from: "grafana-shared-shared") == "shared")
        #expect(Grafana.environment(from: "grafana-platform") == nil)
        #expect(Grafana.environment(from: "some-other-server") == nil)
    }
}
