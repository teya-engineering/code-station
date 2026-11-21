import Foundation
import Testing
@testable import MenuBarApp

// Real installs hold these entries, so the key and the stored form of each kind of
// preference are pinned against the raw store.
struct PreferenceTests {
    private let store = scratchDefaults()

    @Test func enumIsStoredAsItsRawString() {
        #expect(Preferences.textSize.read(in: store) == .standard)

        Preferences.textSize.write(.large, in: store)
        #expect(store.object(forKey: "textSize") as? String == "large")

        store.set("dark", forKey: "appearance")
        #expect(Preferences.appearance.read(in: store) == .dark)

        store.set("no such appearance", forKey: "appearance")
        #expect(Preferences.appearance.read(in: store) == .system)

        Preferences.agent.write(.codex, in: store)
        #expect(store.object(forKey: "agent") as? String == "codex")
    }

    @Test func numberedEnumIsStoredAsItsRawNumber() {
        #expect(Preferences.sessionMemoryLimit.read(in: store) == .automatic)
        #expect(Preferences.skillsRefreshInterval.read(in: store) == .fiveDays)

        Preferences.sessionMemoryLimit.write(.eightGB, in: store)
        #expect(store.object(forKey: "sessionMemoryLimit") as? Int == 8)

        store.set(16, forKey: "sessionMemoryLimit")
        #expect(Preferences.sessionMemoryLimit.read(in: store) == .sixteenGB)

        store.set(7, forKey: "sessionMemoryLimit")
        #expect(Preferences.sessionMemoryLimit.read(in: store) == .automatic)
    }

    @Test func switchIsStoredAsABoolean() {
        #expect(!Preferences.statsEnabled.read(in: store))

        Preferences.statsEnabled.write(true, in: store)
        #expect(store.object(forKey: "statsEnabled") as? Bool == true)

        store.set(true, forKey: "autoPruneOrphanedWorktrees")
        #expect(Preferences.sweepsOrphanedWorktrees.read(in: store))

        Preferences.sweepsOrphanedWorktrees.write(false, in: store)
        #expect(store.object(forKey: "autoPruneOrphanedWorktrees") as? Bool == false)
    }

    @Test func wholeNumberIsClampedOnTheWayInAndOut() {
        #expect(Preferences.oldSessionDays.read(in: store) == 3)
        #expect(Preferences.sidebarSessionLimit.read(in: store) == 4)
        #expect(Preferences.statsRemovedSessionDays.read(in: store) == 30)

        Preferences.oldSessionDays.write(500, in: store)
        #expect(store.object(forKey: "oldSessionDays") as? Int == 30)

        Preferences.oldSessionDays.write(7, in: store)
        #expect(store.object(forKey: "oldSessionDays") as? Int == 7)

        store.set(0, forKey: "sidebarSessionLimit")
        #expect(Preferences.sidebarSessionLimit.read(in: store) == 2)

        store.set(99, forKey: "sidebarSessionLimit")
        #expect(Preferences.sidebarSessionLimit.read(in: store) == 10)

        store.set(0, forKey: "statsRemovedSessionDays")
        #expect(Preferences.statsRemovedSessionDays.read(in: store) == 0)
    }

    @Test func optionalTextIsStoredAsIsAndRemovedWhenCleared() {
        #expect(Preferences.dismissedAppUpdateVersion.read(in: store) == nil)

        Preferences.dismissedAppUpdateVersion.write("1.2.3", in: store)
        #expect(store.object(forKey: "dismissedAppUpdateVersion") as? String == "1.2.3")

        Preferences.dismissedAppUpdateVersion.write(nil, in: store)
        #expect(store.object(forKey: "dismissedAppUpdateVersion") == nil)

        store.set("/tmp/clones", forKey: "cloneFolder")
        #expect(Preferences.cloneFolder.read(in: store) == "/tmp/clones")

        store.set("bot.png", forKey: "defaultAgentAvatarName")
        #expect(Preferences.defaultAgentAvatarName.read(in: store) == "bot.png")
    }

    @MainActor @Test func resetPutsAppearanceBackAndUndoRestoresIt() {
        let scratch = ScratchDirectory()
        let store = scratch.preferences.store
        let settings = AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: store)
        #expect(settings.appearanceSettings == .standard)

        let chosen = AppearanceSettings(
            appearance: .system, sunlightEnabled: true, sunlightMode: .fixed,
            sunlightNightKelvin: 2700, cursorEffects: CursorEffectsSettings(schedule: .always),
            textSize: .large, messageColour: .stone, timestampFormat: .time,
            timestampScope: .messages, diceBearAvatarStyle: .shapes, sidebarIconSet: .monograms)
        settings.appearanceSettings = chosen
        #expect(store.string(forKey: "textSize") == "large")
        #expect(store.double(forKey: "sunlightNightKelvin") == 2700)

        let beforeReset = settings.appearanceSettings
        settings.resetAppearance()
        #expect(settings.appearanceSettings == .standard)
        #expect(AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: store)
            .appearanceSettings == .standard)

        settings.appearanceSettings = beforeReset
        #expect(settings.appearanceSettings == chosen)
        #expect(AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: store)
            .appearanceSettings == chosen)
    }
}
