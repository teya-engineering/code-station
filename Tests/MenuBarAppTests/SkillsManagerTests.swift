import Foundation
import Testing
@testable import MenuBarApp

struct SkillsManagerTests {
    private func file(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marketplace-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test func decodesMarketplacePackages() throws {
        let data = Data("""
        {
          "name": "example-engineering",
          "description": "Engineering skills",
          "plugins": [
            {
              "name": "backend-specialist",
              "description": "Backend help",
              "version": "1.9.1",
              "source": "./plugins/backend-specialist",
              "category": "development"
            }
          ]
        }
        """.utf8)

        let marketplace = try SkillsManager.decodeMarketplace(data)

        #expect(marketplace.name == "example-engineering")
        #expect(marketplace.plugins == [
            SkillMarketplace.Plugin(name: "backend-specialist",
                                    description: "Backend help",
                                    version: "1.9.1",
                                    category: "development")
        ])
    }

    @Test func buildsConfigurationFromLocalMarketplaceFile() throws {
        let url = try file("""
        {
          "name": "local-engineering",
          "plugins": [
            {
              "name": "backend-specialist",
              "description": "Backend help",
              "version": "2.0.0"
            }
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let (configuration, marketplace) = try SkillsManager.localConfiguration(at: url)

        #expect(configuration == SkillMarketplaceConfiguration(
            source: url.standardizedFileURL.path,
            sourceKind: .localFile,
            marketplace: "local-engineering",
            label: "local-engineering"))
        #expect(marketplace.plugins.map(\.name) == ["backend-specialist"])
    }

    @Test func rejectsInvalidLocalMarketplaceFile() throws {
        let url = try file(#"{ "plugins": [] }"#)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ImportError.self) {
            try SkillsManager.localConfiguration(at: url)
        }
    }

    @Test func clonesAndReadsAGitMarketplace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-marketplace-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("source", isDirectory: true)
        let manifest = repository.appendingPathComponent(".claude-plugin/marketplace.json")
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{ "name": "git-engineering", "plugins": [] }"#.utf8)
            .write(to: manifest)
        try runGit(["init", "--quiet"], in: repository)
        try runGit(["add", "."], in: repository)
        try runGit(["-c", "user.name=Code Station Tests",
                    "-c", "user.email=tests@example.test",
                    "-c", "commit.gpgsign=false",
                    "commit", "--quiet", "-m", "Add marketplace"], in: repository)

        let load = await SkillsManager.loadGitCatalogue(source: repository.path, at: cache)

        #expect(load.marketplace?.name == "git-engineering")
        #expect(load.notice == nil)
        #expect(load.didRefresh)
        #expect(FileManager.default.fileExists(
            atPath: cache.appendingPathComponent(".git").path))
    }

    @Test func readsClaudeUserInstallationsFromJSONArray() {
        let output = """
        [
          {
            "id": "backend-specialist@example-engineering",
            "version": "1.8.0",
            "scope": "user",
            "enabled": true
          },
          {
            "id": "documentation-specialist@example-engineering",
            "version": "1.0.2",
            "scope": "project",
            "enabled": true
          },
          {
            "id": "other@another-marketplace",
            "version": "2.0.0",
            "scope": "user",
            "enabled": true
          }
        ]
        """

        let installed = SkillsManager.installedPlugins(from: output, for: .claude,
                                                       marketplace: "example-engineering")

        #expect(installed == [
            "backend-specialist": SkillInstallation(version: "1.8.0", enabled: true)
        ])
    }

    @Test func readsCodexInstallationsPastCLIWarnings() {
        let output = """
        WARNING: aliases were not updated
        {
          "installed": [
            {
              "pluginId": "backend-specialist@example-engineering",
              "name": "backend-specialist",
              "marketplaceName": "example-engineering",
              "version": "1.9.1",
              "installed": true,
              "enabled": false
            }
          ],
          "available": []
        }
        """

        let installed = SkillsManager.installedPlugins(from: output, for: .codex,
                                                       marketplace: "example-engineering")

        #expect(installed == [
            "backend-specialist": SkillInstallation(version: "1.9.1", enabled: false)
        ])
    }

    @Test func readsMarketplaceNamesFromBothCLIShapes() {
        let claude = #"[{"name":"example-engineering"},{"name":"official"}]"#
        let codex = #"{"marketplaces":[{"name":"example-engineering"}]}"#

        #expect(SkillsManager.marketplaceNames(from: claude) ==
                Set(["example-engineering", "official"]))
        #expect(SkillsManager.marketplaceNames(from: codex) ==
                Set(["example-engineering"]))
    }

    @Test func buildsAgentSpecificPluginCommands() {
        let marketplace = "example-engineering"

        #expect(SkillHost.claude.installArguments(plugin: "backend-specialist",
                                                  marketplace: marketplace) == [
            "plugin", "install", "backend-specialist@example-engineering", "--scope", "user"
        ])
        #expect(SkillHost.claude.updateArguments(plugin: "backend-specialist",
                                                 marketplace: marketplace) == [
            "plugin", "update", "backend-specialist@example-engineering", "--scope", "user"
        ])
        #expect(SkillHost.codex.installArguments(plugin: "backend-specialist",
                                                 marketplace: marketplace) == [
            "plugin", "add", "backend-specialist@example-engineering", "--json"
        ])
        #expect(SkillHost.codex.removeArguments(plugin: "backend-specialist",
                                                marketplace: marketplace) == [
            "plugin", "remove", "backend-specialist@example-engineering", "--json"
        ])
    }

    @Test func detectsOnlyKnownDifferentVersionsAsOutdated() {
        #expect(SkillsManager.isOutdated(installedVersion: "1.8.0",
                                         latestVersion: "1.9.1"))
        #expect(!SkillsManager.isOutdated(installedVersion: "1.9.1",
                                          latestVersion: "1.9.1"))
        #expect(!SkillsManager.isOutdated(installedVersion: "unknown",
                                          latestVersion: "1.9.1"))
        #expect(!SkillsManager.isOutdated(installedVersion: nil,
                                          latestVersion: "1.9.1"))
    }

    @Test func schedulesAutomaticRefreshesAtTheChosenInterval() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(!SkillsRefreshInterval.never.shouldRefresh(lastRefresh: nil, now: now))
        #expect(SkillsRefreshInterval.oneDay.shouldRefresh(lastRefresh: nil, now: now))
        #expect(!SkillsRefreshInterval.oneDay.shouldRefresh(
            lastRefresh: now.addingTimeInterval(-86_399), now: now))
        #expect(SkillsRefreshInterval.oneDay.shouldRefresh(
            lastRefresh: now.addingTimeInterval(-86_400), now: now))
        #expect(!SkillsRefreshInterval.fiveDays.shouldRefresh(
            lastRefresh: now.addingTimeInterval(-4 * 86_400), now: now))
        #expect(SkillsRefreshInterval.fiveDays.shouldRefresh(
            lastRefresh: now.addingTimeInterval(-5 * 86_400), now: now))
        #expect(!SkillsRefreshInterval.thirtyDays.shouldRefresh(
            lastRefresh: now.addingTimeInterval(-29 * 86_400), now: now))
        #expect(SkillsRefreshInterval.thirtyDays.shouldRefresh(
            lastRefresh: now.addingTimeInterval(-30 * 86_400), now: now))
    }
}
