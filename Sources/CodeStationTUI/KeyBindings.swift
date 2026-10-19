import TerminalKit

// Every key the TUI handles, screen by screen, as the help overlay lists them. The keys
// are real `Key` values, so their names on screen come from one place and cannot be
// misspelt.
//
// Adding a key: handle it in `TUIApp` (or the view it reaches) and add a row to the
// section of the screen it acts on, in the same commit. A key that only acts in some
// states (Esc stopping a turn) gets one row saying when.
//
// A region of the layout (the sidebar, the main pane's screens) or an overlay gets a
// `Place` and a section of its own; keys that work wherever the focus is go in
// `anywhere`.
struct KeyBinding {
    let keys: [Key]
    // Shown in place of the key names where a row covers keys that a list cannot name,
    // such as every printable character.
    var label: String?
    let does: String

    init(_ keys: [Key], _ does: String) {
        self.keys = keys
        self.does = does
    }

    init(label: String, _ does: String) {
        self.keys = []
        self.label = label
        self.does = does
    }

    var keyNames: String { label ?? keys.map(KeyBindings.name(of:)).joined(separator: " ") }
}

struct KeySection {
    let title: String
    let bindings: [KeyBinding]
}

enum KeyBindings {
    // The screens with keys of their own, in the order the overlay lists them after the
    // one it was opened from.
    enum Place: CaseIterable {
        case sidebar, filter, home, palette, menu, confirmation, newSession, transcript, permission, question,
             composer, changes, diff, history, settings,
             tab, find, container, branches, shortcuts, shortcutEditor, explorer, explorerTyping, design, troubleshoot,
             oldSessions,
             help, anywhere
    }

    // Jumps to the next session that needs the person, as the GUI's ⌘⇧A does.
    static let jumpKey = Key.char("a", .ctrl)

    static func section(_ place: Place) -> KeySection {
        switch place {
        case .anywhere: anywhere
        case .sidebar: sidebar
        case .filter: filter
        case .home: home
        case .palette: palette
        case .menu: menu
        case .confirmation: confirmation
        case .newSession: newSession
        case .transcript: transcript
        case .permission: permission
        case .question: question
        case .composer: composer
        case .changes: changes
        case .diff: diff
        case .history: history
        case .settings: settings
        case .tab: tab
        case .find: find
        case .container: container
        case .branches: branches
        case .shortcuts: shortcuts
        case .shortcutEditor: shortcutEditor
        case .explorer: explorer
        case .explorerTyping: explorerTyping
        case .design: design
        case .troubleshoot: troubleshoot
        case .oldSessions: oldSessions
        case .help: help
        }
    }

    // Every section, the one for where the person is first.
    static func sections(from place: Place) -> [KeySection] {
        ([place] + Place.allCases.filter { $0 != place }).map(section)
    }

    static let anywhere = KeySection(title: "Anywhere", bindings: [
        KeyBinding([.char("c", .ctrl)], "Quit"),
        KeyBinding([.char("d", .ctrl)], "Quit (in a prompt with text, delete forward)"),
        KeyBinding([.char("o", .ctrl)], "Move the keys between the sidebar and the main pane"),
        KeyBinding([.char("b", .ctrl)], "Put the sidebar away or bring it back (narrow: open it over the main pane)"),
        KeyBinding([.char("k", .ctrl)], "Go to a session, project or action (not while writing a prompt)"),
        KeyBinding([jumpKey], "Open the next session that needs you, or else the first running (not while writing a prompt)"),
        KeyBinding([.char("[", []), .left(.alt)], "Back to the place before (where letters are keys)"),
        KeyBinding([.char("]", []), .right(.alt)], "Forward to the place after (where letters are keys)"),
        KeyBinding([.char("l", .ctrl)], "Redraw the screen"),
        KeyBinding([.char("z", .ctrl)], "Suspend to the shell"),
    ])

