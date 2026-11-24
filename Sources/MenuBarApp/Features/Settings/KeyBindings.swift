import SwiftUI

// Every key the app answers, each with what it does and the key it starts with. This is
// both the list Settings shows and, for a key the person can change, where the binding
// is read from, so a key added to a view belongs here too or nothing on screen will ever
// say it exists. The standard editing keys are left out: they are in the menu bar, where
// every Mac app keeps them, and listing them here would bury the rest.
enum AppCommand: String, CaseIterable, Identifiable, Sendable {
    case goBack, goForward, commandPalette, filterSidebar, nextWaiting
    case newSession, switchTab, terminal, maximizeTerminal, findInConversation
    case runLastCommand, savedCommands, stopCommand
    case previewAddress, previewBack, previewForward
    case stopTurn, editSuggestion, sendSuggestion, cancelSuggestion
    case dictate, stopDictating, throwAwayTake
    case branches, commitSelected, askWholeChange, stepFindings, triageFinding, toggleViewed, nextNotViewed
    case saveFile, findInFile, findInFiles, findFileNames, closeFile, renameFile, trashFile
    case searchDocker, switchDockerKind, deleteDockerSelection
    case findRequest, sendRequest
    case settings, biggerText, smallerText, actualSize, fullScreen, closeWindow, minimise, quit

    // The part of the window a pane key works in. A key in a child, such as the Changes
    // tab, is live alongside the keys of the session around it, but not alongside its
    // siblings, which are never on screen together.
    enum Area: Sendable {
        case session, conversation, preview, changes, explorer, docker, dispatch

        var parent: Area? {
            switch self {
            case .conversation, .preview, .changes, .explorer: .session
            case .session, .docker, .dispatch: nil
            }
        }

        // A sheet is a window of its own, asked about every key before the window under it.
        var isSheet: Bool { self == .docker || self == .dispatch }

        func overlaps(_ other: Area) -> Bool {
            self == other || parent == other || other.parent == self
        }
    }

    // Where a key works decides which other keys it can share with.
    enum Scope: Sendable {
        // The menu bar's keys, live everywhere and never shared.
        case app
        // Live wherever the window has the keyboard.
        case window
        // Live only in one part of the window. One caught by a key monitor, or held by a
        // sheet, is asked before the window's own keys and wins there, so it may reuse a
        // window key. One bound to a SwiftUI button may not: when two buttons in a window
        // hold the same key, which one runs is not defined.
        case pane(Area, firstClaim: Bool = false)

        func clashes(with other: Scope) -> Bool {
            switch (self, other) {
            case (.app, _), (_, .app), (.window, .window):
                return true
            case (.window, .pane(let area, let first)), (.pane(let area, let first), .window):
                return !(first || area.isSheet)
            case (.pane(let one, _), .pane(let two, _)):
                return one.overlaps(two)
            }
        }
    }

    struct Info: Sendable {
        let title: String
        let detail: String
        let keys: KeyCombo?
        let scope: Scope
        var canChange = false
        // Keys that always do the same thing whatever the main key is set to.
        var alsoKeys: [KeyCombo] = []
        // How a row that is more than one key is written.
        var label: String?
    }

    var id: String { rawValue }

