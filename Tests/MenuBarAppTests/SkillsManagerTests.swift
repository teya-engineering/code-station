import Foundation
import Testing
@testable import MenuBarApp

struct SkillsManagerTests {
    private let scratch = ScratchDirectory(prefix: "marketplace")

    private func file(_ json: String) throws -> URL {
        let url = scratch.path("marketplace-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test @MainActor func keepsMarketplacesAcrossAdditionsAndRestarts() throws {
        let suite = "multiple-marketplaces-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SkillMarketplaceConfiguration(source: "/tmp/first.json", sourceKind: .localFile,
                                                   marketplace: "first", label: "First")
        let second = SkillMarketplaceConfiguration(source: "/tmp/second.json", sourceKind: .localFile,
                                                    marketplace: "second", label: "Second")
        Preferences.setSkillsMarketplace(first, in: defaults)
        let manager = SkillsManager(preferences: defaults)

        try manager.saveMarketplace(second)
        try manager.saveMarketplace(first)
        try manager.saveMarketplace(second)

        let restored = SkillsManager(preferences: defaults)
        #expect(restored.marketplaceConfigurations.contains(first))
        #expect(restored.marketplaceConfigurations.filter { $0 == second }.count == 1)
        #expect(restored.lastRefresh == nil)
    }

    @Test @MainActor func rejectsConflictingMarketplaceNamesWithoutReplacingSavedSource() throws {
        let suite = "conflicting-marketplaces-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = SkillMarketplaceConfiguration(source: "/tmp/original.json", sourceKind: .localFile,
                                                      marketplace: "shared-name", label: "Original")
        let conflict = SkillMarketplaceConfiguration(source: "/tmp/other.json", sourceKind: .localFile,
                                                      marketplace: "shared-name", label: "Other")
        let manager = SkillsManager(preferences: defaults)
        try manager.saveMarketplace(original)