    static let sidebar = KeySection(title: "Sidebar", bindings: [
        KeyBinding([.up([]), .char("k", []), .char("p", .ctrl)], "Previous row"),
        KeyBinding([.down([]), .char("j", []), .char("n", .ctrl)], "Next row"),
        KeyBinding([.left([]), .char("h", []), .tab(.shift)], "Previous project, task or workspace"),
        KeyBinding([.right([]), .char("l", []), .tab([])], "Next project, task or workspace"),
        KeyBinding([.pageUp([]), .pageDown([])], "Page up, page down"),
        KeyBinding([.home([]), .char("g", [])], "First row"),
        KeyBinding([.end([]), .char("G", [])], "Last row"),
        KeyBinding([.enter([])], "Open the session in the main pane"),
        KeyBinding(label: "Enter on a project", "Open the project's, task's or workspace's screen"),
        KeyBinding([.char(" ", [])], "Fold or unfold the section, project, task or workspace"),
        KeyBinding(label: "Enter on See more", "Show every session of the container"),
        KeyBinding(label: "Enter on Needs you", "Open the session waiting on you"),
        KeyBinding(label: "Enter on Add, Tools", "Open the Add or Tools menu"),
        KeyBinding(label: "Enter on old sessions", "Review old sessions: tick, snooze, delete"),
        KeyBinding(label: "Enter on orphaned worktrees", "Prune them, after a confirmation naming each"),
        KeyBinding([.char("a", [])], "Actions for the row: pin, rename, delete and the rest"),
        KeyBinding([.char("n", [])], "Start a new session"),
        KeyBinding([.char("/", [])], "Filter projects and sessions"),
        KeyBinding([.char(",", [])], "Settings"),
        KeyBinding([.escape], "Clear the filter"),
        KeyBinding([.char("?", [])], "These keys"),
        KeyBinding([.char("q", [])], "Quit"),
    ])

    static let filter = KeySection(title: "Typing a filter", bindings: [
        KeyBinding(label: "text", "Narrow the sidebar to projects and sessions whose name holds the text"),
        KeyBinding([.backspace([])], "Delete a character (on an empty filter, stop typing)"),
        KeyBinding([.char("w", .ctrl), .backspace(.alt)], "Delete a word"),
        KeyBinding([.char("u", .ctrl)], "Delete the whole filter"),
        KeyBinding([.up([]), .char("p", .ctrl), .down([]), .char("n", .ctrl)], "Previous, next session"),
        KeyBinding([.pageUp([]), .pageDown([])], "Page up, page down"),
        KeyBinding([.enter([])], "Open the session, keeping the filter"),
        KeyBinding(label: "Enter on a project", "Show all its sessions, not only the matching ones"),
        KeyBinding([.escape], "Clear the filter and show every session"),
    ])

    // The main pane with no session open.
    static let home = KeySection(title: "Home", bindings: [
        KeyBinding([.up([]), .char("k", []), .char("p", .ctrl)], "Previous session"),
        KeyBinding([.down([]), .char("j", []), .char("n", .ctrl)], "Next session"),
        KeyBinding([.home([]), .char("g", [])], "First session"),
        KeyBinding([.end([]), .char("G", [])], "Last session"),
        KeyBinding([.enter([])], "Open the session"),
        KeyBinding([.char("n", [])], "Start a new session"),
        KeyBinding([.char(",", [])], "Settings"),
        KeyBinding([.escape, .left([]), .char("h", []), .char("q", [])], "Back to the sidebar"),
        KeyBinding([.char("?", [])], "These keys"),
    ])

    static let palette = KeySection(title: "Go to", bindings: [
        KeyBinding(label: "text", "Narrow to results matching every word, or a title's letters in order"),
        KeyBinding([.up([]), .char("p", .ctrl), .down([]), .char("n", .ctrl)], "Previous, next result"),
        KeyBinding([.pageUp([]), .pageDown([])], "Page up, page down"),
        KeyBinding([.tab([]), .tab(.shift)], "Next, previous kind: all, sessions, projects, actions"),
        KeyBinding([.char("u", .ctrl)], "Delete the whole query"),
        KeyBinding([.enter([])], "Go to the result"),
        KeyBinding([.escape], "Close"),
    ])