    var info: Info {
        switch self {
        case .goBack:
            Info(title: "Back", detail: "Go to the project, workspace or session you were looking at before.",
                 keys: KeyCombo("["), scope: .window, canChange: true)
        case .goForward:
            Info(title: "Forward", detail: "Go the other way again after stepping back.",
                 keys: KeyCombo("]"), scope: .window, canChange: true)
        case .commandPalette:
            Info(title: "Command palette", detail: "Search everything and jump straight to it.",
                 keys: KeyCombo("k"), scope: .window, canChange: true)
        case .filterSidebar:
            Info(title: "Filter the sidebar", detail: "Open the filter field and start typing a name.",
                 keys: KeyCombo("f"), scope: .window, canChange: true)
        case .nextWaiting:
            Info(title: "Next one waiting", detail: "Jump to the first session that needs an answer.",
                 keys: KeyCombo("a", [.command, .shift]), scope: .window, canChange: true)
        case .newSession:
            Info(title: "New session", detail: "Start a session in whatever is selected.",
                 keys: KeyCombo("n"), scope: .window, canChange: true)
        case .switchTab:
            Info(title: "Switch tab", detail: "Open a tab by its place in the row at the top.",
                 keys: nil, scope: .window, alsoKeys: (1...9).map { KeyCombo("\($0)") }, label: "⌘ 1 … ⌘ 9")
        case .terminal:
            Info(title: "Terminal",
                 detail: "Open the terminal drawer, move the cursor into it, or close it from the shell.",
                 keys: KeyCombo("`", .control), scope: .window, canChange: true)
        // Beside the terminal key, with Shift. Where backtick is a dead key the press reads
        // as backtick; where it is not, Shift has already made it a tilde, so that reading
        // is kept as well and the key works on either kind of layout.
        case .maximizeTerminal:
            Info(title: "Maximize the terminal",
                 detail: "Let the open terminal take the whole screen, or give the room back.",
                 keys: KeyCombo("`", [.control, .shift]), scope: .window, canChange: true,
                 alsoKeys: [KeyCombo("~", [.control, .shift])])
        case .findInConversation:
            Info(title: "Find in the conversation", detail: "Search what was said in this session. ⌃ F works too.",
                 keys: KeyCombo("f"), scope: .pane(.conversation, firstClaim: true), canChange: true,
                 alsoKeys: [KeyCombo("f", .control)])
        case .runLastCommand:
            Info(title: "Use the shortcut on the button", detail: "Run or insert the first shortcut in this session's list.",
                 keys: KeyCombo("r"), scope: .pane(.session), canChange: true)
        case .savedCommands:
            Info(title: "All saved commands", detail: "Open the list of saved commands for this session.",
                 keys: KeyCombo("r", [.command, .shift]), scope: .pane(.session), canChange: true)
        case .stopCommand:
            Info(title: "Stop the command", detail: "Stop the saved command whose output is open below.",
                 keys: KeyCombo("c", .control), scope: .pane(.session, firstClaim: true), canChange: true)
        case .previewAddress:
            Info(title: "Preview address", detail: "Type an address or a path into the running app's preview.",
                 keys: KeyCombo("l"), scope: .window, canChange: true)
        case .previewBack:
            Info(title: "Back in the preview",
                 detail: "Go back a page in the running app while it or its address has the keyboard.",
                 keys: KeyCombo("["), scope: .pane(.preview, firstClaim: true), canChange: true)
        case .previewForward:
            Info(title: "Forward in the preview",
                 detail: "Go forward a page in the running app while it or its address has the keyboard.",
                 keys: KeyCombo("]"), scope: .pane(.preview, firstClaim: true), canChange: true)
        case .stopTurn:
            Info(title: "Stop the turn", detail: "Call off the agent while it is working.",
                 keys: KeyCombo(KeyCombo.escape, []), scope: .pane(.conversation))
        case .editSuggestion:
            Info(title: "Edit the suggestion", detail: "Put the suggested next prompt in the composer to change it.",
                 keys: KeyCombo(KeyCombo.tab, []), scope: .pane(.conversation))
        case .sendSuggestion:
            Info(title: "Send the suggestion",
                 detail: "Send the suggested next prompt as written. Nothing typed is ever sent over.",
                 keys: KeyCombo(KeyCombo.returnKey), scope: .pane(.conversation))
        case .cancelSuggestion:
            Info(title: "Cancel the suggestion", detail: "Drop the suggested next prompt for this turn.",
                 keys: KeyCombo(KeyCombo.escape, []), scope: .pane(.conversation))
        case .dictate:
            Info(title: "Dictate",
                 detail: "Speak into the prompt box. Press again to stop. Nothing is sent until you send it.",
                 keys: KeyCombo("d", [.command, .shift]), scope: .window, canChange: true)
        case .stopDictating:
            Info(title: "Stop dictating", detail: "Keep the words in the prompt box while the microphone is on.",
                 keys: KeyCombo(KeyCombo.returnKey, []), scope: .pane(.conversation))
        case .throwAwayTake:
            Info(title: "Throw away the take", detail: "Put the prompt back as it was before you spoke.",
                 keys: KeyCombo(KeyCombo.escape, []), scope: .pane(.conversation))
        case .branches:
            Info(title: "Branches and actions",
                 detail: "Browse branches in the selected repository and preview a merge.",
                 keys: KeyCombo("b"), scope: .pane(.changes, firstClaim: true), canChange: true)
        case .commitSelected:
            Info(title: "Commit selected files",
                 detail: "Commit the checked files with the message in the Changes composer.",
                 keys: KeyCombo(KeyCombo.returnKey), scope: .pane(.changes, firstClaim: true), canChange: true)
        case .askWholeChange:
            Info(title: "Ask about the whole change",
                 detail: "Open or close the question card for the whole change during a review.",
                 keys: KeyCombo("?", .shift), scope: .pane(.changes))
        case .stepFindings:
            Info(title: "Next or previous finding", detail: "Move through the findings of a review.",
                 keys: KeyCombo(KeyCombo.down, .option), scope: .pane(.changes),
                 alsoKeys: [KeyCombo(KeyCombo.up, .option)], label: "⌥ ↑ ↓")
        case .triageFinding:
            Info(title: "Keep, edit or dismiss",
                 detail: "Sort the finding in focus while nothing is being typed.",
                 keys: KeyCombo("k", []), scope: .pane(.changes),
                 alsoKeys: [KeyCombo("e", []), KeyCombo("d", [])], label: "K · E · D")
        case .toggleViewed:
            Info(title: "Mark the file viewed",
                 detail: "Tick off the open file as read and move on to the next one, or untick it.",
                 keys: KeyCombo("v", []), scope: .pane(.changes))
        case .nextNotViewed:
            Info(title: "Next file not viewed",
                 detail: "Open the next changed file you have not read yet.",
                 keys: KeyCombo("v", .shift), scope: .pane(.changes))
        case .saveFile:
            Info(title: "Save the file", detail: "Save the file being edited in the Explorer.",
                 keys: KeyCombo("s"), scope: .pane(.explorer), canChange: true)
        case .findInFile:
            Info(title: "Find in the file", detail: "Search the file being edited in the Explorer. ⌃ F works too.",
                 keys: KeyCombo("f"), scope: .pane(.explorer, firstClaim: true), canChange: true,
                 alsoKeys: [KeyCombo("f", .control)])
        case .findInFiles:
            Info(title: "Find in files", detail: "Search the text of every file in the Explorer's folder.",
                 keys: KeyCombo("h", .control), scope: .pane(.explorer, firstClaim: true), canChange: true)
        case .findFileNames:
            Info(title: "Find a file by name", detail: "Press Shift twice to search the names of files in the Explorer.",
                 keys: nil, scope: .pane(.explorer), label: "⇧ ⇧")
        case .closeFile:
            Info(title: "Close the file", detail: "Close the file in front, the way an editor closes a tab.",
                 keys: KeyCombo("w"), scope: .pane(.explorer, firstClaim: true))
        case .renameFile:
            Info(title: "Rename", detail: "Rename the file or folder picked in the Explorer's list.",
                 keys: KeyCombo(KeyCombo.returnKey, []), scope: .pane(.explorer))
        case .trashFile:
            Info(title: "Move to Trash", detail: "Move the file or folder picked in the Explorer's list to the Trash.",
                 keys: KeyCombo(KeyCombo.delete), scope: .pane(.explorer))
        case .searchDocker:
            Info(title: "Filter Docker", detail: "Type a name or an image to narrow the list.",
                 keys: KeyCombo("f"), scope: .pane(.docker), canChange: true)
        case .switchDockerKind:
            Info(title: "Switch list", detail: "Show containers, images, volumes or networks.",
                 keys: nil, scope: .pane(.docker),
                 alsoKeys: (1...DockerKind.allCases.count).map { KeyCombo("\($0)") },
                 label: "⌘ 1 … ⌘ \(DockerKind.allCases.count)")
        case .deleteDockerSelection:
            Info(title: "Delete the picked ones", detail: "Remove the containers, images or volumes picked in the list.",
                 keys: KeyCombo(KeyCombo.delete, []), scope: .pane(.docker))
        case .findRequest:
            Info(title: "Find a request", detail: "Search the saved requests in Dispatch. ⌃ K works too.",
                 keys: KeyCombo("k"), scope: .pane(.dispatch), canChange: true,
                 alsoKeys: [KeyCombo("k", .control)])
        case .sendRequest:
            Info(title: "Send the request", detail: "Send the request open in Dispatch, or cancel it while it runs.",
                 keys: KeyCombo(KeyCombo.returnKey), scope: .pane(.dispatch),
                 alsoKeys: [KeyCombo(KeyCombo.returnKey, .control)])
        case .settings:
            Info(title: "Settings", detail: "Open this window.", keys: KeyCombo(","), scope: .app)
        case .biggerText:
            Info(title: "Bigger text", detail: "Grow the text in conversations, diffs and the terminal.",
                 keys: KeyCombo("+"), scope: .app, alsoKeys: [KeyCombo("=")])
        case .smallerText:
            Info(title: "Smaller text", detail: "Shrink it again.", keys: KeyCombo("-"), scope: .app)
        case .actualSize:
            Info(title: "Actual size", detail: "Put the text back to its normal size.",
                 keys: KeyCombo("0"), scope: .app)
        case .fullScreen:
            Info(title: "Full screen", detail: "Fill the screen with the window.",
                 keys: KeyCombo("f", [.control, .command]), scope: .app)
        case .closeWindow:
            Info(title: "Close the window", detail: "The app keeps running in the menu bar.",
                 keys: KeyCombo("w"), scope: .app)
        case .minimise:
            Info(title: "Minimise", detail: "Send the window to the Dock.", keys: KeyCombo("m"), scope: .app)
        case .quit:
            Info(title: "Quit", detail: "Close the app and everything running in it.",
                 keys: KeyCombo("q"), scope: .app)
        }
    }

