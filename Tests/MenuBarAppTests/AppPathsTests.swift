import Foundation
import Testing
@testable import MenuBarApp

// Moving the files an older version wrote is the one part of the storage change that can
// lose someone's work, so the rules it follows are pinned down here.
struct AppPathsTests {
    private let scratch = ScratchDirectory()
    private var root: URL { scratch.url }

    @Test func movesWhatAnOlderVersionLeftBehind() throws {
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
        let legacy = root.appendingPathComponent("stale.json")
        let destination = root.appendingPathComponent("current.json")
        try Data("stale".utf8).write(to: legacy)
        try Data("current".utf8).write(to: destination)

        AppPaths.move(legacy, to: destination)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "current")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func doesNothingWhenThereIsNothingToMove() throws {
        let destination = root.appendingPathComponent("projects.json")
        AppPaths.move(root.appendingPathComponent("missing.json"), to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test func savesAndClearsTheSelectedSkillsMarketplace() throws {
        let suite = "skills-marketplace-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marketplace = SkillMarketplaceConfiguration(
            source: "/tmp/marketplace.json",
            sourceKind: .localFile,
            marketplace: "example-engineering",
            label: "example-engineering")

        Preferences.setSkillsMarketplace(marketplace, in: defaults)
        #expect(Preferences.skillsMarketplace(in: defaults) == marketplace)

        Preferences.setSkillsMarketplace(nil, in: defaults)
        #expect(Preferences.skillsMarketplace(in: defaults) == nil)
    }

    @Test func movesTheFirstExistingCandidate() throws {
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

    @Test func abbreviatesOnlyPathsInsideTheHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(home.abbreviatedPath == "~")
        #expect("\(home)/project/file.swift".abbreviatedPath == "~/project/file.swift")
        #expect("\(home)-archive/file.swift".abbreviatedPath == "\(home)-archive/file.swift")
    }

    @Test func findsPathsRelativeToADirectoryAtComponentBoundaries() {
        #expect("/work/project".pathRelative(to: "/work/project") == "")
        #expect("/work/project/Sources/App.swift".pathRelative(to: "/work/project")
                == "Sources/App.swift")
        #expect("/work/project-copy/App.swift".pathRelative(to: "/work/project") == nil)
        #expect("/work/project/App.swift".pathRelative(to: "/") == "work/project/App.swift")
    }

    @Test func restoresEachSidebarItemExpansionState() throws {
        let suite = "code-station-sidebar-tests-\(UUID().uuidString)"
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
        let suite = "code-station-sidebar-group-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Preferences.collapsedSidebarGroups(in: defaults).isEmpty)

        Preferences.setCollapsedSidebarGroups([.tasks, .workspaces], in: defaults)
        #expect(Preferences.collapsedSidebarGroups(in: defaults) == [.tasks, .workspaces])

        Preferences.setCollapsedSidebarGroups([], in: defaults)
        #expect(defaults.object(forKey: "collapsedSidebarGroups") == nil)
    }

    @Test func defaultsAndClampsOldSessionDays() throws {
        let suite = "code-station-old-session-tests-\(UUID().uuidString)"
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

    @Test func defaultsAndMigratesTheOldSessionCleanupPolicy() throws {
        let suite = "code-station-old-session-cleanup-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Preferences.oldSessionCleanupPolicy(in: defaults) == .deleteAll)

        defaults.set(false, forKey: "autoDeleteOldSessions")
        #expect(Preferences.oldSessionCleanupPolicy(in: defaults) == .review)

        defaults.set(true, forKey: "autoDeleteOldSessions")
        #expect(Preferences.oldSessionCleanupPolicy(in: defaults) == .deleteSafe)

        Preferences.setOldSessionCleanupPolicy(.deleteAll, in: defaults)
        #expect(Preferences.oldSessionCleanupPolicy(in: defaults) == .deleteAll)
        #expect(defaults.object(forKey: "autoDeleteOldSessions") == nil)
    }

    @Test @MainActor func appSettingsPersistsTheOldSessionCleanupPolicy() throws {
        let suite = "code-station-app-old-session-cleanup-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let avatar = root.appendingPathComponent("avatar.png")
        let settings = AppSettings(agentAvatarURL: avatar, preferences: defaults)

        #expect(settings.oldSessionCleanupPolicy == .deleteAll)

        settings.oldSessionCleanupPolicy = .review

        #expect(Preferences.oldSessionCleanupPolicy(in: defaults) == .review)
        #expect(AppSettings(agentAvatarURL: avatar, preferences: defaults)
            .oldSessionCleanupPolicy == .review)
    }