    // A row's actions, or Add's or Tools'.
    static let menu = KeySection(title: "Actions menu", bindings: [
        KeyBinding([.up([]), .char("k", []), .down([]), .char("j", [])], "Previous, next entry"),
        KeyBinding([.home([]), .char("g", []), .end([]), .char("G", [])], "First, last entry"),
        KeyBinding([.enter([]), .right([]), .char("l", []), .char(" ", [])], "Choose the entry"),
        KeyBinding([.escape, .left([]), .char("h", []), .char("q", [])], "Close"),
    ])

    // A deletion asking first: what goes, what stays.
    static let confirmation = KeySection(title: "Confirming a deletion", bindings: [
        KeyBinding([.enter([])], "Take the focused button (it starts on the deletion)"),
        KeyBinding([.char("y", [])], "Delete"),
        KeyBinding([.tab([]), .left([]), .right([])], "Move between the deletion and Cancel"),
        KeyBinding([.escape, .char("n", []), .char("q", [])], "Cancel"),
    ])

    static let newSession = KeySection(title: "New session", bindings: [
        KeyBinding([.up([]), .char("k", []), .char("p", .ctrl), .tab(.shift)], "Previous field"),
        KeyBinding([.down([]), .char("j", []), .char("n", .ctrl), .tab([])], "Next field"),
        KeyBinding([.left([]), .char("h", [])], "Previous choice (project, agent, model, checkout)"),
        KeyBinding([.right([]), .char("l", []), .char(" ", [])], "Next choice"),
        KeyBinding([.char("x", [])], "In a workspace, leave the project out or attach it again"),
        KeyBinding([.enter([])], "Start the session and open it"),
        KeyBinding([.char("?", [])], "These keys"),
        KeyBinding([.escape, .char("q", [])], "Cancel"),
    ])

    static let transcript = KeySection(title: "Session", bindings: [
        KeyBinding([.enter([]), .char("i", [])], "Write a prompt"),
        KeyBinding([.up([]), .char("k", []), .char("p", .ctrl)], "Scroll up a line"),
        KeyBinding([.down([]), .char("j", []), .char("n", .ctrl)], "Scroll down a line"),
        KeyBinding([.pageUp([]), .char("b", []), .char("u", .ctrl)], "Scroll up a page"),
        KeyBinding([.pageDown([]), .char(" ", []), .char("f", [])], "Scroll down a page"),
        KeyBinding([.home([]), .char("g", [])], "Top"),
        KeyBinding([.end([]), .char("G", [])], "Bottom, following new output"),
        KeyBinding([.tab([]), .tab(.shift)], "Point at the next, previous tool call"),
        KeyBinding([.char("o", [])], "Open or close the tool call pointed at"),
        KeyBinding([.char("O", [])], "Open or close every tool call"),
        KeyBinding([.char("d", [])], "Changes"),
        KeyBinding(label: "1-5", "Another tab, by position in the tab row"),
        KeyBinding([.char("C", [])], "Compact the context (Claude Code; asks first, as it costs a turn)"),
        KeyBinding([.char("X", [])], "Clear the context: the next turn starts a fresh conversation"),
        KeyBinding([.char("R", [])], "Rebuild the lost worktree the warning strip names (asks first)"),
        KeyBinding([.char("a", [])], "Jump to the agent the top bar counts as running or failed"),
        KeyBinding([.char("!", [])], "Shortcuts: run, stop and edit the saved commands of the session's projects"),
        KeyBinding([.char("m", [])], "The session's actions: continue, rewind, fork, recap, rename, delete and the rest"),
        KeyBinding([.char("s", [])], "Send the suggested next prompt (with a prompt written, add it to the end)"),
        KeyBinding([.char("r", [])], "Run settings for the next turn: model, effort, permissions or access, design ambition"),
        KeyBinding([.char("+", [])], "Attach a file to the next prompt, by its path"),
        KeyBinding([.char("I", [])], "Custom instructions for the next prompt"),
        KeyBinding([.char("/", []), .char("f", .ctrl)], "Find text in the transcript"),
        KeyBinding([.char("N", []), .char("n", [])], "With find open: the older, newer match"),
        KeyBinding(label: "Esc with find open", "Close find"),
        KeyBinding([.char("D", [])], "Session details: branch, changes, pull requests, model, context, cost"),
        KeyBinding([.char("L", [])], "The session's log, in $PAGER"),
        KeyBinding([.char(",", [])], "Settings"),
        KeyBinding([.char("y", [])], "Copy the message nearest the bottom (again: the one above)"),
        KeyBinding([.char("c", [])], "Copy the code block nearest the bottom (again: the one above)"),
        KeyBinding([.escape], "Stop the running turn (with none running, back to the sidebar)"),
        KeyBinding([.left([]), .char("h", []), .char("q", [])], "Back to the sidebar, leaving the session open"),
        KeyBinding([.char("?", [])], "These keys"),
    ])