    // Grouped by what a person is trying to do rather than by the file the key is bound in.
    static let groups: [(title: String, commands: [AppCommand])] = [
        ("Moving around", [.goBack, .goForward, .commandPalette, .filterSidebar, .nextWaiting]),
        ("Sessions", [.newSession, .switchTab, .terminal, .maximizeTerminal, .findInConversation,
                      .runLastCommand, .savedCommands, .stopCommand, .stopTurn, .editSuggestion,
                      .sendSuggestion, .cancelSuggestion, .dictate, .stopDictating, .throwAwayTake]),
        ("Preview", [.previewAddress, .previewBack, .previewForward]),
        ("Changes", [.branches, .commitSelected, .askWholeChange, .stepFindings, .triageFinding,
                     .toggleViewed, .nextNotViewed]),
        ("Files", [.saveFile, .findInFile, .findInFiles, .findFileNames, .closeFile, .renameFile, .trashFile]),
        ("Docker", [.searchDocker, .switchDockerKind, .deleteDockerSelection]),
        ("Dispatch", [.findRequest, .sendRequest]),
        ("The app", [.settings, .biggerText, .smallerText, .actualSize, .fullScreen, .closeWindow,
                     .minimise, .quit])
    ]
}

// The keys the person has moved away from where they start. Only the changes are kept,
// so a key the app moves in a later version still reaches everyone who never touched it.
struct KeyBindings: Equatable, Sendable {
    // A command mapped to nil has had its key taken away on purpose.
    private(set) var changes: [AppCommand: KeyCombo?] = [:]

