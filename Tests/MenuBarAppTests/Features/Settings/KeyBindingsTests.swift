import AppKit
import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct KeyBindingsTests {
    private func press(_ characters: String, _ flags: NSEvent.ModifierFlags = [],
                       keyCode: UInt16 = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    @Test func aCommandStartsOnItsOwnKey() {
        let bindings = KeyBindings()

        #expect(bindings.keys(for: .commandPalette) == KeyCombo("k"))
        #expect(!bindings.isChanged(.commandPalette))
        #expect(!bindings.hasChanges)
    }

    @Test func aChangedKeyReplacesTheOneItStartedWith() {
        var bindings = KeyBindings()
        bindings.set(KeyCombo("p", [.command, .shift]), for: .commandPalette)

        #expect(bindings.keys(for: .commandPalette) == KeyCombo("p", [.command, .shift]))
        #expect(bindings.isChanged(.commandPalette))
    }

    // Setting a key back to where it started is no change at all, so a later version that
    // moves the default still reaches this person.
    @Test func settingTheStartingKeyAgainForgetsTheChange() {
        var bindings = KeyBindings()
        bindings.set(KeyCombo("p"), for: .commandPalette)
        bindings.set(KeyCombo("k"), for: .commandPalette)

        #expect(!bindings.isChanged(.commandPalette))
        #expect(!bindings.hasChanges)
    }

    @Test func aKeyTakenAwayStaysAwayAndCanBeReset() {
        var bindings = KeyBindings()
        bindings.set(nil, for: .findInConversation)

        #expect(bindings.keys(for: .findInConversation) == nil)
        #expect(bindings.isChanged(.findInConversation))

        bindings.reset(.findInConversation)
        #expect(bindings.keys(for: .findInConversation) == KeyCombo("f"))
    }

    @Test func aFixedKeyCannotBeMoved() {
        var bindings = KeyBindings()
        bindings.set(KeyCombo("j"), for: .quit)

        #expect(bindings.keys(for: .quit) == KeyCombo("q"))
        #expect(!bindings.hasChanges)
    }

    @Test func aKeyAnotherWindowCommandHoldsIsRefused() {
        let bindings = KeyBindings()

        #expect(bindings.problem(with: KeyCombo("n"), for: .commandPalette) == .taken(by: "New session"))
        #expect(bindings.problem(with: KeyCombo("q"), for: .commandPalette) == .taken(by: "Quit"))
        #expect(bindings.problem(with: KeyCombo("c"), for: .commandPalette) == .taken(by: "Copy"))
        #expect(bindings.problem(with: KeyCombo("3"), for: .commandPalette) == .taken(by: "Switch tab"))
    }

    // Once a command lets go of a key, another one may take it.
    @Test func aKeyFreedByAnotherCommandCanBeTaken() {
        var bindings = KeyBindings()
        bindings.set(KeyCombo("y"), for: .newSession)

        #expect(bindings.problem(with: KeyCombo("n"), for: .commandPalette) == nil)
    }

    @Test func aCommandMayKeepItsOwnKey() {
        #expect(KeyBindings().problem(with: KeyCombo("k"), for: .commandPalette) == nil)
    }

    // A pane key caught by a monitor is asked before the window's own keys and wins
    // there, so the window may share it, the way Back shares ⌘[ with the preview.
    @Test func aWindowKeyMayShareAPaneKeyThatIsAskedFirst() {
        let bindings = KeyBindings()

        #expect(bindings.problem(with: KeyCombo("["), for: .goBack) == nil)
        #expect(bindings.problem(with: KeyCombo("b"), for: .commandPalette) == nil)
    }

    // Two SwiftUI buttons on one key leave it undefined which one runs.
    @Test func aWindowKeyMayNotTakeAPaneKeyBoundToAButton() {
        #expect(KeyBindings().problem(with: KeyCombo("s"), for: .commandPalette) == .taken(by: "Save the file"))
        #expect(KeyBindings().problem(with: KeyCombo("r"), for: .newSession) == .taken(by: "Use the shortcut on the button"))
    }

    // A sheet is its own window, so its keys never meet the window's.
    @Test func aSheetKeyMayShareAWindowKey() {
        #expect(KeyBindings().problem(with: KeyCombo("n"), for: .findRequest) == nil)
        #expect(KeyBindings().problem(with: KeyCombo("n"), for: .searchDocker) == nil)
    }

    // The Changes tab and the Explorer are never on screen together, but both sit inside
    // a session whose own keys stay live in every tab.
    @Test func paneKeysClashOnlyWhereTheyAreLiveTogether() {
        let bindings = KeyBindings()

        #expect(bindings.problem(with: KeyCombo("b"), for: .findInFile) == nil)
        #expect(bindings.problem(with: KeyCombo("r"), for: .saveFile) == .taken(by: "Use the shortcut on the button"))
        #expect(bindings.problem(with: KeyCombo("h", .control), for: .saveFile) == .taken(by: "Find in files"))
    }

    // A key a command always answers to as well as its main one is still taken.
    @Test func aSecondKeyIsHeldToo() {
        let bindings = KeyBindings()

        #expect(bindings.problem(with: KeyCombo("f", .control), for: .findInFiles) == .taken(by: "Find in the file"))
        #expect(bindings.problem(with: KeyCombo("="), for: .commandPalette) == .taken(by: "Bigger text"))
    }

    @Test func aPaneFindTakesTheFilterKeyOnlyWhileTheyMatch() {
        var bindings = KeyBindings()
        #expect(bindings.takes(.filterSidebar, from: .findInFile))

        bindings.set(KeyCombo("f", [.command, .option]), for: .filterSidebar)
        #expect(!bindings.takes(.filterSidebar, from: .findInFile))

        // The file's find answers ⌃F as well as its main key.
        bindings.set(KeyCombo("f", .control), for: .filterSidebar)
        #expect(bindings.takes(.filterSidebar, from: .findInFile))
    }

    @Test func aTooltipNamesTheKeyOnlyWhenThereIsOne() {
        var bindings = KeyBindings()
        #expect(bindings.tooltip("Commit", for: .commitSelected) == "Commit (⌘⏎)")

        bindings.set(nil, for: .commitSelected)
        #expect(bindings.tooltip("Commit", for: .commitSelected) == "Commit")
    }

    @Test func aHandlerFollowsTheKeysItIsGiven() throws {
        let handler = WindowKeyHandler()
        let press = try self.press("b", .command, keyCode: 11)
        #expect(handler.pressed(.branches, press))

        handler.keyBindings.set(KeyCombo("b", [.command, .option]), for: .branches)
        #expect(!handler.pressed(.branches, press))
        #expect(handler.pressed(.branches, try self.press("b", [.command, .option], keyCode: 11)))
    }

    @Test func aKeyWithoutCommandControlOrOptionIsTyping() {
        let bindings = KeyBindings()

        #expect(bindings.problem(with: KeyCombo("k", []), for: .commandPalette) == .needsModifier)
        #expect(bindings.problem(with: KeyCombo("k", .shift), for: .commandPalette) == .needsModifier)
        #expect(bindings.problem(with: KeyCombo("k", .option), for: .commandPalette) == nil)
    }

    @Test func changesSurviveARelaunch() throws {
        let suite = "KeyBindingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var bindings = KeyBindings()
        bindings.set(KeyCombo("p", [.command, .option]), for: .commandPalette)
        bindings.set(nil, for: .dictate)
        Preferences.setKeyBindings(bindings, in: defaults)

        #expect(Preferences.keyBindings(in: defaults) == bindings)

        bindings.resetAll()
        Preferences.setKeyBindings(bindings, in: defaults)
        #expect(defaults.object(forKey: "keyBindings") == nil)
        #expect(Preferences.keyBindings(in: defaults) == KeyBindings())
    }

    // A command dropped or made fixed in a later version must not leave a key behind.
    @Test func savedChangesForUnknownOrFixedCommandsAreDropped() throws {
        let suite = "KeyBindingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let saved: [String: KeyCombo?] = ["gone": KeyCombo("g"), "quit": KeyCombo("j"),
                                          "workingSet": KeyCombo("\\"),
                                          "newSession": KeyCombo("y")]
        defaults.set(try JSONEncoder().encode(saved), forKey: "keyBindings")

        let bindings = Preferences.keyBindings(in: defaults)
        #expect(bindings.keys(for: .newSession) == KeyCombo("y"))
        #expect(bindings.keys(for: .quit) == KeyCombo("q"))
        #expect(bindings.changes.count == 1)
    }

    @Test func aPressReadsAsTheSameKeysItWasRecordedAs() throws {
        #expect(KeyCombo(event: try press("A", [.command, .shift])) == KeyCombo("a", [.command, .shift]))
        #expect(KeyCombo(event: try press("`", .control)) == KeyCombo("`", .control))
        #expect(KeyCombo(event: try press("\u{1b}", keyCode: 53)) == KeyCombo(KeyCombo.escape, []))
        #expect(KeyCombo(event: try press("\r", .command, keyCode: 36)) == KeyCombo(KeyCombo.returnKey))
        // Caps Lock and the function key are not part of a shortcut.
        #expect(KeyCombo(event: try press("k", [.command, .capsLock])) == KeyCombo("k"))
        #expect(KeyCombo("k").matches(try press("k", .command)))
        #expect(!KeyCombo("k").matches(try press("k", [.command, .shift])))
    }

    // On a layout where backtick is a dead key, such as Brazilian - Pro, AppKit leaves
    // the plain character empty and only Control-backtick's typed character holds the mark.
    @Test func aDeadKeyReadsAsTheMarkItTypesWithControl() throws {
        let deadBacktick = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, characters: "`", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 50))
        #expect(KeyCombo(event: deadBacktick) == KeyCombo("`", .control))
    }

    @Test func labelsReadTheWayMacMenusWriteThem() {
        let keys = KeyCombo("a", [.shift, .command, .control])

        #expect(keys.label == "⌃ ⇧ ⌘ A")
        #expect(keys.compactLabel == "⌃⇧⌘A")
        #expect(keys.spokenLabel == "Command-Shift-Control-A")
        #expect(KeyCombo(KeyCombo.returnKey).label == "⌘ ⏎")
        #expect(KeyBindings().label(for: .switchTab) == "⌘ 1 … ⌘ 9")
    }

    // Shift makes the brace out of the bracket key, so AppKit expects the brace without
    // shift in the mask. A letter keeps shift.
    @Test func shiftStaysOnLettersAndLeavesSymbols() {
        #expect(KeyCombo("a", [.command, .shift]).shortcut.modifiers == [.command, .shift])
        #expect(KeyCombo("{", [.command, .shift]).shortcut.modifiers == .command)
    }

    @Test func everyCommandIsListedOnce() {
        let listed = AppCommand.groups.flatMap(\.commands)

        #expect(listed.count == Set(listed).count)
        #expect(Set(listed) == Set(AppCommand.allCases))
    }

    // Two keys the person can change must never start out on the same key.
    @Test func noChangeableCommandStartsOnATakenKey() {
        let bindings = KeyBindings()
        for command in AppCommand.allCases where command.info.canChange {
            guard let keys = command.info.keys else { continue }
            #expect(bindings.problem(with: keys, for: command) == nil, "\(command)")
        }
    }
}
