import Foundation
import Testing
@testable import MenuBarApp

struct SiteConfigurationImporterTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-configuration-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func importedDefaults(in root: URL) throws -> SiteDefaults {
        try SiteDefaults.decode(Data("""
        {
          "dispatch": {
            "oauth": {
              "tokenURL": "https://id.example/token",
              "clientID": "code-station"
            },
            "requests": [
              { "name": "Health", "method": "GET", "url": "https://api.example/health" }
            ]
          },
          "shortcuts": [
            { "name": "Run service", "command": "./gradlew bootRun" }
          ]
        }
        """.utf8), from: root.appendingPathComponent("team.json"))
    }

    @Test func acceptsARepositoryURLAndNormalisesItsCloneAddress() throws {
        let full = try SiteConfigurationImporter.GitHubRepository(
            "https://github.com/example/site-settings")
        let short = try SiteConfigurationImporter.GitHubRepository(
            "github.com/example/site-settings.git")

        #expect(full == short)
        #expect(full.label == "example/site-settings")
        #expect(full.cloneURL
            == "https://github.com/example/site-settings.git")
    }

    @Test func rejectsGitHubLinksThatDoNotNameARepository() {
        #expect(throws: ImportError.self) {
            try SiteConfigurationImporter.GitHubRepository(
                "https://github.com/example/site-settings/blob/main/teya-defaults.json")
        }
        #expect(throws: ImportError.self) {
            try SiteConfigurationImporter.GitHubRepository("https://example.com/team/settings")
        }
    }

    @Test func prefersTheNamedSiteConfiguration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.appendingPathComponent("site-defaults.json")
        try Data("{}".utf8).write(to: canonical)
        try Data("{}".utf8).write(to: root.appendingPathComponent("something-else.json"))

        #expect(try SiteConfigurationImporter.configurationFile(in: root).standardizedFileURL.path
            == canonical.standardizedFileURL.path)
    }

    @Test func acceptsTheOnlyJSONFileInARepository() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("company.json")
        try Data("{}".utf8).write(to: file)
        try Data("notes".utf8).write(to: root.appendingPathComponent("README.md"))

        #expect(try SiteConfigurationImporter.configurationFile(in: root).standardizedFileURL.path
            == file.standardizedFileURL.path)
    }

    @Test func rejectsAnAmbiguousRepository() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("first.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("second.json"))

        #expect(throws: ImportError.self) {
            try SiteConfigurationImporter.configurationFile(in: root)
        }
    }

    @Test func validatesAndSummarisesALocalConfiguration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("team.json")
        try Data("""
        {
          "dispatch": {
            "requests": [
              { "name": "Health", "method": "GET", "url": "https://api.example/health" }
            ]
          },
          "grafana": {
            "presets": [
              { "scope": "platform", "environment": "prd", "url": "https://grafana.example" }
            ]
          }
        }
        """.utf8).write(to: file)

        let selection = try SiteConfigurationImporter.load(file: file)

        #expect(selection.sourceName == "team.json")
        #expect(selection.defaults.dispatchRequests.map(\.name) == ["Health"])
        #expect(selection.defaults.grafanaPresets.map(\.name) == ["grafana-platform-prd"])
        #expect(selection.summary.contains("1 starter request"))
        #expect(selection.summary.contains("1 Grafana preset"))
    }

    @Test func rejectsAMalformedLocalConfiguration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("broken.json")
        try Data(#"{ "grafana": { "presets": [ {} ] } }"#.utf8).write(to: file)

        #expect(throws: ImportError.self) {
            try SiteConfigurationImporter.load(file: file)
        }
    }

    @Test func encodesTheCurrentConfigurationWithoutRuntimeMetadata() throws {
        let defaults = SiteDefaults(
            environments: [.init(name: "dev", title: "Development")],
            skills: .init(name: "Team", marketplace: "team", repository: "example/skills"),
            loadFailure: "old failure",
            sourceURL: URL(fileURLWithPath: "/tmp/source.json"))

        let data = try SiteConfigurationImporter.configurationData(for: defaults)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(root["environments"] != nil)
        #expect(root["skills"] != nil)
        #expect(root["loadFailure"] == nil)
        #expect(root["sourceURL"] == nil)
        #expect(data.last == 0x0A)
    }

    @Test func exportedJSONIncludesTheEnvironmentsTheAppIsUsing() throws {
        let data = try SiteConfigurationImporter.configurationData(for: SiteDefaults())
        let exported = try SiteDefaults.decode(data, from: URL(fileURLWithPath: "/tmp/export.json"))

        #expect(exported.environments == SiteDefaults.ownEnvironments)
    }

    @Test func resetWritesACompleteMergeOfSelectedAndCurrentAspects() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("current.json")
        let current = try SiteDefaults.decode(Data("""
        {
          "environments": [{ "name": "local" }],
          "skills": { "name": "Personal", "marketplace": "personal", "repository": "personal/repo" },
          "shortcuts": [{ "name": "Personal", "command": "make personal" }]
        }
        """.utf8), from: destination)
        let selection = try SiteConfigurationImporter.load(file: {
            let file = root.appendingPathComponent("team.json")
            try Data("""
            {
              "skills": { "name": "Team", "marketplace": "team", "repository": "team/repo" },
              "shortcuts": [{ "name": "Team", "command": "make team" }]
            }
            """.utf8).write(to: file)
            return file
        }())

        let reset = try SiteConfigurationImporter.reset(selection,
                                                        aspects: [.skills],
                                                        current: current,
                                                        at: destination)
        let written = SiteDefaults.load([destination])

        #expect(reset.environments?.map(\.name) == ["local"])
        #expect(reset.skills?.name == "Team")
        #expect(reset.commandShortcuts.map(\.name) == ["Personal"])
        #expect(written == reset)
    }

    @Test @MainActor func appliesImportedDefaultsToEmptyPersistedStores() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try importedDefaults(in: root)

        let dispatchURL = root.appendingPathComponent("dispatch.json")
        try JSONEncoder().encode(SavedRequestCollection(folders: [.default]))
            .write(to: dispatchURL)
        let dispatch = DispatchStore(storeURL: dispatchURL, siteDefaults: SiteDefaults())

        let shortcutsURL = root.appendingPathComponent("shortcuts.json")
        try Data(#"{ "shortcuts": [] }"#.utf8).write(to: shortcutsURL)
        let shortcuts = ShortcutStore(storageURL: shortcutsURL)
        let keychain = KeychainClient(read: { [:] }, write: { _ in })
        let auth = DispatchAuthStore(storeURL: root.appendingPathComponent("auth.json"),
                                     keychain: keychain)

        dispatch.applySiteDefaults(defaults)
        shortcuts.applySiteDefaults(defaults)
        auth.applySiteDefaults(defaults)

        #expect(dispatch.requests.map(\.name) == ["Health"])
        #expect(shortcuts.shortcuts.map(\.name) == ["Run service"])
        #expect(auth.staging.clientID == "code-station")
        #expect(auth.production.tokenURL == "https://id.example/token")
        _ = auth.save()
    }

    @Test @MainActor func replacesUnsavedDefaultsWhenNoStoreExists() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try importedDefaults(in: root)

        let dispatch = DispatchStore(storeURL: root.appendingPathComponent("dispatch.json"),
                                     siteDefaults: SiteDefaults())
        let shortcuts = ShortcutStore(storageURL: root.appendingPathComponent("shortcuts.json"))

        dispatch.applySiteDefaults(defaults)
        shortcuts.applySiteDefaults(defaults)

        #expect(dispatch.requests.map(\.name) == ["Health"])
        #expect(shortcuts.shortcuts.map(\.name) == ["Run service"])
    }

    @Test @MainActor func mergesImportedDefaultsIntoExistingStoresOnce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try importedDefaults(in: root)

        let dispatchURL = root.appendingPathComponent("dispatch.json")
        try JSONEncoder().encode(SavedRequestCollection(folders: [.default]))
            .write(to: dispatchURL)
        let dispatch = DispatchStore(storeURL: dispatchURL, siteDefaults: SiteDefaults())
        dispatch.add(SavedRequest(name: "Personal", url: "https://personal.example"))

        let shortcutsURL = root.appendingPathComponent("shortcuts.json")
        try Data(#"{ "shortcuts": [] }"#.utf8).write(to: shortcutsURL)
        let shortcuts = ShortcutStore(storageURL: shortcutsURL)
        _ = shortcuts.add(name: "Personal", command: "make personal")

        let authURL = root.appendingPathComponent("auth.json")
        let keychain = KeychainClient(read: { [:] }, write: { _ in })
        let auth = DispatchAuthStore(storeURL: authURL, keychain: keychain)
        var staging = auth.staging
        staging.clientID = "personal"
        staging.clientSecret = "staging-secret"
        staging.state = "personal-state"
        staging.headerPrefix = "Token"
        staging.clientAuth = .basicHeader
        auth.setConfig(staging, for: .staging)
        _ = auth.save()

        for _ in 0..<2 {
            dispatch.applySiteDefaults(defaults)
            shortcuts.applySiteDefaults(defaults)
            auth.applySiteDefaults(defaults)
        }

        #expect(dispatch.requests.map(\.name) == ["Personal", "Health"])
        #expect(shortcuts.shortcuts.map(\.name) == ["Personal", "Run service"])
        #expect(auth.staging.clientID == "code-station")
        #expect(auth.staging.clientSecret == "staging-secret")
        #expect(auth.staging.state == "personal-state")
        #expect(auth.staging.headerPrefix == "Token")
        #expect(auth.staging.clientAuth == .basicHeader)
        #expect(DispatchStore(storeURL: dispatchURL,
                              siteDefaults: SiteDefaults()).requests.map(\.name)
            == ["Personal", "Health"])
        #expect(ShortcutStore(storageURL: shortcutsURL).shortcuts.map(\.name)
            == ["Personal", "Run service"])
    }

    @Test @MainActor func importsPersistedSiteRequestsOnlyOnce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try importedDefaults(in: root)
        let dispatchURL = root.appendingPathComponent("dispatch.json")
        try JSONEncoder().encode(SavedRequestCollection(folders: [.default]))
            .write(to: dispatchURL)

        let imported = DispatchStore(storeURL: dispatchURL, siteDefaults: defaults)
        #expect(imported.requests.map(\.name) == ["Health"])

        imported.remove(try #require(imported.requests.first?.id))

        let reloaded = DispatchStore(storeURL: dispatchURL, siteDefaults: defaults)
        #expect(reloaded.requests.isEmpty)
    }

    @Test @MainActor func explicitResetReplacesSiteRequestsAndKeepsPersonalOnes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try SiteDefaults.decode(Data("""
        { "dispatch": { "requests": [
          { "name": "First", "url": "https://first.example" }
        ] } }
        """.utf8), from: root.appendingPathComponent("first.json"))
        let second = try SiteDefaults.decode(Data("""
        { "dispatch": { "requests": [
          { "name": "Second", "url": "https://second.example" }
        ] } }
        """.utf8), from: root.appendingPathComponent("second.json"))
        let store = DispatchStore(storeURL: root.appendingPathComponent("dispatch.json"),
                                  siteDefaults: first)
        store.applySiteDefaults(first)
        store.add(SavedRequest(name: "Personal", url: "https://personal.example"))

        #expect(store.siteConfigurationRequests.map(\.name) == ["First"])

        store.resetSiteRequests(to: second)

        #expect(store.requests.map(\.name) == ["Personal", "Second"])
        #expect(store.siteConfigurationRequests.map(\.name) == ["Second"])
    }

    @Test @MainActor func explicitResetReplacesSiteShortcutsAndKeepsPersonalOnes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SiteDefaults(shortcuts: [.init(name: "First", command: "make first")])
        let second = SiteDefaults(shortcuts: [.init(name: "Second", command: "make second")])
        let url = root.appendingPathComponent("shortcuts.json")
        let store = ShortcutStore(storageURL: url)
        store.applySiteDefaults(first)
        _ = store.add(name: "Personal", command: "make personal")

        #expect(store.siteConfigurationShortcuts.map(\.name) == ["First"])

        store.resetSiteShortcuts(to: second)

        #expect(store.shortcuts.map(\.name) == ["Personal", "Second"])
        #expect(store.siteConfigurationShortcuts.map(\.name) == ["Second"])
        #expect(ShortcutStore(storageURL: url).shortcuts.map(\.name)
            == ["Personal", "Second"])
    }
}
