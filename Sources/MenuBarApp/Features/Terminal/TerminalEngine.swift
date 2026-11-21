import AppKit

// What a session needs from whatever emulates the terminal: the shell's output going in,
// and a few questions about the screen that output leaves behind. Keeping it this narrow
// is what lets the emulator change without the session or the pty changing with it.
@MainActor
protocol TerminalEngine: AnyObject {
    // The grid the shell is told about when it starts. Later changes reach the shell
    // through the surface's resize callback.
    var gridSize: (columns: Int, rows: Int) { get }
    // The shell turns bracketed paste on once its line editor is ready, so this doubles
    // as the shell saying it is at a prompt.
    var isBracketedPasteOn: Bool { get }
    func feedOutput(_ data: Data)
    // Back to a blank screen, as if the terminal had just been opened.
    func resetScreen()
    // What the screen shows, as plain text.
    func screenText() -> String
}

// A view the shell is typed into directly. While one holds the keyboard, the window's
// own shortcut monitors stand back, since every stroke there belongs to the shell.
@MainActor
protocol TerminalKeyboardResponder: AnyObject {}

// Where one key press goes while the shell holds the keyboard. Command belongs to the
// app, which is where a Mac shortcut lives and what keeps Copy, Paste and Quit working
// over a terminal; everything else belongs to the shell, because Escape, Control-C and
// the rest are how a terminal is driven.
enum TerminalKeyRoute: Equatable {
    case shell
    case app
    case clear
    case drawer

    static func route(_ event: NSEvent, claimsKeys: Bool, drawerKeys: KeyCombo?) -> TerminalKeyRoute {
        guard claimsKeys else { return .app }
        // The drawer's own key is checked first, so it still works when it has been set
        // to a Control key, or to the Command key the shell would otherwise clear with.
        // Nothing else would be left to leave the shell with.
        if drawerKeys?.matches(event) == true { return .drawer }
        let characters = event.charactersIgnoringModifiers
        if event.modifierFlags.contains(.command) {
            // Clearing the screen is the one Command key the shell answers.
            return characters == "k" ? .clear : .app
        }
        return .shell
    }
}