    // While the agent waits for permission. Every other key of the session still works.
    static let permission = KeySection(title: "Agent asking for permission", bindings: [
        KeyBinding([.char("1", [])], "Allow once"),
        KeyBinding([.char("2", [])], "Allow, and add the folder the call reaches outside the session's; else allow always (when offered)"),
        KeyBinding([.char("3", []), .char("n", [])], "Deny"),
        KeyBinding([.enter([]), .char("i", [])], "Write a prompt instead (Tab comes back)"),
        KeyBinding([.escape], "Back to the sidebar, leaving the request waiting"),
    ])

    // While the agent waits for answers to its questions. The prompt takes the keys.
    static let question = KeySection(title: "Agent asking a question", bindings: [
        KeyBinding([.up([]), .char("p", .ctrl), .down([]), .char("n", .ctrl)], "Point at an option"),
        KeyBinding([.char(" ", [])], "Pick the option (tick or untick where several go)"),
        KeyBinding(label: "1-9", "Pick an option by number"),
        KeyBinding(label: "text", "Write an answer of your own instead"),
        KeyBinding([.backspace([]), .char("u", .ctrl)], "Delete a character, the whole answer"),
        KeyBinding([.enter([])], "Next question, or send every answer from the last"),
        KeyBinding([.tab([]), .tab(.shift)], "Next, previous question"),
        KeyBinding([.char("x", .ctrl)], "Skip: the agent reads it as a refusal"),
        KeyBinding([.pageUp([]), .pageDown([])], "Scroll the transcript"),
        KeyBinding([.escape], "Back to the sidebar, leaving the question waiting"),
    ])

    static let composer = KeySection(title: "Writing a prompt", bindings: [
        KeyBinding([.enter([])], "Send (queued while a turn runs)"),
        KeyBinding([.enter(.alt), .enter(.shift), .char("j", .ctrl)], "New line"),
        KeyBinding([.up([]), .down([])],
                   "In an empty prompt, step through earlier prompts; otherwise move by line"),
        KeyBinding([.left([]), .right([]), .char("b", .ctrl), .char("f", .ctrl)], "Move by character"),
        KeyBinding([.left(.alt), .right(.alt), .char("b", .alt), .char("f", .alt)], "Move by word"),
        KeyBinding([.home([]), .end([]), .char("a", .ctrl), .char("e", .ctrl)], "Start, end of the line"),
        KeyBinding([.backspace([]), .delete([])], "Delete a character"),
        KeyBinding([.char("w", .ctrl), .backspace(.alt)], "Delete the word before the cursor"),
        KeyBinding([.char("u", .ctrl)], "Delete to the start of the line"),
        KeyBinding([.char("k", .ctrl)], "Delete to the end of the line"),
        KeyBinding([.char("d", .ctrl)], "Delete forward (in an empty prompt, quit)"),
        KeyBinding([.pageUp([]), .pageDown([])], "Scroll the transcript"),
        KeyBinding([.tab([])], "Back to the transcript, keeping the prompt"),
        KeyBinding([.char("t", .ctrl)], "Attach a file, by its path"),
        KeyBinding(label: "Backspace on an empty prompt", "Take off the last file attached"),
        KeyBinding(label: "/ at the start", "List the slash commands; ↑↓ choose, Tab or Enter take one, Esc hides the list"),
        KeyBinding([.escape], "Stop the running turn (with none running, leave the prompt)"),
    ])

