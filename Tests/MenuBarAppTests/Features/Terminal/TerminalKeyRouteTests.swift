import AppKit
import Testing
@testable import MenuBarApp

// Which keys reach the shell. A terminal is only usable if the window stops answering
// for it, so the split between the app's keys and the shell's is worth pinning down.
@MainActor
struct TerminalKeyRouteTests {

    private func press(_ characters: String, _ flags: NSEvent.ModifierFlags = [],
                       keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    private func route(_ event: NSEvent, claimsKeys: Bool = true,
                       drawerKeys: KeyCombo? = AppCommand.terminal.info.keys) -> TerminalSurface.KeyRoute {
        TerminalSurface.route(event, claimsKeys: claimsKeys, drawerKeys: drawerKeys)
    }

    @Test func controlCombinationsGoToTheShell() {
        for letter in ["c", "d", "z", "a", "e"] {
            #expect(route(press(letter, .control)) == .shell)
        }
    }

    // The app binds Control-F to find in a file. The shell needs it for itself.
    @Test func aControlKeyTheAppBindsElsewhereStillGoesToTheShell() {
        #expect(route(press("f", .control)) == .shell)
    }

    @Test func escapeAndPlainKeysGoToTheShell() {
        #expect(route(press("\u{1b}", [], keyCode: 53)) == .shell)
        #expect(route(press("\r", [], keyCode: 36)) == .shell)
        #expect(route(press("q")) == .shell)
        #expect(route(press("e", .option)) == .shell)
    }

    // Command is the Mac's own, so the Edit menu and the app's shortcuts keep working
    // over a terminal.
    @Test func commandKeysStayWithTheApp() {
        for letter in ["c", "v", "q", "n", "1"] {
            #expect(route(press(letter, .command)) == .app)
        }
    }

    @Test func clearingTheScreenIsTheOneCommandKeyTheTerminalAnswers() {
        #expect(route(press("k", .command)) == .clear)
    }

    // The drawer's key is how the shell is left, so the terminal answers it itself
    // rather than leaving it for a button the screen may not have.
    @Test func theDrawerKeyPutsTheDrawerAway() {
        #expect(route(press("`", .control)) == .drawer)
    }

    // Where backtick is a dead key the press carries no plain character, and it must
    // still be read as the drawer's key rather than typed into the shell.
    @Test func theDrawerKeyIsFoundOnALayoutWhereBacktickIsADeadKey() {
        let deadBacktick = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, characters: "`", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 50)!
        #expect(route(deadBacktick) == .drawer)
    }

    // A key the person has moved follows them into the shell, and the key it used to be
    // goes back to the shell, which has its own uses for it.
    @Test func aChangedDrawerKeyPutsTheDrawerAwayInstead() {
        let moved = KeyCombo("t", .control)
        #expect(route(press("t", .control), drawerKeys: moved) == .drawer)
        #expect(route(press("`", .control), drawerKeys: moved) == .shell)
    }

    // Set to the key that clears the screen, the drawer still wins: otherwise there
    // would be no way out of the shell from the keyboard.
    @Test func theDrawerKeyWinsOverClearingTheScreen() {
        #expect(route(press("k", .command), drawerKeys: KeyCombo("k")) == .drawer)
    }

    // With the key taken away, or no drawer around the shell, nothing in the shell is
    // held back for it, and Command-K clears the screen again.
    @Test func noDrawerKeyLeavesControlBacktickToTheShell() {
        #expect(route(press("`", .control), drawerKeys: nil) == .shell)
        #expect(route(press("k", .command), drawerKeys: nil) == .clear)
    }

    // A dialog or a menu is drawn over the terminal and answers Escape and Return
    // itself, so nothing is taken while one is up.
    @Test func nothingIsTakenWhileSomethingIsDrawnOverTheTerminal() {
        #expect(route(press("c", .control), claimsKeys: false) == .app)
        #expect(route(press("\u{1b}", [], keyCode: 53), claimsKeys: false) == .app)
        #expect(route(press("k", .command), claimsKeys: false) == .app)
    }
}
