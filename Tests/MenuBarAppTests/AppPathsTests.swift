import Foundation
import Testing
@testable import MenuBarApp

// Moving the files an older version wrote is the one part of the storage change that can
// lose someone's work, so the rules it follows are pinned down here.
struct AppPathsTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func movesWhatAnOlderVersionLeftBehind() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent("old/projects.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"projects":[]}"#.utf8).write(to: legacy)

        // The destination folder does not exist yet, which is the first-launch case.
        let destination = root.appendingPathComponent("support/projects.json")
        AppPaths.move(legacy, to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path) == false)
        #expect(try String(contentsOf: destination, encoding: .utf8) == #"{"projects":[]}"#)
    }

    // Whatever is already in the new place is the one being used, so an old file left
    // over from before must not overwrite it.
    @Test func neverOverwritesTheFileInUse() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent("stale.json")
        let destination = root.appendingPathComponent("current.json")
        try Data("stale".utf8).write(to: legacy)
        try Data("current".utf8).write(to: destination)

        AppPaths.move(legacy, to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "current")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func doesNothingWhenThereIsNothingToMove() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("projects.json")
        AppPaths.move(root.appendingPathComponent("missing.json"), to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test func movesTheFirstExistingCandidate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("missing.json")
        let second = root.appendingPathComponent("previous-name.json")
        let third = root.appendingPathComponent("older-location.json")
        let destination = root.appendingPathComponent("current-name.json")
        try Data("previous".utf8).write(to: second)
        try Data("older".utf8).write(to: third)

        AppPaths.move([first, second, third], to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "previous")
        #expect(FileManager.default.fileExists(atPath: second.path) == false)
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    // The app runs from the build folder in development, where there is no bundle to ask.
    @Test func alwaysHasAnIdentifierToFileUnder() {
        #expect(AppPaths.bundleID.isEmpty == false)
        #expect(AppPaths.support.path.hasSuffix(AppPaths.bundleID))
        #expect(AppPaths.support.path.contains("Application Support"))
    }

    @Test func restoresEachSidebarItemExpansionState() throws {
        let suite = "conductor-sidebar-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let collapsedProject = UUID()
        let expandedWorkspace = UUID()

        Preferences.setSidebarExpansion([
            collapsedProject: false,
            expandedWorkspace: true
        ], in: defaults)

        #expect(Preferences.sidebarExpansion(in: defaults) == [
            collapsedProject: false,
            expandedWorkspace: true
        ])
    }

    @Test func remembersWhichSidebarSectionsAreFoldedAway() throws {
        let suite = "conductor-sidebar-group-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Preferences.collapsedSidebarGroups(in: defaults).isEmpty)

        Preferences.setCollapsedSidebarGroups([.tasks, .workspaces], in: defaults)
        #expect(Preferences.collapsedSidebarGroups(in: defaults) == [.tasks, .workspaces])

        Preferences.setCollapsedSidebarGroups([], in: defaults)
        #expect(defaults.object(forKey: "collapsedSidebarGroups") == nil)
    }

    @Test func defaultsAndClampsOldSessionDays() throws {
        let suite = "conductor-old-session-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Preferences.oldSessionDays(in: defaults) == 3)

        for days in [1, 2, 180, 365] {
            defaults.set(days, forKey: "oldSessionDays")
            #expect(Preferences.oldSessionDays(in: defaults) == days)
        }

        defaults.set(0, forKey: "oldSessionDays")
        #expect(Preferences.oldSessionDays(in: defaults) == 1)

        defaults.set(366, forKey: "oldSessionDays")
        #expect(Preferences.oldSessionDays(in: defaults) == 365)
    }

    @Test func storesAndResetsTheChosenSiteConfiguration() throws {
        let suite = "conductor-site-defaults-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = URL(fileURLWithPath: "/tmp/../tmp/team-defaults.json")

        Preferences.setSiteDefaultsURL(selected, in: defaults)

        #expect(Preferences.siteDefaultsURL(in: defaults)?.path == "/tmp/team-defaults.json")

        Preferences.setSiteDefaultsURL(nil, in: defaults)
        #expect(Preferences.siteDefaultsURL(in: defaults) == nil)
        #expect(defaults.object(forKey: "siteDefaultsPath") == nil)
    }

    @Test @MainActor func changingTheSiteConfigurationRequiresARestart() throws {
        let suite = "conductor-site-restart-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.json")
        let replacement = root.appendingPathComponent("replacement.json")
        Preferences.setSiteDefaultsURL(original, in: defaults)
        let settings = AppSettings(agentAvatarURL: root.appendingPathComponent("avatar.png"),
                                   preferences: defaults)

        #expect(settings.siteDefaultsURL == original)
        #expect(!settings.siteDefaultsRestartRequired)

        settings.setSiteDefaultsURL(replacement)
        #expect(settings.siteDefaultsRestartRequired)
        #expect(Preferences.siteDefaultsURL(in: defaults) == replacement)

        settings.setSiteDefaultsURL(nil)
        #expect(settings.siteDefaultsRestartRequired)
        #expect(Preferences.siteDefaultsURL(in: defaults) == nil)

        settings.setSiteDefaultsURL(original)
        #expect(!settings.siteDefaultsRestartRequired)
    }
}