    static let changes = KeySection(title: "Changes", bindings: [
        KeyBinding([.up([]), .char("k", []), .char("p", .ctrl)], "Previous file"),
        KeyBinding([.down([]), .char("j", []), .char("n", .ctrl)], "Next file"),
        KeyBinding([.pageUp([]), .char("b", []), .char("u", .ctrl)], "Page up"),
        KeyBinding([.pageDown([]), .char("f", [])], "Page down"),
        KeyBinding([.home([]), .char("g", [])], "First file"),
        KeyBinding([.end([]), .char("G", [])], "Last file"),
        KeyBinding([.enter([]), .right([]), .char("l", [])], "Open the file's diff"),
        KeyBinding([.char(" ", [])], "Tick the file for the next commit (none ticked: every file)"),
        KeyBinding([.char("c", [])], "Commit, with a message"),
        KeyBinding([.char("D", [])], "Discard the file's changes (asks first)"),
        KeyBinding([.char("r", [])], "Read the changes again"),
        KeyBinding([.char("P", [])], "Push the checkout's commits (publish a branch with no upstream)"),
        KeyBinding([.char("U", [])], "Pull from the checkout's upstream"),
        KeyBinding([.char("F", [])], "Fetch origin"),
        KeyBinding([.char("B", [])], "Switch to or create a branch"),
        KeyBinding([.char("H", [])], "Commit history and the session's pull requests"),
        KeyBinding([.escape, .left([]), .char("h", []), .char("q", [])], "Back to the session"),
        KeyBinding([.char("?", [])], "These keys"),
    ])

    static let diff = KeySection(title: "Diff", bindings: [
        KeyBinding([.up([]), .char("k", []), .char("p", .ctrl)], "Scroll up a line"),
        KeyBinding([.down([]), .char("j", []), .char("n", .ctrl)], "Scroll down a line"),
        KeyBinding([.pageUp([]), .char("b", []), .char("u", .ctrl)], "Scroll up a page"),
        KeyBinding([.pageDown([]), .char(" ", []), .char("f", [])], "Scroll down a page"),
        KeyBinding([.home([]), .char("g", [])], "Top"),
        KeyBinding([.end([]), .char("G", [])], "Bottom"),
        KeyBinding([.char("n", []), .char("p", [])], "Next, previous file"),
        KeyBinding([.char("c", [])], "Commit, with a message"),
        KeyBinding([.char("D", [])], "Discard the file's changes (asks first)"),
        KeyBinding([.char("r", [])], "Read the changes again"),
        KeyBinding([.char("P", [])], "Push the checkout's commits (publish a branch with no upstream)"),
        KeyBinding([.char("U", [])], "Pull from the checkout's upstream"),
        KeyBinding([.char("F", [])], "Fetch origin"),
        KeyBinding([.char("B", [])], "Switch to or create a branch"),
        KeyBinding([.escape, .left([]), .char("h", []), .char("q", [])], "Back to the files"),
        KeyBinding([.char("?", [])], "These keys"),
    ])

    // The old-sessions review, opened from its strip at the sidebar's foot.
    static let oldSessions = KeySection(title: "Old sessions", bindings: [
        KeyBinding([.up([]), .char("k", []), .down([]), .char("j", [])], "Previous, next session or project"),
        KeyBinding([.home([]), .char("g", []), .end([]), .char("G", [])], "First, last row"),
        KeyBinding([.char(" ", []), .char("x", [])], "Tick or untick the session"),
        KeyBinding([.char("d", []), .enter([])], "Delete the ticked sessions (saved work asks first)"),
        KeyBinding([.char("z", [])], "Snooze the project's cleanup for a day (again: one more day)"),
        KeyBinding([.char("w", [])], "Wake a snoozed project now"),
        KeyBinding([.char("r", [])], "Read the list again"),
        KeyBinding([.char("?", [])], "These keys"),
        KeyBinding([.escape, .char("q", [])], "Close"),
    ])

