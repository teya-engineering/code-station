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
          "dispatch": {
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
          },
          "shortcuts": [
            { "name": "Orders service", "command": "./gradlew bootRun" }
          ]
        }
        """)
        let defaults = SiteDefaults.load([url])

        #expect(defaults.loadFailure == nil)
        #expect(defaults.sourceURL == url)
        #expect(defaults.dispatchOAuth.grant == .clientCredentials)
        #expect(defaults.dispatchOAuth.tokenURL == "https://id.example/token")
        #expect(defaults.dispatchOAuth.clientID == "abc")
        // Anything the file leaves out keeps the app's own default.
        #expect(defaults.dispatchOAuth.callbackURL == "http://127.0.0.1:8234/callback")

        #expect(defaults.dispatchRequests.count == 1)
        #expect(defaults.dispatchRequests[0].name == "List things")
        #expect(defaults.dispatchRequests[0].method == .post)

        #expect(defaults.grafanaPresets.count == 1)
        #expect(defaults.grafanaPresets[0].name == "grafana-platform-dev")
        #expect(defaults.skills?.marketplace == "example-engineering")

        #expect(defaults.commandShortcuts.map(\.name) == ["Orders service"])
        #expect(defaults.commandShortcuts[0].command == "./gradlew bootRun")
    }

    @Test func missingFileLeavesEverythingEmpty() {
        let missing = URL(fileURLWithPath: "/nowhere/site-defaults.json")
        let defaults = SiteDefaults.load([missing])

        #expect(defaults.loadFailure == nil)
        #expect(defaults.dispatchRequests.isEmpty)
        #expect(defaults.grafanaPresets.isEmpty)
        #expect(defaults.skills == nil)
        #expect(defaults.commandShortcuts.isEmpty)
        #expect(defaults.dispatchOAuth == OAuthConfig())
    }

    // {{env}} still has to resolve to something on a build with no file, since the sheet
    // sends requests either way.
    @Test func environmentNamesFallBackToTheAppsOwn() throws {
        let named = try file("""
        { "dispatch": { "environments": { "staging": "test", "production": "live" } } }
        """)
        let values = SiteDefaults.load([named]).dispatchEnvValues
        #expect(values.staging == "test")
        #expect(values.production == "live")

        let half = try file(#"{ "dispatch": { "environments": { "staging": "test" } } }"#)
        #expect(SiteDefaults.load([half]).dispatchEnvValues.production == "prd")

        let none = SiteDefaults().dispatchEnvValues
        #expect(none.staging == "dev")
        #expect(none.production == "prd")
    }

    // The file names no IDs. A shortcut still has to come back as the same one on the
    // next launch, or a running command would lose the row it belongs to.
    @Test func aShortcutKeepsItsIdentityBetweenReads() throws {
        let url = try file("""
        { "shortcuts": [
            { "name": "Build", "command": "swift build" },
            { "name": "Test", "command": "swift test" }
        ] }
        """)

        let first = SiteDefaults.load([url]).commandShortcuts
        let second = SiteDefaults.load([url]).commandShortcuts

        #expect(first == second)
        #expect(first[0].id != first[1].id)
    }

    @Test func readsThePreviousHTTPClientSection() throws {
        let url = try file("""
        {
          "postman": {
            "requests": [
              { "name": "Existing request", "url": "https://api.example/existing" }
            ]
          }
        }
        """)

        let defaults = SiteDefaults.load([url])

        #expect(defaults.dispatchRequests.map(\.name) == ["Existing request"])
    }

    @Test func aBrokenFileIsReportedWhenThereIsNoFallback() throws {
        let url = try file("{ \"grafana\": { \"presets\": [ { \"scope\": \"platform\" } ] } }")
        let defaults = SiteDefaults.load([url])

        #expect(defaults.loadFailure != nil)
        #expect(defaults.loadFailure?.contains("No fallback configuration was available") == true)
        #expect(defaults.sourceURL == nil)
        #expect(defaults.grafanaPresets.isEmpty)
    }

    @Test func aBrokenFileFallsBackToTheNextValidFile() throws {
        let broken = try file("{ \"grafana\": { \"presets\": [ { \"scope\": \"platform\" } ] } }")
        let fallback = try file(#"{ "skills": { "name": "Fallback", "marketplace": "fallback", "repository": "https://example.test/fallback" } }"#)

        let defaults = SiteDefaults.load([broken, fallback])

        #expect(defaults.skills?.name == "Fallback")
        #expect(defaults.sourceURL == fallback)
        #expect(defaults.loadFailure?.contains(broken.path) == true)
        #expect(defaults.loadFailure?.contains("The app loaded \(fallback.path) instead.") == true)
    }

    @Test func theFirstValidFileWins() throws {
        let missing = URL(fileURLWithPath: "/nowhere/site-defaults.json")
        let first = try file(#"{ "skills": { "name": "First", "marketplace": "first", "repository": "https://example.test/first" } }"#)
        let second = try file(#"{ "skills": { "name": "Second", "marketplace": "second", "repository": "https://example.test/second" } }"#)

        #expect(SiteDefaults.load([missing, first, second]).skills?.name == "First")
    }

    @Test func searchOrderHonoursTheEnvironmentAndSavedOverride() {
        let environment = URL(fileURLWithPath: "/tmp/from-environment.json")
        let selected = URL(fileURLWithPath: "/tmp/from-settings.json")
        let bundled = URL(fileURLWithPath: "/tmp/from-bundle.json")

        let paths = SiteDefaults.searchPaths(environmentURL: environment,
                                             savedURL: selected,
                                             bundledURL: bundled)

        #expect(paths == [
            environment,
            selected,
            AppPaths.support.appendingPathComponent(SiteDefaults.fileName),
            bundled
        ])
        #expect(SiteDefaults.searchPaths(environmentURL: selected,
                                         savedURL: selected,
                                         bundledURL: nil).count { $0 == selected } == 1)
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

    // The example is intended to be copied into deployments, so it must stay loadable
    // and complete.
    @Test func theTrackedSettingsExampleParses() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let defaults = SiteDefaults.load([
            root.appendingPathComponent("site-defaults.example.json")
        ])

        #expect(defaults.loadFailure == nil)
        #expect(!defaults.dispatchOAuth.clientID.isEmpty)
        #expect(!defaults.dispatchRequests.isEmpty)
        #expect(!defaults.grafanaPresets.isEmpty)
        #expect(defaults.skills != nil)
        #expect(!defaults.commandShortcuts.isEmpty)
    }

    // No settings are compiled in, so a plain checkout builds an app with no file to fall
    // back on. A build only carries one because `build-app.sh` was given one to fold in.
    @Test func noFileIsShippedWithTheBuild() {
        #expect(SiteDefaults.bundledURL == nil)
    }

    // Settings reads this off the file already in place, so it has to hold for defaults
    // that were never a freshly loaded selection, including the empty ones.
    @Test func theSummaryCountsWhatTheDefaultsHold() throws {
        let url = try file("""
        {
          "dispatch": {
            "requests": [
              { "name": "Health", "url": "https://api.example/health" },
              { "name": "Version", "url": "https://api.example/version" }
            ]
          },
          "grafana": {
            "presets": [
              { "scope": "platform", "environment": "prd", "url": "https://grafana.example" }
            ]
          },
          "skills": { "name": "team", "marketplace": "org/skills", "repository": "org/skills" }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = SiteDefaults.load([url]).summary

        #expect(summary.contains("2 starter requests"))
        #expect(summary.contains("1 Grafana preset"))
        #expect(summary.contains("0 shortcuts"))
        #expect(summary.contains("a skills marketplace"))
    }

    @Test func theSummaryOfEmptyDefaultsSaysEverythingIsMissing() {
        let summary = SiteDefaults().summary

        #expect(summary.contains("0 starter requests"))
        #expect(summary.contains("0 Grafana presets"))
        #expect(summary.contains("no skills marketplace"))
    }

    @Test func serverNamesAreReadBackWithoutTheSiteFile() {
        #expect(Grafana.environment(from: "grafana-platform-dev") == "dev")
        #expect(Grafana.environment(from: "grafana-shared-shared") == "shared")
        #expect(Grafana.environment(from: "grafana-platform") == nil)
        #expect(Grafana.environment(from: "some-other-server") == nil)
    }
}