    init(changes: [AppCommand: KeyCombo?] = [:]) {
        self.changes = changes.filter { $0.key.info.canChange }
    }

    func keys(for command: AppCommand) -> KeyCombo? {
        if let changed = changes[command] { return changed }
        return command.info.keys
    }

    // Written for a row in Settings. A fixed row of several keys has its own way of saying it.
    func label(for command: AppCommand) -> String? {
        command.info.label ?? keys(for: command)?.label
    }

    // A tooltip's name and the key, as "Commit (⌘⏎)", or the name alone when there is no key.
    func tooltip(_ name: String, for command: AppCommand) -> String {
        keys(for: command).map { "\(name) (\($0.compactLabel))" } ?? name
    }

    // Whether the second command's key is one the first also answers to, as when a pane's
    // find takes the key the sidebar's filter is on.
    func takes(_ other: AppCommand, from command: AppCommand) -> Bool {
        guard let keys = keys(for: other) else { return false }
        return held(by: command).contains(keys)
    }

    // Every key the command answers to right now.
    func held(by command: AppCommand) -> [KeyCombo] {
        (keys(for: command).map { [$0] } ?? []) + command.info.alsoKeys
    }

    func isChanged(_ command: AppCommand) -> Bool { changes.keys.contains(command) }

    var hasChanges: Bool { !changes.isEmpty }