    static let history = KeySection(title: "History and pull requests", bindings: [
        KeyBinding([.up([]), .char("k", []), .char("p", .ctrl)], "Previous pull request, commit or file (in a diff, scroll up)"),
        KeyBinding([.down([]), .char("j", []), .char("n", .ctrl)], "Next pull request, commit or file (in a diff, scroll down)"),
        KeyBinding([.pageUp([]), .pageDown([])], "Page up, page down"),
        KeyBinding([.home([]), .char("g", []), .end([]), .char("G", [])], "First, last"),
        KeyBinding([.enter([]), .right([]), .char("l", [])], "Open the commit, or the file's diff"),
        KeyBinding(label: "Enter on a pull request", "Open it in the browser"),
        KeyBinding([.char("n", []), .char("p", [])], "In a diff, the next, previous file of the commit"),
        KeyBinding([.char("r", [])], "Read the history again"),
        KeyBinding([.escape, .left([]), .char("h", []), .char("q", [])], "Back a level, then to the changes"),
        KeyBinding([.char("?", [])], "These keys"),
    ])

    static let settings = KeySection(title: "Settings", bindings: [
        KeyBinding([.up([]), .char("k", []), .down([]), .char("j", [])], "Previous, next setting"),
        KeyBinding([.left([]), .char("h", [])], "Previous choice"),
        KeyBinding([.right([]), .char("l", []), .char(" ", []), .enter([])], "Next choice (saved at once)"),
        KeyBinding([.home([]), .char("g", []), .end([]), .char("G", [])], "First, last setting"),
        KeyBinding([.char("r", [])], "Check again whether the agents are installed and signed in (in run settings: close)"),
        KeyBinding([.char("?", [])], "These keys"),
        KeyBinding([.escape, .char("q", []), .char(",", [])], "Close"),
    ])

    // Over an open session, on whichever tab is showing, unless it is taking text.
    static let tab = KeySection(title: "Session tabs", bindings: [
        KeyBinding(label: "1-5", "Chat, Design, Troubleshoot, Changes, Explorer, by position in the tab row"),
        KeyBinding([.char("C", [])], "Compact the context (asks first)"),
        KeyBinding([.char("X", [])], "Clear the context"),
        KeyBinding([.char("a", [])], "Back to the chat, at the agent the top bar counts"),
        KeyBinding([.char("!", [])], "Shortcuts of the session's projects"),
        KeyBinding([.escape, .left([]), .char("h", []), .char("q", [])], "Back to the chat (from a tab with nothing open)"),
    ])

    // Finding text in the transcript.
    static let find = KeySection(title: "Find in the transcript", bindings: [
        KeyBinding(label: "text", "What to look for (any case); the newest match comes into view"),
        KeyBinding([.up([]), .char("p", .ctrl), .down([]), .char("n", .ctrl)], "The older, newer match"),
        KeyBinding([.pageUp([]), .pageDown([])], "Scroll the transcript"),
        KeyBinding([.enter([])], "Done typing: n and N step through the matches"),
        KeyBinding([.escape], "Close find"),
    ])

    // A project, task or workspace screen.
    static let container = KeySection(title: "Project, task or workspace", bindings: [
        KeyBinding([.up([]), .char("k", []), .char("p", .ctrl)], "Previous session"),
        KeyBinding([.down([]), .char("j", []), .char("n", .ctrl)], "Next session"),
        KeyBinding([.home([]), .char("g", []), .end([]), .char("G", [])], "First, last session"),
        KeyBinding([.enter([])], "Open the session"),
        KeyBinding([.char("n", [])], "Start a new session (a task: run it, asking for its inputs)"),
        KeyBinding([.char("r", [])], "Read the status strip again"),
        KeyBinding([.char("l", [])], "Make the workspace project under the pointer its lead"),
        KeyBinding([.char("w", [])], "Start that project on a worktree, or in its folder"),
        KeyBinding([.char("d", [])], "A workspace's changes across its projects"),
        KeyBinding([.char("e", [])], "A task: edit its prompt and agent"),
        KeyBinding([.char("i", [])], "A task: edit how an input is asked for"),
        KeyBinding([.char("s", [])], "A task: set, change or turn off its schedule"),
        KeyBinding([.char("f", [])], "A task: show all, scheduled or failed runs"),
        KeyBinding([.char("c", [])], "A task: answer a scheduled run waiting for confirmation"),
        KeyBinding([.char("!", [])], "Shortcuts: the project's saved commands (not a workspace)"),
        KeyBinding([.char("P", [])], "Push the project folder's commits (not a task or workspace)"),
        KeyBinding([.char("U", [])], "Pull the project folder from its upstream"),
        KeyBinding([.char("F", [])], "Fetch origin for the project folder"),
        KeyBinding([.char("B", [])], "Switch the project folder to or create a branch"),
        KeyBinding([.escape, .left([]), .char("h", []), .char("q", [])], "Back to the sidebar"),
        KeyBinding([.char("?", [])], "These keys"),
    ])

