import Foundation
import Testing
@testable import MenuBarApp

// The sound is read back from a raw string that a user or an older build can have left
// in any shape, so what an unknown or missing value falls back to is pinned down.
struct SessionSoundTests {
    private func freshStore() -> UserDefaults {
        let name = "sound-test-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func playsTheStandardSoundBeforeAnyoneChoosesOne() {
        #expect(Preferences.sessionFinishedSound(in: freshStore()) == .standard)
    }

    @Test func keepsTheChosenSound() {
        let store = freshStore()
        Preferences.setSessionFinishedSound(.submarine, in: store)
        #expect(Preferences.sessionFinishedSound(in: store) == .submarine)
    }

    // Silence is a real choice rather than an absent one, so it must survive the round
    // trip instead of reading back as the standard sound.
    @Test func keepsSilence() {
        let store = freshStore()
        Preferences.setSessionFinishedSound(.off, in: store)
        #expect(Preferences.sessionFinishedSound(in: store) == .off)
    }

    @Test func fallsBackWhenTheStoredNameIsNotOneWeKnow() {
        let store = freshStore()
        store.set("Trumpet", forKey: "sessionFinishedSound")
        #expect(Preferences.sessionFinishedSound(in: store) == .standard)
    }

    // Every name other than the silent one has to match a file in /System/Library/Sounds,
    // since a typo would simply play nothing at all.
    @Test func namesAreSystemSounds() {
        for sound in SessionSound.allCases where sound != .off {
            #expect(FileManager.default.fileExists(
                atPath: "/System/Library/Sounds/\(sound.rawValue).aiff"),
                    "\(sound.rawValue) is not a system sound")
        }
    }
}
