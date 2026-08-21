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

    @Test func validatesEditedConfigurationWithoutRewritingIt() throws {
        let text = """
        {
          "environments": [{ "name": "dev", "title": "Development" }],
          "future": { "kept": true }
        }
        """

        let data = try SiteConfigurationImporter.editedData(text)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(String(decoding: data, as: UTF8.self) == text)
        #expect((root["future"] as? [String: Bool])?["kept"] == true)
    }

    @Test func rejectsEmptyAndMalformedEdits() {
        #expect(throws: ImportError.self) {
            try SiteConfigurationImporter.editedData("  \n")
        }
        #expect(throws: ImportError.self) {
            try SiteConfigurationImporter.editedData(#"{ "environments": [ }"#)
        }
    }

    @Test @MainActor func appliesImportedDefaultsToEmptyFirstRunStores() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("team.json")
        let defaults = try SiteDefaults.decode(Data("""
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
        """.utf8), from: source)

        let dispatch = DispatchStore(storeURL: root.appendingPathComponent("dispatch.json"))
        let shortcuts = ShortcutStore(storageURL: root.appendingPathComponent("shortcuts.json"))
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
}