        #expect(throws: ImportError.self) { try manager.saveMarketplace(conflict) }
        #expect(manager.marketplaceConfigurations.contains(original))
        #expect(!manager.marketplaceConfigurations.contains(conflict))
    }

    @Test @MainActor func isolatesRepositoryCachesAndRefreshDates() throws {
        let suite = "marketplace-state-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SkillsManager(cacheURL: scratch.path("caches"), preferences: defaults)
        let first = SkillMarketplaceConfiguration(source: "https://example.com/first.git", sourceKind: .gitRepository,
                                                   marketplace: "first", label: "First")
        let second = SkillMarketplaceConfiguration(source: "https://example.com/second.git", sourceKind: .gitRepository,
                                                    marketplace: "second", label: "Second")
        let refreshed = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(refreshed, forKey: "skillsLastRefresh.first")
        try manager.saveMarketplace(first)
        try manager.saveMarketplace(second)
        #expect(manager.lastRefresh == nil)
        #expect(manager.cacheURL(source: first.source) != manager.cacheURL(source: second.source))
        #expect(manager.cacheURL(source: first.source) == manager.cacheURL(source: first.source))
    }

    @Test @MainActor func combinesPackagesAndKeepsSameNamesDistinct() throws {
        let suite = "combined-marketplaces-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SkillsManager(preferences: defaults)
        let configurations = ["first", "second"].map {
            SkillMarketplaceConfiguration(source: "/tmp/\($0).json", sourceKind: .localFile,
                                          marketplace: $0, label: $0)
        }
        let first = try SkillsManager.decodeMarketplace(Data(#"{"name":"first","plugins":[{"name":"shared","description":"First","version":"2"},{"name":"alpha","description":"Alpha"}]}"#.utf8))
        let second = try SkillsManager.decodeMarketplace(Data(#"{"name":"second","plugins":[{"name":"shared","description":"Second","version":"3"}]}"#.utf8))
        manager.applyCatalogues([
            "first": .init(marketplace: first, notice: nil, didRefresh: true),
            "second": .init(marketplace: second, notice: nil, didRefresh: true)
        ], configurations: configurations)
        #expect(manager.plugins.map(\.id) == ["alpha@first", "shared@first", "shared@second"])
        #expect(manager.plugins.map(\.marketplace) == ["first", "first", "second"])

        let installed = SkillsManager.installedPlugins(from: #"[{"id":"shared@first","version":"1","scope":"user"},{"id":"shared@second","version":"3","scope":"user"}]"#,
                                                       for: .claude, marketplaces: ["first", "second"])
        manager.apply(.init(installations: installed, failure: nil), to: .claude)
        #expect(manager.installation(of: manager.plugins[1], on: .claude)?.version == "1")
        #expect(manager.installation(of: manager.plugins[2], on: .claude)?.version == "3")
        #expect(manager.isOutdated(manager.plugins[1], on: .claude))
        #expect(!manager.isOutdated(manager.plugins[2], on: .claude))
        #expect(manager.installedPluginCount == 2)
        #expect(manager.updateCount == 1)
        #expect(SkillHost.codex.installArguments(plugin: manager.plugins[2].name,
                                                marketplace: manager.plugins[2].marketplace)
            == ["plugin", "add", "shared@second", "--json"])
    }

    @Test @MainActor func failedMarketplaceDoesNotHideOtherPackages() throws {
        let suite = "partial-marketplaces-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SkillsManager(preferences: defaults)
        let configurations = ["working", "broken", "renamed"].map {
            SkillMarketplaceConfiguration(source: "/tmp/\($0).json", sourceKind: .localFile,
                                          marketplace: $0, label: $0)
        }
        let working = try SkillsManager.decodeMarketplace(Data(#"{"name":"working","plugins":[{"name":"package","description":"Works"}]}"#.utf8))
        manager.applyCatalogues([
            "working": .init(marketplace: working, notice: nil, didRefresh: true),
            "broken": .init(marketplace: nil, notice: "Could not read file", didRefresh: false),
            "renamed": .init(marketplace: working, notice: nil, didRefresh: true)
        ], configurations: configurations)
        #expect(manager.plugins.map(\.id) == ["package@working"])
        #expect(manager.catalogueNotice?.contains("broken: Could not read file") == true)
        #expect(manager.catalogueNotice?.contains("renamed: The manifest names a different marketplace") == true)
        #expect(defaults.object(forKey: "skillsLastRefresh.working") != nil)
        #expect(defaults.object(forKey: "skillsLastRefresh.broken") == nil)
        #expect(defaults.object(forKey: "skillsLastRefresh.renamed") == nil)
    }

    @Test(arguments: SkillHost.allCases) func readsInstallationsAcrossMarketplaces(host: SkillHost) {
        let output: String
        switch host {
        case .claude:
            output = #"[{"id":"shared@first","version":"1"},{"id":"shared@second","version":"2"},{"id":"shared@other","version":"9"}]"#
        case .codex:
            output = #"{"installed":[{"pluginId":"shared@first","version":"1"},{"pluginId":"shared@second","version":"2"},{"pluginId":"shared@other","version":"9"}]}"#
        case .copilot:
            output = #"{"plugins":[{"kind":"plugin","name":"shared","source":"marketplace:first","version":"1"},{"kind":"plugin","name":"shared","source":"marketplace:second","version":"2"},{"kind":"plugin","name":"shared","source":"marketplace:other","version":"9"}]}"#
        }
        let installed = SkillsManager.installedPlugins(from: output, for: host, marketplaces: ["first", "second"])
        #expect(installed == ["shared@first": .init(version: "1", enabled: true),
                              "shared@second": .init(version: "2", enabled: true)])
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

        let (configuration, marketplace) = try SkillsManager.localConfiguration(at: url)

        #expect(configuration == SkillMarketplaceConfiguration(
            source: url.standardizedFileURL.path,
            sourceKind: .localFile,
            marketplace: "local-engineering",
            label: "local-engineering"))
        #expect(marketplace.plugins.map(\.name) == ["backend-specialist"])
    }

    @Test func siteConfigurationKeepsALocalMarketplaceSource() {
        let skills = SiteDefaults.Skills(name: "Local Engineering",
                                         marketplace: "local-engineering",
                                         repository: "/tmp/marketplace.json",
                                         sourceKind: .localFile)

        #expect(SkillMarketplaceConfiguration.siteDefault(skills)
            == SkillMarketplaceConfiguration(source: "/tmp/marketplace.json",
                                              sourceKind: .localFile,
                                              marketplace: "local-engineering",
                                              label: "Local Engineering"))
    }

    @Test func rejectsInvalidLocalMarketplaceFile() throws {
        let url = try file(#"{ "plugins": [] }"#)

        #expect(throws: ImportError.self) {
            try SkillsManager.localConfiguration(at: url)
        }
    }

    @Test func clonesAndReadsAGitMarketplace() async throws {
        let repository = try GitRepo(initialCommit: false)
        try repository.write(".claude-plugin/marketplace.json",
                             #"{ "name": "git-engineering", "plugins": [] }"#)
        try repository.commit("Add marketplace")
        let cache = scratch.path("cache")

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

    @Test func readsMarketplaceNamesFromEveryCLIShape() {
        let claude = #"[{"name":"example-engineering"},{"name":"official"}]"#
        let codex = #"{"marketplaces":[{"name":"example-engineering"}]}"#
        let copilot = """
        Included with GitHub Copilot:
          ◆ copilot-plugins (GitHub: github/copilot-plugins)
          ◆ awesome-copilot (GitHub: github/awesome-copilot)

        Registered marketplaces:
          • example-engineering (URL: https://github.com/example/claude-plugins)
        """

        #expect(SkillsManager.marketplaceNames(from: claude) ==
                Set(["example-engineering", "official"]))
        #expect(SkillsManager.marketplaceNames(from: codex) ==
                Set(["example-engineering"]))
        #expect(SkillsManager.marketplaceNames(from: copilot) ==
                Set(["copilot-plugins", "awesome-copilot", "example-engineering"]))
    }

    // Copilot lists plugins among everything else it has configured, so only the
    // plugin rows from the marketplace count.
    @Test func readsCopilotInstallationsOutOfItsMixedList() {
        let output = """
        {
          "plugins": [
            {"kind": "plugin", "name": "backend-specialist", "scope": "user",
             "source": "marketplace:example-engineering", "enabled": false, "version": "1.9.1"},
            {"kind": "plugin", "name": "other", "scope": "user",
             "source": "marketplace:elsewhere", "enabled": true, "version": "1.0.0"},
            {"kind": "skill", "name": "backend-specialist", "scope": "plugin", "source": "plugin", "enabled": true},
            {"kind": "mcp", "name": "github", "scope": "user", "source": "user", "enabled": true}
          ],
          "errors": []
        }
        """

        let installed = SkillsManager.installedPlugins(from: output, for: .copilot,
                                                       marketplace: "example-engineering")

        #expect(installed == [
            "backend-specialist": SkillInstallation(version: "1.9.1", enabled: false)
        ])
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
        #expect(SkillHost.copilot.listArguments == ["plugins", "list", "--json"])
        #expect(SkillHost.copilot.installArguments(plugin: "backend-specialist",
                                                   marketplace: marketplace) == [
            "plugin", "install", "backend-specialist@example-engineering"
        ])
        #expect(SkillHost.copilot.removeArguments(plugin: "backend-specialist",
                                                  marketplace: marketplace) == [
            "plugin", "uninstall", "backend-specialist@example-engineering"
        ])
        #expect(SkillHost.copilot.updateArguments(plugin: "backend-specialist",
                                                  marketplace: marketplace) == [
            "plugin", "update", "backend-specialist@example-engineering"
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