    // The branch picker, over the Changes tab or a project's screen.
    static let branches = KeySection(title: "Branches", bindings: [
        KeyBinding(label: "text", "Narrow the branches to those whose names hold every word"),
        KeyBinding([.up([]), .char("p", .ctrl), .down([]), .char("n", .ctrl)], "Previous, next branch"),
        KeyBinding([.enter([])], "Switch to the branch (a remote one gets a local branch that tracks it)"),
        KeyBinding(label: "Enter on Create", "Name a new branch from here, then Enter creates it and switches"),
        KeyBinding([.escape], "Close (while naming: back to the list)"),
    ])

    static let shortcuts = KeySection(title: "Shortcuts", bindings: [
        KeyBinding([.up([]), .char("k", []), .down([]), .char("j", [])], "Previous, next shortcut"),
        KeyBinding([.enter([])], "Run it and show its output (running: show its output)"),
        KeyBinding([.char("s", [])], "Stop it"),
        KeyBinding([.char("o", [])], "Show its last output"),
        KeyBinding([.char("n", [])], "Save a new command"),
        KeyBinding([.char("e", [])], "Edit it (stop it first)"),
        KeyBinding([.char("x", [])], "Remove it (asks first)"),
        KeyBinding([.escape], "Hide the output, then close"),
        KeyBinding(label: "Tools › Shortcuts", "This Mac's own list, run from your home folder"),
    ])

    static let shortcutEditor = KeySection(title: "Editing a shortcut", bindings: [
        KeyBinding(label: "text", "Type the name or the command"),
        KeyBinding([.tab([]), .down([]), .tab(.shift), .up([])], "Next, previous field"),
        KeyBinding([.left([]), .right([]), .char(" ", [])], "On Where: this project only, or all projects"),
        KeyBinding([.enter([])], "Save"),
        KeyBinding([.escape], "Cancel"),
    ])

    // The Explorer tab's tree.
    static let explorer = KeySection(title: "Explorer", bindings: [
        KeyBinding([.up([]), .char("k", []), .down([]), .char("j", [])], "Previous, next file"),
        KeyBinding([.right([]), .char("l", [])], "Open a folder, or step into it"),
        KeyBinding([.left([]), .char("h", [])], "Fold a folder, or step out to its parent"),
        KeyBinding([.pageUp([]), .char("b", []), .pageDown([]), .char(" ", [])], "Page up, down"),
        KeyBinding([.home([]), .char("g", []), .end([]), .char("G", [])], "First, last row"),
        KeyBinding([.enter([])], "Open the file in $EDITOR, or open or fold the folder"),
        KeyBinding([.char("e", [])], "Open the file in $EDITOR"),
        KeyBinding([.char("/", [])], "Find a file by name"),
        KeyBinding([.char("F", []), .char("f", .ctrl)], "Find text in files"),
        KeyBinding([.char("n", []), .char("N", [])], "New file, new folder, beside the picked row"),
        KeyBinding([.char("R", [])], "Rename"),
        KeyBinding([.char("D", []), .delete([])], "Move to the Trash (asks first)"),
        KeyBinding([.char("r", [])], "Read the tree again"),
        KeyBinding([.escape, .char("q", [])], "Back to the chat"),
        KeyBinding([.char("?", [])], "These keys"),
    ])

