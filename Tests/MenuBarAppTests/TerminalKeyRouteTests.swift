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

    @Test func controlCombinationsGoToTheShell() {
        for letter in ["c", "d", "z", "a", "e"] {
            #expect(TerminalSurface.route(press(letter, .control), claimsKeys: true) == .shell)
        }
    }

    // The app binds Control-F to find in a file. The shell needs it for itself.
    @Test func aControlKeyTheAppBindsElsewhereStillGoesToTheShell() {
        #expect(TerminalSurface.route(press("f", .control), claimsKeys: true) == .shell)
    }

    @Test func escapeAndPlainKeysGoToTheShell() {
        #expect(TerminalSurface.route(press("\u{1b}", [], keyCode: 53), claimsKeys: true) == .shell)
        #expect(TerminalSurface.route(press("\r", [], keyCode: 36), claimsKeys: true) == .shell)
        #expect(TerminalSurface.route(press("q"), claimsKeys: true) == .shell)
        #expect(TerminalSurface.route(press("e", .option), claimsKeys: true) == .shell)
    }

    // Command is the Mac's own, so the Edit menu and the app's shortcuts keep working
    // over a terminal.
    @Test func commandKeysStayWithTheApp() {
        for letter in ["c", "v", "q", "n", "1"] {
            #expect(TerminalSurface.route(press(letter, .command), claimsKeys: true) == .app)
        }
    }

    @Test func theTwoKeysTheTerminalAnswersItself() {
        #expect(TerminalSurface.route(press("k", .command), claimsKeys: true) == .clear)
        #expect(TerminalSurface.route(press("`", .control), claimsKeys: true) == .focusOut)
    }

    // A dialog or a menu is drawn over the terminal and answers Escape and Return
    // itself, so nothing is taken while one is up.
    @Test func nothingIsTakenWhileSomethingIsDrawnOverTheTerminal() {
        #expect(TerminalSurface.route(press("c", .control), claimsKeys: false) == .app)
        #expect(TerminalSurface.route(press("\u{1b}", [], keyCode: 53), claimsKeys: false) == .app)
        #expect(TerminalSurface.route(press("k", .command), claimsKeys: false) == .app)
    }
}