    mutating func set(_ keys: KeyCombo?, for command: AppCommand) {
        guard command.info.canChange else { return }
        if keys == command.info.keys {
            changes.removeValue(forKey: command)
        } else {
            changes.updateValue(keys, forKey: command)
        }
    }

    mutating func reset(_ command: AppCommand) { changes.removeValue(forKey: command) }

    mutating func resetAll() { changes.removeAll() }

    enum Problem: Equatable, Sendable {
        // A plain key or a shifted one is typing, and would never reach the window.
        case needsModifier
        case taken(by: String)

        var message: String {
            switch self {
            case .needsModifier: "Hold ⌘, ⌃ or ⌥ with the key."
            case .taken(let name): "Already used by \(name)."
            }
        }
    }

    // Why the keys cannot go to the command, or nil when they can.
    func problem(with keys: KeyCombo, for command: AppCommand) -> Problem? {
        guard !keys.modifiers.isDisjoint(with: [.command, .control, .option]) else {
            return .needsModifier
        }
        let scope = command.info.scope
        for other in AppCommand.allCases where other != command && scope.clashes(with: other.info.scope) {
            if held(by: other).contains(keys) { return .taken(by: other.info.title) }
        }
        if let menu = Self.menuKeys.first(where: { $0.keys == keys }) {
            return .taken(by: menu.title)
        }
        return nil
    }

    // The keys in the menu bar that the list leaves out, so none of them is given away.
    private static let menuKeys: [(keys: KeyCombo, title: String)] = [
        (KeyCombo("z"), "Undo"), (KeyCombo("z", [.command, .shift]), "Redo"),
        (KeyCombo("x"), "Cut"), (KeyCombo("c"), "Copy"), (KeyCombo("v"), "Paste"),
        (KeyCombo("v", [.command, .option, .shift]), "Paste and Match Style"),
        (KeyCombo("a"), "Select All"), (KeyCombo("h"), "Hide"),
        (KeyCombo("h", [.command, .option]), "Hide Others")
    ]
}

extension Preferences {
    private static let keyBindingsKey = "keyBindings"

    static func keyBindings(in store: UserDefaults = .standard) -> KeyBindings {
        guard let data = store.data(forKey: keyBindingsKey),
              let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data)
        else { return KeyBindings() }
        // A command that no longer exists, or can no longer be changed, is dropped.
        var changes: [AppCommand: KeyCombo?] = [:]
        for (id, keys) in saved {
            guard let command = AppCommand(rawValue: id) else { continue }
            changes.updateValue(keys, forKey: command)
        }
        return KeyBindings(changes: changes)
    }

    static func setKeyBindings(_ bindings: KeyBindings, in store: UserDefaults = .standard) {
        guard bindings.hasChanges else {
            store.removeObject(forKey: keyBindingsKey)
            return
        }
        var saved: [String: KeyCombo?] = [:]
        for (command, keys) in bindings.changes {
            saved.updateValue(keys, forKey: command.rawValue)
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        store.set(data, forKey: keyBindingsKey)
    }
}

extension EnvironmentValues {
    // Set once at the top of the window from the person's settings. A view on its own,
    // as in a test, gets the keys the app starts with.
    @Entry var keyBindings = KeyBindings()
}

extension View {
    // Binds the command's current key to this button, or no key when it has none.
    func appShortcut(_ command: AppCommand) -> some View {
        modifier(AppShortcutModifier(command: command))
    }

    // Keeps a key monitor listening for the command's current key.
    func keyMonitor(_ monitor: WindowKeyMonitor, follows command: AppCommand) -> some View {
        modifier(KeyMonitorBinding(monitor: monitor, command: command))
    }
}

private struct KeyMonitorBinding: ViewModifier {
    @Environment(\.keyBindings) private var bindings
    let monitor: WindowKeyMonitor
    let command: AppCommand

    func body(content: Content) -> some View {
        content.onChange(of: bindings.keys(for: command), initial: true) { _, keys in
            monitor.keys = keys
        }
    }
}

private struct AppShortcutModifier: ViewModifier {
    @Environment(\.keyBindings) private var bindings
    let command: AppCommand

    func body(content: Content) -> some View {
        content.keyboardShortcut(bindings.keys(for: command)?.shortcut)
    }
}
