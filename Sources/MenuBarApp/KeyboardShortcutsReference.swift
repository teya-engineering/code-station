import Foundation

// One key and what it does. The keys themselves are declared where the action lives, so
// this is a description of them rather than the thing that binds them: a key added to a
// view belongs here too, or nothing on screen will ever say it exists.
struct KeyboardShortcutHelp: Identifiable, Equatable, Sendable {
    let keys: String
    let title: String
    let detail: String

    var id: String { "\(keys):\(title)" }
}

struct KeyboardShortcutGroup: Identifiable, Equatable, Sendable {
    let title: String
    let shortcuts: [KeyboardShortcutHelp]

    var id: String { title }
}

// Every key the app answers, grouped by what a person is trying to do rather than by the
// file the key is bound in. The standard editing keys are left out: they are in the menu
// bar, where every Mac app keeps them, and listing them here would bury the rest.
enum KeyboardShortcutsReference {
    static let groups: [KeyboardShortcutGroup] = [
        KeyboardShortcutGroup(title: "Moving around", shortcuts: [
            KeyboardShortcutHelp(keys: "⌘ [", title: "Back",
                                 detail: "Go to the project, workspace or session you were looking at before."),
            KeyboardShortcutHelp(keys: "⌘ ]", title: "Forward",
                                 detail: "Go the other way again after stepping back."),
            KeyboardShortcutHelp(keys: "⌘ K", title: "Command palette",
                                 detail: "Search everything and jump straight to it."),
            KeyboardShortcutHelp(keys: "⌘ F", title: "Filter the sidebar",
                                 detail: "Open the filter field and start typing a name."),
            KeyboardShortcutHelp(keys: "⇧ ⌘ A", title: "Next one waiting",
                                 detail: "Jump to the first session that needs an answer.")
        ]),
        KeyboardShortcutGroup(title: "Sessions", shortcuts: [
            KeyboardShortcutHelp(keys: "⌘ N", title: "New session",
                                 detail: "Start a session in whatever is selected."),
            KeyboardShortcutHelp(keys: "⌘ 1 … ⌘ 9", title: "Switch tab",
                                 detail: "Open a tab by its place in the row at the top."),
            KeyboardShortcutHelp(keys: "⌃ `", title: "Terminal",
                                 detail: "Open the terminal drawer, then move between the shell and the composer."),
            KeyboardShortcutHelp(keys: "Esc", title: "Stop the turn",
                                 detail: "Call off the agent while it is working.")
        ]),
        KeyboardShortcutGroup(title: "Files", shortcuts: [
            KeyboardShortcutHelp(keys: "⌘ S", title: "Save the file",
                                 detail: "Save the file being edited in the Explorer."),
            KeyboardShortcutHelp(keys: "⌃ F", title: "Find in the file",
                                 detail: "Search the file being edited in the Explorer.")
        ]),
        KeyboardShortcutGroup(title: "The app", shortcuts: [
            KeyboardShortcutHelp(keys: "⌘ ,", title: "Settings",
                                 detail: "Open this window."),
            KeyboardShortcutHelp(keys: "⌘ +", title: "Bigger text",
                                 detail: "Grow the text in conversations, diffs and the terminal."),
            KeyboardShortcutHelp(keys: "⌘ -", title: "Smaller text",
                                 detail: "Shrink it again."),
            KeyboardShortcutHelp(keys: "⌘ 0", title: "Actual size",
                                 detail: "Put the text back to its normal size."),
            KeyboardShortcutHelp(keys: "⌃ ⌘ F", title: "Full screen",
                                 detail: "Fill the screen with the window."),
            KeyboardShortcutHelp(keys: "⌘ W", title: "Close the window",
                                 detail: "The app keeps running in the menu bar."),
            KeyboardShortcutHelp(keys: "⌘ M", title: "Minimise",
                                 detail: "Send the window to the Dock."),
            KeyboardShortcutHelp(keys: "⌘ Q", title: "Quit",
                                 detail: "Close the app and everything running in it.")
        ])
    ]
}
