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
          "environments": [
            { "name": "dev", "title": "Dev" },
            { "name": "prd", "title": "Prod", "danger": true }
          ],
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
          "mcp": {
            "presets": [
              {
                "name": "grafana-platform-dev",
                "title": "Grafana platform dev",
                "environment": "dev",
                "command": "mcp-grafana",
                "env": {
                  "GRAFANA_URL": "https://grafana.example",
                  "GRAFANA_SERVICE_ACCOUNT_TOKEN": ""
                }
              }
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

        #expect(defaults.deployEnvironments.map(\.name) == ["dev", "prd"])
        #expect(defaults.deployEnvironments.map(\.label) == ["Dev", "Prod"])
        #expect(defaults.deployEnvironment(named: "prd")?.isDangerous == true)
        #expect(defaults.deployEnvironment(named: "dev")?.isDangerous == false)

        #expect(defaults.mcpPresets.count == 1)
        #expect(defaults.mcpPresets[0].name == "grafana-platform-dev")
        #expect(defaults.mcpPresets[0].env?.first { $0.key == "GRAFANA_URL" }?.value
            == "https://grafana.example")
        #expect(defaults.skills?.marketplace == "example-engineering")

        #expect(defaults.commandShortcuts.map(\.name) == ["Orders service"])
        #expect(defaults.commandShortcuts[0].command == "./gradlew bootRun")
    }

    @Test func missingFileLeavesEverythingEmpty() {
        let missing = URL(fileURLWithPath: "/nowhere/site-defaults.json")
        let defaults = SiteDefaults.load([missing])

        #expect(defaults.loadFailure == nil)
        #expect(defaults.dispatchRequests.isEmpty)
        #expect(defaults.mcpPresets.isEmpty)
        #expect(defaults.skills == nil)
        #expect(defaults.commandShortcuts.isEmpty)
        #expect(defaults.dispatchOAuth == OAuthConfig())
    }

    @Test func previousDispatchAliasesBecomeSharedEnvironments() throws {
        let named = try file("""
        { "dispatch": { "environments": { "staging": "test", "production": "live" } } }
        """)
        let migrated = SiteDefaults.load([named]).deployEnvironments
        #expect(migrated.map(\.name) == ["test", "live"])
        #expect(migrated.map(\.label) == ["Staging", "Production"])
        #expect(migrated.map(\.isDangerous) == [false, true])

        let half = try file(#"{ "dispatch": { "environments": { "staging": "test" } } }"#)
        #expect(SiteDefaults.load([half]).deployEnvironments.map(\.name) == ["test", "prd"])
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
        let url = try file("{ \"mcp\": { \"presets\": [ { \"name\": 42 } ] } }")
        let defaults = SiteDefaults.load([url])

        #expect(defaults.loadFailure != nil)
        #expect(defaults.loadFailure?.contains("No fallback configuration was available") == true)
        #expect(defaults.sourceURL == nil)
        #expect(defaults.mcpPresets.isEmpty)
    }

    @Test func aBrokenFileFallsBackToTheNextValidFile() throws {
        let broken = try file("{ \"mcp\": { \"presets\": [ { \"name\": 42 } ] } }")
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

    // A build with no file still has to offer somewhere to diagnose in, and a file that
    // names an environment badly must not leave the picker empty either.
    @Test func environmentsFallBackToTheAppsOwn() throws {
        #expect(SiteDefaults().deployEnvironments.map(\.name) == ["staging", "production"])
        #expect(SiteDefaults().deployEnvironment(named: "production")?.isDangerous == true)

        let empty = try file(#"{ "environments": [] }"#)
        #expect(SiteDefaults.load([empty]).deployEnvironments.map(\.name)
            == ["staging", "production"])

        let unnamed = try file(#"{ "environments": [{ "name": "" }, { "name": "sbx" }] }"#)
        #expect(SiteDefaults.load([unnamed]).deployEnvironments.map(\.name) == ["sbx"])
        // A file that names no title still reads as a label rather than as a raw tag.
        #expect(SiteDefaults.load([unnamed]).deployEnvironments.map(\.label) == ["Sbx"])
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
        #expect(!defaults.mcpPresets.isEmpty)
        // A preset whose environment nothing names would add servers no diagnosis filters.
        for preset in defaults.mcpPresets {
            #expect(defaults.deployEnvironment(named: preset.environmentTag) != nil)
        }
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
          "mcp": {
            "presets": [
              { "name": "metrics", "environment": "prd", "url": "https://mcp.example" }
            ]
          },
          "skills": { "name": "team", "marketplace": "org/skills", "repository": "org/skills" }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = SiteDefaults.load([url]).summary

        #expect(summary.contains("0 environments"))
        #expect(summary.contains("2 starter requests"))
        #expect(summary.contains("1 MCP preset"))
        #expect(summary.contains("0 shortcuts"))
        #expect(summary.contains("a skills marketplace"))
    }

    @Test func theSummaryOfEmptyDefaultsSaysEverythingIsMissing() {
        let summary = SiteDefaults().summary

        #expect(summary.contains("0 environments"))
        #expect(summary.contains("0 starter requests"))
        #expect(summary.contains("0 MCP presets"))
        #expect(summary.contains("no skills marketplace"))
    }

    @Test func previousGrafanaPresetsBecomeMCPPresets() throws {
        let url = try file("""
        {
          "grafana": {
            "presets": [
              { "scope": "platform", "environment": "dev", "url": "https://grafana.example" }
            ]
          }
        }
        """)

        let preset = try #require(SiteDefaults.load([url]).mcpPresets.first)

        #expect(preset.name == "grafana-platform-dev")
        #expect(preset.command == "mcp-grafana")
        #expect(preset.environmentTag == "dev")
        #expect(preset.env?.contains {
            $0.key == "GRAFANA_SERVICE_ACCOUNT_TOKEN" && $0.value.isEmpty
        } == true)

        let encoded = try SiteConfigurationImporter.configurationData(
            for: SiteDefaults.load([url]))
        let root = try #require(try JSONSerialization.jsonObject(with: encoded)
            as? [String: Any])
        #expect(root["mcp"] != nil)
        #expect(root["grafana"] == nil)
    }

    @Test func serverNamesAreReadBackWithoutTheSiteFile() {
        #expect(Grafana.environment(from: "grafana-platform-dev") == "dev")
        #expect(Grafana.environment(from: "grafana-shared-shared") == "shared")
        #expect(Grafana.environment(from: "grafana-platform") == nil)
        #expect(Grafana.environment(from: "some-other-server") == nil)
    }
}