    // The Design tab: the session's Design conversation (see `DesignTab`).
    static let design = KeySection(title: "Design", bindings: [
        KeyBinding([.enter([]), .char("i", [])], "Write to the Design conversation (enter sends)"),
        KeyBinding([.up([]), .char("k", []), .down([]), .char("j", [])], "Scroll the conversation"),
        KeyBinding([.char("o", [])], "Open the canvas screen in the browser"),
        KeyBinding([.char("s", [])], "Next screen of the canvas"),
        KeyBinding([.char("A", [])], "Next design ambition, from the next turn"),
        KeyBinding([.char("v", [])], "Approve the canvas as it is"),
        KeyBinding([.char("I", [])], "Implement the Design (asks for guidance), or send the newer one to the Build"),
        KeyBinding([.char("r", [])], "Read the Design again"),
        KeyBinding([.escape], "Stop the running turn, or back to the chat"),
    ])

    // The Troubleshoot tab and the new diagnosis form (see `TroubleshootForm`).
    static let troubleshoot = KeySection(title: "Troubleshoot", bindings: [
        KeyBinding([.up([]), .down([]), .tab([])], "Previous, next field"),
        KeyBinding(label: "text", "The problem, the incident time, evidence paths and skills (commas between several)"),
        KeyBinding([.left([]), .right([]), .char(" ", [])], "Change the environment, turn MCP servers on or off"),
        KeyBinding([.enter([])], "Start the diagnosis"),
        KeyBinding([.escape], "Back to the chat (what was typed stays)"),
    ])

    // Typing in the Explorer: a file name, text to find, or a name for a file.
    static let explorerTyping = KeySection(title: "Typing in the Explorer", bindings: [
        KeyBinding(label: "text", "The file name, the text to find, or the name to give"),
        KeyBinding([.up([]), .char("p", .ctrl), .down([]), .char("n", .ctrl)], "Previous, next result"),
        KeyBinding([.enter([])], "Open the result in $EDITOR (find in files: search first, then open at the line); save a name"),
        KeyBinding([.escape], "Back to the tree"),
    ])

    static let help = KeySection(title: "This list", bindings: [
        KeyBinding([.up([]), .char("k", []), .down([]), .char("j", [])], "Scroll a line"),
        KeyBinding([.pageUp([]), .char("b", []), .pageDown([]), .char(" ", [])], "Scroll a page"),
        KeyBinding([.home([]), .char("g", []), .end([]), .char("G", [])], "Top, bottom"),
        KeyBinding([.escape, .char("q", []), .char("?", [])], "Close"),
    ])

    // MARK: - Names

    static func name(of key: Key) -> String {
        switch key {
        case .char(" ", let mods): return prefix(mods) + "Space"
        case .char(let character, let mods):
            if mods.contains(.ctrl) { return "Ctrl-" + String(character).uppercased() }
            if mods.contains(.alt) { return "Alt-" + String(character) }
            return String(character)
        case .enter(let mods): return prefix(mods) + "Enter"
        case .tab(let mods): return prefix(mods) + "Tab"
        case .backspace(let mods): return prefix(mods) + "Backspace"
        case .escape: return "Esc"
        case .up(let mods): return prefix(mods) + "↑"
        case .down(let mods): return prefix(mods) + "↓"
        case .left(let mods): return prefix(mods) + "←"
        case .right(let mods): return prefix(mods) + "→"
        case .home(let mods): return prefix(mods) + "Home"
        case .end(let mods): return prefix(mods) + "End"
        case .pageUp(let mods): return prefix(mods) + "PgUp"
        case .pageDown(let mods): return prefix(mods) + "PgDn"
        case .delete(let mods): return prefix(mods) + "Delete"
        case .paste: return "paste"
        }
    }

    private static func prefix(_ mods: Modifiers) -> String {
        var prefix = ""
        if mods.contains(.ctrl) { prefix += "Ctrl+" }
        if mods.contains(.alt) { prefix += "Alt+" }
        if mods.contains(.shift) { prefix += "Shift+" }
        return prefix
    }
}