    @Test @MainActor func orphanedWorktreeAutoPruningDefaultsOffAndPersists() throws {
        let suite = "code-station-orphan-pruning-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let avatar = root.appendingPathComponent("avatar.png")
        let settings = AppSettings(agentAvatarURL: avatar, preferences: defaults)

        #expect(!settings.autoPruneOrphanedWorktrees)

        settings.autoPruneOrphanedWorktrees = true

        #expect(Preferences.autoPruneOrphanedWorktrees(in: defaults))
        #expect(AppSettings(agentAvatarURL: avatar, preferences: defaults)
            .autoPruneOrphanedWorktrees)
    }

    @Test func defaultsAndClampsTheSidebarSessionLimit() throws {
        let suite = "code-station-sidebar-session-limit-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Preferences.sidebarSessionLimit(in: defaults) == 4)

        for limit in SidebarSessionVisibility.limitRange {
            Preferences.setSidebarSessionLimit(limit, in: defaults)
            #expect(Preferences.sidebarSessionLimit(in: defaults) == limit)
        }

        Preferences.setSidebarSessionLimit(1, in: defaults)
        #expect(Preferences.sidebarSessionLimit(in: defaults) == 2)

        Preferences.setSidebarSessionLimit(11, in: defaults)
        #expect(Preferences.sidebarSessionLimit(in: defaults) == 10)
    }

    @Test func designStaysOffUntilItIsEnabled() throws {
        let suite = "code-station-design-setting-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!Preferences.designEnabled(in: defaults))
        defaults.set(true, forKey: "designEnabled")
        #expect(Preferences.designEnabled(in: defaults))
    }

    @Test @MainActor func sessionRecapsDefaultOffAndPersist() throws {
        let suite = "code-station-recap-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let avatar = root.appendingPathComponent("avatar.png")
        let settings = AppSettings(agentAvatarURL: avatar, preferences: defaults)

        #expect(!Preferences.sessionRecapsEnabled(in: defaults))
        #expect(!settings.sessionRecapsEnabled)

        settings.sessionRecapsEnabled = true

        #expect(Preferences.sessionRecapsEnabled(in: defaults))
        #expect(AppSettings(agentAvatarURL: avatar, preferences: defaults)
            .sessionRecapsEnabled)
    }

    @Test func sessionRecapsRespectTheOldCatchUpOptOut() throws {
        let suite = "code-station-recap-migration-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "sessionResumeBriefsEnabled")

        #expect(!Preferences.sessionRecapsEnabled(in: defaults))
    }

    @Test @MainActor func appSettingsPersistsTheSidebarSessionLimit() throws {
        let suite = "code-station-app-sidebar-session-limit-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let avatar = root.appendingPathComponent("avatar.png")
        let settings = AppSettings(agentAvatarURL: avatar, preferences: defaults)

        #expect(settings.sidebarSessionLimit == 4)

        settings.sidebarSessionLimit = 8
        #expect(Preferences.sidebarSessionLimit(in: defaults) == 8)

        settings.sidebarSessionLimit = 20
        #expect(settings.sidebarSessionLimit == 10)

        let restored = AppSettings(agentAvatarURL: avatar, preferences: defaults)
        #expect(restored.sidebarSessionLimit == 10)
    }

    @Test @MainActor func appSettingsKeepsInjectedPreferenceStoresIsolated() throws {
        let firstSuite = "code-station-app-settings-first-\(UUID().uuidString)"
        let secondSuite = "code-station-app-settings-second-\(UUID().uuidString)"
        let firstDefaults = try #require(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try #require(UserDefaults(suiteName: secondSuite))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
            Appearance.system.apply()
        }
        let avatar = root.appendingPathComponent("avatar.png")

        Preferences.setOldSessionDays(42, in: firstDefaults)
        Preferences.setSkillsRefreshInterval(.oneDay, in: firstDefaults)
        Preferences.setProjectSort(.lastUsed, in: firstDefaults)
        Preferences.setProjectGrouping(.kind, in: firstDefaults)
        Preferences.setTerminalBundleID("com.example.FirstTerminal", in: firstDefaults)
        Preferences.setAppearance(.dark, in: firstDefaults)
        Preferences.setTextSize(.larger, in: firstDefaults)
        Preferences.setDesignEnabled(true, in: firstDefaults)
        Preferences.setMobileAccessEnabled(true, in: firstDefaults)
        Preferences.setShowCost(false, for: .codex, in: firstDefaults)

        let first = AppSettings(agentAvatarURL: avatar, preferences: firstDefaults)
        let second = AppSettings(agentAvatarURL: avatar, preferences: secondDefaults)

        #expect(first.oldSessionDays == 42)
        #expect(first.skillsRefreshInterval == .oneDay)
        #expect(first.projectSort == .lastUsed)
        #expect(first.projectGrouping == .kind)
        #expect(first.terminalBundleID == "com.example.FirstTerminal")
        #expect(first.appearance == .dark)
        #expect(first.textSize == .larger)
        #expect(first.designEnabled)
        #expect(first.mobileAccessEnabled)
        #expect(!first.showsCost(for: .codex))

        #expect(second.oldSessionDays == OldSessions.defaultDays)
        #expect(second.skillsRefreshInterval == .fiveDays)
        #expect(second.projectSort == .name)
        #expect(second.projectGrouping == .flat)
        #expect(second.terminalBundleID == nil)
        #expect(second.appearance == .system)
        #expect(second.textSize == .standard)
        #expect(!second.designEnabled)
        #expect(!second.mobileAccessEnabled)
        #expect(second.showsCost(for: .codex))

        first.oldSessionDays = 21
        first.skillsRefreshInterval = .thirtyDays
        first.projectSort = .name
        first.projectGrouping = .flat
        first.terminalBundleID = "com.example.UpdatedTerminal"
        first.appearance = .light
        first.textSize = .small
        first.designEnabled = false
        first.mobileAccessEnabled = false
        first.setShowsCost(true, for: .codex)

        #expect(Preferences.oldSessionDays(in: firstDefaults) == 21)
        #expect(Preferences.skillsRefreshInterval(in: firstDefaults) == .thirtyDays)
        #expect(Preferences.projectSort(in: firstDefaults) == .name)
        #expect(Preferences.projectGrouping(in: firstDefaults) == .flat)
        #expect(Preferences.terminalBundleID(in: firstDefaults)
                == "com.example.UpdatedTerminal")
        #expect(Preferences.appearance(in: firstDefaults) == .light)
        #expect(Preferences.textSize(in: firstDefaults) == .small)
        #expect(!Preferences.designEnabled(in: firstDefaults))
        #expect(!Preferences.mobileAccessEnabled(in: firstDefaults))
        #expect(Preferences.showCost(for: .codex, in: firstDefaults))

        let restoredSecond = AppSettings(agentAvatarURL: avatar, preferences: secondDefaults)
        #expect(restoredSecond.oldSessionDays == OldSessions.defaultDays)
        #expect(restoredSecond.skillsRefreshInterval == .fiveDays)
        #expect(restoredSecond.projectSort == .name)
        #expect(restoredSecond.projectGrouping == .flat)
        #expect(restoredSecond.terminalBundleID == nil)
        #expect(restoredSecond.appearance == .system)
        #expect(restoredSecond.textSize == .standard)
        #expect(!restoredSecond.designEnabled)
        #expect(!restoredSecond.mobileAccessEnabled)
        #expect(restoredSecond.showsCost(for: .codex))
    }

    @Test @MainActor func appSettingsPersistsSidebarAvatarChoices() throws {
        let suite = "code-station-sidebar-avatar-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let avatar = root.appendingPathComponent("avatar.png")

        let settings = AppSettings(agentAvatarURL: avatar, preferences: defaults)
        #expect(settings.sidebarIconSet == .diceBear)
        #expect(settings.diceBearAvatarStyle == .waves)

        settings.sidebarIconSet = .diceBear
        settings.diceBearAvatarStyle = .landscape

        let restored = AppSettings(agentAvatarURL: avatar, preferences: defaults)
        #expect(restored.sidebarIconSet == .diceBear)
        #expect(restored.diceBearAvatarStyle == .landscape)
    }

    @Test @MainActor func workingSetStartsClosedAndItsDefaultPersists() throws {
        let suite = "code-station-working-set-default-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let avatar = root.appendingPathComponent("avatar.png")
        let settings = AppSettings(agentAvatarURL: avatar, preferences: defaults)

        #expect(!settings.opensWorkingSetByDefault)

        settings.opensWorkingSetByDefault = true

        #expect(Preferences.opensWorkingSetByDefault(in: defaults))
        #expect(AppSettings(agentAvatarURL: avatar, preferences: defaults)
            .opensWorkingSetByDefault)
    }

    @Test func storesAndResetsAnExternalSiteConfigurationPath() throws {
        let suite = "code-station-site-defaults-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = URL(fileURLWithPath: "/tmp/../tmp/team-defaults.json")

        Preferences.setSiteDefaultsURL(selected, in: defaults)

        #expect(Preferences.siteDefaultsURL(in: defaults)?.path == "/tmp/team-defaults.json")

        Preferences.setSiteDefaultsURL(nil, in: defaults)
        #expect(Preferences.siteDefaultsURL(in: defaults) == nil)
        #expect(defaults.object(forKey: "siteDefaultsPath") == nil)
    }

    @Test @MainActor func onboardingIsOnlyCompletedAfterTheWizardFinishes() throws {
        let suite = "code-station-onboarding-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(agentAvatarURL: root.appendingPathComponent("avatar.png"),
                                   preferences: defaults)

        #expect(!settings.hasCompletedOnboarding)
        #expect(!Preferences.hasCompletedOnboarding(in: defaults))
        #expect(settings.shouldShowOnboarding(hasExistingWork: false))

        settings.completeOnboarding()

        #expect(settings.hasCompletedOnboarding)
        #expect(Preferences.hasCompletedOnboarding(in: defaults))

        let restored = AppSettings(agentAvatarURL: root.appendingPathComponent("avatar.png"),
                                   preferences: defaults)
        #expect(restored.hasCompletedOnboarding)
        #expect(!restored.shouldShowOnboarding(hasExistingWork: false))
    }

    @Test @MainActor func existingWorkDoesNotTriggerFirstRunOnboarding() throws {
        let suite = "code-station-onboarding-migration-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(agentAvatarURL: root.appendingPathComponent("avatar.png"),
                                   preferences: defaults)

        #expect(!settings.shouldShowOnboarding(hasExistingWork: true))
        #expect(settings.hasCompletedOnboarding)
        #expect(Preferences.hasCompletedOnboarding(in: defaults))
    }

    @Test func takesOverThePreferencesTheOldBundleIdentifierOwned() throws {
        let previous = "code-station-previous-bundle-\(UUID().uuidString)"
        let suite = "code-station-adopt-tests-\(UUID().uuidString)"
        let old = try #require(UserDefaults(suiteName: previous))
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            old.removePersistentDomain(forName: previous)
            defaults.removePersistentDomain(forName: suite)
        }

        old.set("opus", forKey: "claudeDefaultModel")
        old.set(true, forKey: "hasCompletedOnboarding")
        defaults.set("sonnet", forKey: "claudeDefaultModel")

        AppPaths.adoptDefaults(of: previous, into: defaults)

        // An answer already given under the new name is the newer of the two.
        #expect(defaults.string(forKey: "claudeDefaultModel") == "sonnet")
        #expect(defaults.bool(forKey: "hasCompletedOnboarding"))
    }

    @Test func doesNotBringBackAPreferenceClearedAfterTheRename() throws {
        let previous = "code-station-previous-bundle-\(UUID().uuidString)"
        let suite = "code-station-adopt-once-tests-\(UUID().uuidString)"
        let old = try #require(UserDefaults(suiteName: previous))
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            old.removePersistentDomain(forName: previous)
            defaults.removePersistentDomain(forName: suite)
        }

        old.set(true, forKey: "mobileAccessEnabled")

        AppPaths.adoptDefaults(of: previous, into: defaults)
        #expect(defaults.bool(forKey: "mobileAccessEnabled"))

        defaults.removeObject(forKey: "mobileAccessEnabled")
        AppPaths.adoptDefaults(of: previous, into: defaults)

        #expect(defaults.object(forKey: "mobileAccessEnabled") == nil)
    }

    @Test func carriesTheWholeDataFolderOverToTheNewName() throws {
        let old = root.appendingPathComponent("com.teya.conductor")
        let new = root.appendingPathComponent("com.teya.code-station")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old.appendingPathComponent("projects.json"))

        AppPaths.move(old, to: new)

        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("projects.json").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

}
