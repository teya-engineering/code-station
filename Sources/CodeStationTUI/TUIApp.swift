import CodeStationCore
import Foundation
import TerminalKit
import TerminalServices
import TerminalTranscript

// The terminal front end. It owns the terminal for as long as it runs, reaches the core
// only through the station interface, as one client of the station, and holds view state
// alone. Quitting, however it is asked for, restores the terminal and then does what main
// says quitting does to the station.
//
// The frame is laid out as the GUI's window is (see `Layout`): the sidebar on the left,
// the top bar over the main pane, and the main pane, with overlays drawn over all of it.
// Keys go to the overlay on top, if any, and otherwise to the region with the focus.
@MainActor
final class TUIApp {
    private let terminal: any TerminalDevice
    let commands: any StationInterface
    // What quitting does to the station, once the terminal is put back.
    private let shutdown: () -> Void
    private let theme: TranscriptTheme
    // How the process ends once the terminal is put back and the station shut down.
    private let exit: @MainActor () -> Void
    // What time it is, for the elapsed time on the top bar. A test sets it ahead.
    private let now: @MainActor () -> Date
    private var screen = Screen()
    var sidebar = SidebarView()
    // What the main pane shows while no session is open.
    private var home = HomeView()
    // Which region takes the keys when no overlay is up.
    var focus: Layout.Focus = .sidebar
    // The sidebar put away by hand on a terminal wide enough to dock it. Where it is not
    // docked it opens over the main pane while it has the keys.
    private var sidebarHidden = false
    // The open session, in the main pane, when one is open.
    var transcript: TranscriptView?
    // The sidebar row the open session was opened from.
    private var openedRowID: String?
    // Prompts left half written in sessions that were closed, by session id.
    private var drafts: [String: ComposerView] = [:]
    // The open session's facts in full, over its transcript, opened from the top bar's
    // Details entry.
    private var factsOpen = false
    // Repaints each second while the top bar counts a running or waiting turn's time.
    private var ticker: Task<Void, Never>?
    // The open session's tab, and its screen in the main pane for every tab but the chat,
    // which is the transcript (see `SessionTabs`).
    private var tab: RemoteSessionTab.Kind = .chat
    private var tabScreen: (any SessionTabScreen)?
    // A project, task or workspace in the main pane, while one is shown there in place of
    // a session, and the read of its status strip on its way.
    var containerScreen: ContainerScreen?
    // Push, pull, fetch and the branch picker for a project screen's folder.
    private var containerSync: SyncActions?
    private var statusRead: Task<Void, Never>?
    // The command shortcuts of a project, a session or the Mac, over everything, while
    // they are open (see `ShortcutsOverlay`).
    private var shortcuts: ShortcutsOverlay?
    // The new-session form, over everything, while one is being filled in.
    private var newSession: NewSessionForm?
    private var newSessionWork: Task<Void, Never>?
    // The key list, over whatever screen it was opened from.
    private var help: HelpView?
    // The settings, over everything, while they are open.
    private var settingsScreen: SettingsScreen?
    // The open session's run settings for its next turn, over everything, while open
    // (`r`), drawn on the settings screen, and the session they belong to.
    private var runSettings: (screen: SettingsScreen, sessionID: String)?
    // A newer release of the app than the one the station runs, noted in the sidebar.
    private var update: RemoteAppUpdate?
    // The command palette, over everything, while it is open.
    private var palette: CommandPalette?
    // An actions menu (a sidebar row's, Add's or Tools'), over everything, while open.
    var menu: ActionMenu?
    // A deletion asking first, over everything, and what it does once confirmed.
    var confirmation: (view: ImpactConfirmation, then: @MainActor () -> Void)?
    // The old-sessions review, over everything, while it is open (see `CleanupActions`).
    var oldSessions: OldSessionsScreen?
    // More entries for a row's actions menu, after the built-in ones. Tests add their own
    // here; a feature adds its entries in `rowActions(for:)`.
    var extraRowActions: [@MainActor (SidebarView.Target) -> [MenuAction]] = []
    // The places this front end has shown in the main pane, walked with back and
    // forward. Its own, as its selection is: the GUI keeps a trail of its own.
    private var history = NavigationHistory()
    private var updates: Task<Void, Never>?
    private var hostEvents: Task<Void, Never>?
    private var linkWatch: Task<Void, Never>?
    private var sessionEvents: Task<Void, Never>?
    private var recallWork: Task<Void, Never>?
    // A session on its way to the screen, so a second Enter does not open it again.
    private var opening = false
    private var quitting = false
    // Station work started from a key and not yet seen through, such as a session being
    // opened or a prompt being sent.
    private var pendingWork = 0
    // How copying reaches the clipboard (OSC 52), and how what the station host tells the
    // person reaches this terminal (OSC 9, the bell). Set by main once the host exists.
    var host: TerminalHost?
    // What runs `$EDITOR`, `$PAGER` and `$SHELL` on this terminal. Set by main.
    var handoff: (any HandoffRunner)?
    // Where `$PAGER` and the like are read.
    var environment: [String: String] = ProcessInfo.processInfo.environment
    // The typed path the core asked for, over everything else, and who is waiting for it.
    private var pathPrompt: PathPromptView?
    private var pathAnswer: CheckedContinuation<String?, Never>?
    // What the TUI itself does with a typed path, such as adding a project, in place of
    // a question from the core.
    private var pathChosen: (@MainActor (String) -> Void)?
    // A new name being typed for a project, task or session, over everything else, and
    // what saves it: nil once saved, or why the station refused it.
    private var renaming: (view: NamePromptView, save: @MainActor (String) async -> StationRefusal?)?
    // The new-workspace form, and the new-session form for a workspace, over everything
    // while one is being filled in.
    private var workspaceForm: WorkspaceForm?
    private var workspaceSession: WorkspaceSessionForm?
    // A workspace's changes across its members, over its screen, while they are open.
    private var workspaceChanges: WorkspaceChanges?
    // A task form (new, edit, an input, a run, the schedule) over everything else: the
    // form, what an edit refreshes in it, and what Enter does with it (see `TaskActions`).
    var taskForm: (view: FormView, refresh: (inout FormView) -> Void, submit: @MainActor (FormView) -> Void)?
    // A scheduled run waiting for confirmation, asked about over everything else.
    var scheduledRunQuestion: (view: ChoiceDialog<ScheduledRunChoice>, taskID: String)?

    init(terminal: any TerminalDevice, commands: any StationInterface, theme: TranscriptTheme,
         shutdown: @escaping () -> Void,
         exit: @escaping @MainActor () -> Void = { Darwin.exit(0) },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.terminal = terminal
        self.now = now
        self.commands = commands
        self.theme = theme
        self.shutdown = shutdown
        self.exit = exit
    }

    // The sidebar fills in on the first directory update, sent as soon as it is asked for.
    func start() {
        terminal.start { [weak self] event in self?.handle(event) }
        history.visit(.home)
        paint()
        updates = Task { [weak self, commands] in
            for await directory in commands.directoryUpdates() {
                guard let self else { return }
                self.sidebar.show(directory)
                self.home.show(directory)
                let before = self.containerScreen?.container
                if self.containerScreen?.show(directory) == false { self.closeContainer() }
                if let screen = self.containerScreen, screen.container.kind == .task, screen.container != before {
                    self.work { [weak self] in await self?.readTask(screen.id) }
                }
                self.paint()
            }
            // The list only ends when the host will not serve this terminal again, such
            // as a host of another build that took the station: asking says why.
            guard let self, !self.quitting, !Task.isCancelled else { return }
            do {
                _ = try await commands.listDirectory()
            } catch {
                self.sidebar.hostRefused((error as? StationRefusal)?.message ?? "\(error)")
                self.paint()
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.topBarTicks || self.sidebar.showsCountdown { self.paint() }
                // A command may be printing: its output is asked for again.
                self.shortcuts?.reload()
            }
        }
        // Whether an update is waiting, read once: the GUI looks for one once a day.
        work { [weak self, commands] in
            guard let settings = try? await commands.readSettings(), let self else { return }
            self.update = settings.update
            self.paint()
        }
        // A host that takes the connection but does not answer it is said in the sidebar
        // until one answers, rather than left as a blank frame.
        linkWatch = Task { [weak self, commands] in
            for await link in commands.linkUpdates() {
                guard let self else { return }
                self.sidebar.linkChanged(link.message)
                self.paint()
            }
        }
        // Whichever process runs a session, the terminal rings and notifies for it.
        hostEvents = Task { [weak self, commands] in
            for await event in commands.hostEvents() {
                guard let self else { return }
                if case .handoverStarting(let successor) = event {
                    self.sidebar.handoverStarted(to: successor)
                    self.paint()
                }
                guard let host = self.host else { continue }
                event.deliver(to: host)
            }
        }
    }

    private func handle(_ event: Terminal.Event) {
        switch event {
        case .key(let key): handle(key)
        case .resize: paint()
        case .resumed:
            screen.invalidate()
            paint()
        case .signal: quit()
        }
    }

    private func handle(_ key: Key) {
        transcript?.notice = nil
        sidebar.notice = nil
        if key != .char("y", []) && key != .char("c", []) { transcript?.forgetCopy() }
        if pathPrompt != nil, key != .char("c", .ctrl) {
            handleInPathPrompt(key)
            paint()
            return
        }
        if renaming != nil, key != .char("c", .ctrl) {
            handleInRename(key)
            paint()
            return
        }
        if workspaceForm != nil, key != .char("c", .ctrl) {
            handleInWorkspaceForm(key)
            paint()
            return
        }
        if taskForm != nil, key != .char("c", .ctrl) {
            handleInTaskForm(key)
            paint()
            return
        }
        if transcript?.asking != nil {
            answerAsking(key)
            paint()
            return
        }
        switch key {
        case .char("d", .ctrl) where focus == .main && tabScreen == nil && transcript?.composing == true
            && transcript?.composer.text.isEmpty == false:
            // In a prompt being written it deletes, as it does in a shell.
            guard handleInTranscript(key) else { return }
        case .char("c", .ctrl), .char("d", .ctrl): quit()
        case .char("l", .ctrl): screen.invalidate()
        case .char("z", .ctrl):
            terminal.suspend()
            return
        default:
            if help != nil {
                guard handleInHelp(key) else { return }
            } else if confirmation != nil {
                guard handleInConfirmation(key) else { return }
            } else if scheduledRunQuestion != nil {
                guard handleInScheduledRunQuestion(key) else { return }
            } else if menu != nil {
                guard handleInMenu(key) else { return }
            } else if palette != nil {
                guard handleInPalette(key) else { return }
            } else if shortcuts != nil {
                guard handleInShortcuts(key) else { return }
            } else if openHelp(for: key) {
                break
            } else if runSettings != nil {
                guard handleInRunSettings(key) else { return }
            } else if oldSessions != nil {
                guard handleInOldSessions(key) else { return }
            } else if settingsScreen != nil {
                guard handleInSettings(key) else { return }
            } else if openSettings(for: key) {
                break
            } else if newSession != nil {
                guard handleInNewSession(key) else { return }
            } else if workspaceSession != nil {
                guard handleInWorkspaceSession(key) else { return }
            } else if key == .char("k", .ctrl), place != .composer, place != .find, place != .explorerTyping, place != .branches {
                palette = CommandPalette(directory: sidebar.directory, theme: theme)
            } else if key == KeyBindings.jumpKey, place != .composer, place != .find, place != .explorerTyping, place != .branches {
                jumpToNeedsYou()
            } else if key == .char("o", .ctrl) {
                moveFocus()
            } else if key == .char("b", .ctrl), place != .composer, place != .find, place != .explorerTyping, place != .branches {
                toggleSidebar()
            } else if let step = historyStep(for: key) {
                walkHistory(step)
            } else if focus == .main, factsOpen, tabScreen == nil {
                guard handleInFacts(key) else { return }
            } else if focus == .main, tabScreen != nil {
                guard handleInTab(key) else { return }
            } else if focus == .main, let changes = workspaceChanges {
                switch changes.handle(key, rows: terminal.size.rows) {
                case .handled: break
                case .ignored: return
                case .back: closeWorkspaceChanges()
                }
            } else if focus == .main, containerScreen != nil {
                guard handleInContainer(key) else { return }
            } else if focus == .main, transcript != nil {
                guard handleInTranscript(key) else { return }
            } else if focus == .main {
                guard handleInHome(key) else { return }
            } else {
                guard handleInSidebar(key) else { return }
            }
        }
        paint()
    }

    // MARK: - Help

    // Where the person is, for the key list to start with that screen's keys.
    private var place: KeyBindings.Place {
        if confirmation != nil || scheduledRunQuestion != nil { return .confirmation }
        if menu != nil { return .menu }
        if oldSessions != nil { return .oldSessions }
        if let shortcuts { return shortcuts.place }
        if settingsScreen != nil || runSettings != nil { return .settings }
        if palette != nil { return .palette }
        if newSession != nil || workspaceSession != nil { return .newSession }
        if focus == .main, let tabScreen { return tabScreen.place }
        if focus == .main, let transcript {
            if transcript.isFindEditing { return .find }
            if transcript.composing { return .composer }
            if let prompt = transcript.prompt { return prompt.isQuestion ? .question : .permission }
            return .transcript
        }
        if focus == .main, let workspaceChanges { return workspaceChanges.place }
        if focus == .main, containerScreen != nil { return containerSync?.isOpen == true ? .branches : .container }
        if focus == .main { return .home }
        return sidebar.editingFilter ? .filter : .sidebar
    }

    // MARK: - Focus

    // The focus key swaps between the sidebar and the main pane. The main pane only takes
    // it while it shows something with keys of its own: a session, or Home with sessions
    // to list.
    private var mainHasKeys: Bool { transcript != nil || containerScreen != nil || !home.isEmpty }

    private func moveFocus() {
        switch focus {
        case .sidebar where mainHasKeys: focus = .main
        case .sidebar: break
        case .main: focus = .sidebar
        }
    }

    // The sidebar key. Docked, it puts the sidebar away, and the main pane takes the
    // whole width and the keys; put away, it brings it back with the keys. Where the
    // sidebar is not docked, it opens over the main pane, or closes back to it. With
    // nothing in the main pane to take the keys the sidebar is all there is, so it stays
    // on screen, over the main pane.
    private func toggleSidebar() {
        if !Layout.isNarrow(terminal.size.cols) {
            sidebarHidden.toggle()
            focus = sidebarHidden && mainHasKeys ? .main : .sidebar
        } else {
            focus = focus == .sidebar && mainHasKeys ? .main : .sidebar
        }
    }

    // `?` opens the key list from any screen whose letters are keys. Where keys type
    // text (the composer, the filter) it types a question mark instead.
    private func openHelp(for key: Key) -> Bool {
        guard key == .char("?", []) || key == .char("?", .shift),
              place != .composer, place != .filter, place != .question, place != .find,
              place != .explorerTyping, place != .branches else { return false }
        help = HelpView(from: place)
        return true
    }

    // MARK: - Settings

    // `,` opens the settings, as Cmd-, does in the GUI, from any screen whose letters are
    // keys.
    private func openSettings(for key: Key) -> Bool {
        guard key == .char(",", []), [.sidebar, .home, .transcript, .changes, .diff, .tab, .container, .explorer].contains(place) else { return false }
        openSettings()
        return true
    }

    // Opens the settings screen, read fresh from the station. Also for whatever else
    // leads there, such as the sidebar's Tools entry.
    func openSettings() {
        work { [weak self, commands] in
            guard let settings = try? await commands.readSettings(), let self, !self.quitting else { return }
            self.update = settings.update
            if self.settingsScreen == nil {
                self.settingsScreen = SettingsScreen(settings)
            } else {
                self.settingsScreen?.show(settings)
            }
            self.paint()
        }
    }

    private func handleInSettings(_ key: Key) -> Bool {
        guard var screen = settingsScreen else { return false }
        let outcome = screen.handle(key, rows: terminal.size.rows)
        settingsScreen = screen
        switch outcome {
        case .ignored: return false
        case .handled: break
        case .close: settingsScreen = nil
        case .recheck: openSettings()
        case .change(let id, let value):
            work { [weak self, commands] in
                do throws(StationRefusal) {
                    let settings = try await commands.changeSetting(id, to: value)
                    self?.settingsScreen?.show(settings)
                } catch {
                    self?.settingsScreen?.notice = error.message
                }
                self?.paint()
            }
        }
        return true
    }

    private func handleInHelp(_ key: Key) -> Bool {
        switch help?.handle(key, rows: terminal.size.rows) {
        case .close: help = nil
        case .handled: break
        case .ignored, nil: return false
        }
        return true
    }

    // MARK: - The sidebar

    private func handleInSidebar(_ key: Key) -> Bool {
        if sidebar.editingFilter { return handleInFilter(key) }
        switch key {
        case .char("q", []): quit()
        case .enter([]): activateSelected()
        case .char("a", []): openRowActions()
        case .char(" ", []): sidebar.toggleFold()
        case .char("n", []): openNewSession()
        case .char("/", []): sidebar.startFilter()
        case .escape where !sidebar.filter.isEmpty: sidebar.clearFilter()
        case .up, .char("k", []), .char("p", .ctrl): sidebar.move(by: -1)
        case .down, .char("j", []), .char("n", .ctrl): sidebar.move(by: 1)
        case .left, .char("h", []), .tab(.shift): sidebar.moveContainer(by: -1)
        case .right, .char("l", []), .tab([]): sidebar.moveContainer(by: 1)
        case .pageUp: sidebar.move(by: -max(terminal.size.rows - 4, 1))
        case .pageDown: sidebar.move(by: max(terminal.size.rows - 4, 1))
        case .home, .char("g", []): sidebar.moveToFirst()
        case .end, .char("G", []): sidebar.moveToLast()
        default: return false
        }
        return true
    }

    // While a filter is typed, printable keys go to it, and only keys that type nothing
    // move the selection.
    private func handleInFilter(_ key: Key) -> Bool {
        switch key {
        case .escape: sidebar.clearFilter()
        case .enter([]):
            sidebar.stopEditingFilter()
            activateSelected()
        case .up, .char("p", .ctrl): sidebar.move(by: -1)
        case .down, .char("n", .ctrl): sidebar.move(by: 1)
        case .pageUp: sidebar.move(by: -max(terminal.size.rows - 4, 1))
        case .pageDown: sidebar.move(by: max(terminal.size.rows - 4, 1))
        default: return sidebar.editFilter(with: key)
        }
        return true
    }

    // Enter on what the sidebar's selection is on: a session opens, an entry of the Needs
    // you stack opens its session, Add and Tools open their menus, and a row with no
    // screen of its own does what the sidebar does with it (fold, See more, reveal).
    private func activateSelected() {
        switch sidebar.target {
        case .row(.session)?: openSelected()
        case .row(.container(let container, _))?:
            // While filtering, the container shows all its sessions too, and the sidebar
            // keeps the keys for the filter.
            let filtering = !sidebar.filter.isEmpty
            sidebar.activate()
            openContainer(container.id, focusing: !filtering)
        case .extra(.notice(let noticed))?: openNoticed(noticed)
        case .extra(.showCurrent)?: sidebar.showCurrent()
        case .extra(.oldSessions)?: openOldSessions()
        case .extra(.orphans)?: askToPruneOrphans()
        case .extra(.add)?: menu = addMenu()
        case .extra(.tools)?: menu = toolsMenu()
        case .row?, nil: sidebar.activate()
        }
    }

    // MARK: - Needs you

    // A session from the Needs you stack opens as the GUI opens one: the filter goes, its
    // container unfolds, and its card shows even past the container's limit.
    private func openNoticed(_ noticed: SidebarView.Notice) {
        sidebar.clearFilter()
        openSession(noticed.row.id, conversation: noticed.row.conversation)
    }

    // The jump key: the next session that needs the person, or the first running one.
    private func jumpToNeedsYou() {
        guard let target = sidebar.jumpTarget() else {
            sidebar.notice = "Nothing needs you, and nothing is running."
            return
        }
        openNoticed(target)
    }

    // MARK: - Actions menus

    private func openRowActions() {
        guard let target = sidebar.target else { return }
        menu = rowActions(for: target)
    }

    private static let inTheGUI = "in the GUI for now"

    // A row's actions menu, the terminal's version of the GUI's context menus. Entries the
    // TUI cannot do yet are listed, as the GUI lists them, and say so; a feature that adds
    // one turns its `.unavailable` into what it does: `.run` for an action, `.confirm` with
    // an `ImpactConfirmation` for a deletion.
    func rowActions(for target: SidebarView.Target) -> ActionMenu? {
        var title: String
        var subtitle: String?
        var actions: [MenuAction]
        let later = MenuAction.Effect.unavailable(Self.inTheGUI)
        switch target {
        case .row(.session(let row, let container)):
            (title, subtitle, actions) = (row.title, container.name, sessionActions(row))
        case .extra(.notice(let noticed)):
            (title, subtitle, actions) = (noticed.row.title, noticed.container.name, sessionActions(noticed.row))
        case .row(.container(let container, let expanded)):
            title = container.name
            subtitle = container.path
            let fold = container.sessions.isEmpty ? [] : [
                MenuAction(expanded ? "Fold" : "Unfold", detail: "Space", .run { [weak self] in
                    self?.sidebar.select(container.id)
                    self?.sidebar.toggleFold()
                }),
            ]
            let newSession = MenuAction("New session", detail: "n", .run { [weak self] in
                self?.sidebar.select(container.id)
                self?.openNewSession()
            })
            switch container.kind {
            case .project:
                let project = projectActions(container)
                actions = [project.pin, project.rename, newSession] + project.cleanup + [project.shell] + fold
                    + [MenuAction("Clear idle sessions", destructive: true, project.clear),
                       MenuAction("Remove project", destructive: true, project.remove)]
            case .task:
                let task = projectActions(container)
                actions = taskActions(container) + [task.pin, MenuAction("Run task", detail: "n", .run { [weak self] in
                    self?.runTask(container.id)
                }), task.rename] + task.cleanup + [task.shell] + fold
                    + [MenuAction("Clear idle runs", destructive: true, task.clear),
                       MenuAction("Delete task", destructive: true, task.remove)]
            case .workspace:
                actions = workspaceActions(container, fold: fold)
            }
        case .row(.section(let group, _, let folded)):
            title = group.title
            actions = [MenuAction(folded ? "Unfold" : "Fold", detail: "Space", .run { [weak self] in
                self?.sidebar.select(SidebarView.Row.sectionID(group))
                self?.sidebar.toggleFold()
            })]
        case .row(.more), .extra:
            return nil
        }
        actions += extraRowActions.flatMap { $0(target) }
        return actions.isEmpty ? nil : ActionMenu(title: title, subtitle: subtitle, actions: actions)
    }

    // A session card's actions, as its context menu lists them in the GUI.
    private func sessionActions(_ row: RemoteSessionRow) -> [MenuAction] {
        [MenuAction("Open", detail: "Enter", .run { [weak self] in
            self?.sidebar.clearFilter()
            self?.openSession(row.id, conversation: row.conversation)
        })] + cardActions(id: row.id, title: row.title, isPinned: row.isPinned, isUnread: row.isUnread,
                          folder: row.folder)
    }

    // What a session's context menu offers in the GUI, after Open: pin, read or unread,
    // rename, regenerate the title, a shell in its folder (the terminal's "Open in
    // Terminal") and delete.
    private func cardActions(id: String, title: String, isPinned: Bool, isUnread: Bool,
                             folder: String?) -> [MenuAction] {
        [
            MenuAction(isPinned ? "Unpin" : "Pin", .run { [weak self] in
                self?.sessionAction(id, isPinned ? .unpin : .pin)
            }),
            MenuAction(isUnread ? "Mark as read" : "Mark as unread", .run { [weak self] in
                self?.sessionAction(id, isUnread ? .markRead : .markUnread)
            }),
            MenuAction("Rename…", .run { [weak self] in
                self?.rename(title) { [weak self] name in
                    await self?.refusal { commands throws(StationRefusal) in
                        try await commands.sessionAction(id, .rename(title: name))
                    }
                }
            }),
            MenuAction("Regenerate session title", .run { [weak self] in self?.sessionAction(id, .regenerateTitle) }),
            MenuAction("Open a shell here", .run { [weak self] in
                self?.openShell(in: folder, missing: "\(title)'s folder is missing.")
            }),
            MenuAction("Delete session", destructive: true, .run { [weak self] in self?.askToDeleteSession(id) }),
        ]
    }

    // Does an action to a session through the station, and hands what it leaves to
    // `then`. A refusal shows under the open session, or in the sidebar.
    private func sessionAction(_ id: String, _ action: RemoteSessionAction,
                               then: (@MainActor (RemoteSessionActionResult) -> Void)? = nil) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let result = try await commands.sessionAction(id, action)
                then?(result)
            } catch {
                self?.say(error.message, about: id)
            }
            self?.paint()
        }
    }

    // Under the session when it is the one open, and in the sidebar otherwise.
    private func say(_ notice: String, about id: String) {
        if transcript != nil, transcript?.sessionID == id || openedRowID == id {
            transcript?.notice = notice
        } else {
            sidebar.notice = notice
        }
    }

    // Reads what deleting the session takes from the station, and asks with it. The
    // session goes from the main pane once it is deleted.
    private func askToDeleteSession(_ id: String) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let impact = try await commands.sessionRemovalImpact(id)
                self?.confirmation = (ImpactConfirmation(impact), then: { [weak self] in
                    self?.sessionAction(id, .delete) { [weak self] _ in
                        guard let self, self.openedRowID == id || self.transcript?.sessionID == id else { return }
                        self.goHome()
                    }
                })
            } catch {
                self?.say(error.message, about: id)
            }
            self?.paint()
        }
    }

    // MARK: - The open session's actions

    // `m` over the open session: what it offers now, then what its card's menu offers.
    private func openSessionMenu() {
        guard let open = transcript else { return }
        let header = open.transcript.header
        let upkeep = header.upkeep ?? RemoteSessionUpkeep()
        let id = open.sessionID
        var actions: [MenuAction] = []
        if upkeep.canContinue {
            actions.append(MenuAction("Continue", detail: "carry on where the turn stopped", .run { [weak self] in
                self?.sessionAction(id, .continue)
            }))
        }
        if upkeep.canRetry {
            actions.append(MenuAction("Retry turn", .run { [weak self] in self?.sessionAction(id, .retry) }))
        }
        if header.failure != nil {
            actions.append(MenuAction("Dismiss failure", .run { [weak self] in self?.sessionAction(id, .dismissFailure) }))
        }
        if let suggestion = upkeep.suggestion {
            actions.append(MenuAction("Send the suggestion", detail: "s · " + suggestion, .run { [weak self] in
                self?.useSuggestion()
            }))
            actions.append(MenuAction("Edit the suggestion", .run { [weak self] in
                self?.sessionAction(id, .takeSuggestion) { [weak self] result in self?.takeIntoComposer(result.draft, in: id) }
            }))
            actions.append(MenuAction("Dismiss the suggestion", .run { [weak self] in
                self?.sessionAction(id, .dismissSuggestion)
            }))
        }
        if !open.transcript.queued.isEmpty {
            let queued = open.transcript.queued
            actions.append(MenuAction("Remove a queued prompt…", .run { [weak self] in
                self?.menu = ActionMenu(title: "Remove a queued prompt", subtitle: header.title,
                                        actions: queued.map { prompt in
                    MenuAction(Self.firstLine(prompt.text), .run { [weak self] in
                        self?.sessionAction(id, .unqueue(promptID: prompt.id))
                    })
                })
            }))
        }
        let messages = open.transcript.messages
        let prompts = { (ids: [String]) -> [RemoteMessage] in
            Array(messages.filter { ids.contains($0.id) }.reversed())
        }
        let rewindable = prompts(upkeep.rewindable)
        if !rewindable.isEmpty {
            let effect: MenuAction.Effect = header.isBusy ? .unavailable("once the turn ends") : .run { [weak self] in
                self?.menu = ActionMenu(title: "Rewind to a prompt",
                                        subtitle: "It and everything after it go; files keep their state",
                                        actions: rewindable.map { message in
                    MenuAction(Self.firstLine(message.text), .run { [weak self] in self?.rewind(to: message.id) })
                })
            }
            actions.append(MenuAction("Rewind to a prompt…", effect))
        }
        let forkable = prompts(upkeep.forkable)
        if !forkable.isEmpty {
            actions.append(MenuAction("Fork from a prompt…", .run { [weak self] in
                self?.menu = ActionMenu(title: "Fork from a prompt",
                                        subtitle: "A new session carries the conversation up to it",
                                        actions: forkable.map { message in
                    MenuAction(Self.firstLine(message.text), .run { [weak self] in self?.fork(id, from: message.id) })
                })
            }))
        }
        if upkeep.canRecap || upkeep.isRecapping {
            let effect: MenuAction.Effect = upkeep.isRecapping ? .unavailable("being written")
                : .run { [weak self] in self?.sessionAction(id, .recap) }
            actions.append(MenuAction("Recap", effect))
        }
        actions.append(MenuAction("Run settings…", detail: "r · model, effort, permissions", .run { [weak self] in
            self?.openRunSettings()
        }))
        actions.append(MenuAction("Attach a file…", detail: "+", .run { [weak self] in self?.attachFile() }))
        if !open.composer.attachments.isEmpty {
            actions.append(MenuAction("Remove the attached files", .run { [weak self] in
                self?.transcript?.composer.attachments = []
            }))
        }
        actions.append(MenuAction("Custom instructions…", detail: "I", .run { [weak self] in self?.editInstructions() }))
        let row = openedRowID ?? id
        let folder = sidebar.directory?.containers?.lazy.flatMap(\.sessions).first { $0.id == row }?.folder
        actions += cardActions(id: row, title: header.title, isPinned: upkeep.isPinned, isUnread: upkeep.isUnread,
                               folder: folder)
        menu = ActionMenu(title: header.title, subtitle: header.container ?? header.project, actions: actions)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    // Winds the open session back to before a prompt. What the composer holds goes to the
    // front of the queue, as in the GUI, and the prompt comes back to the composer.
    private func rewind(to messageID: String) {
        guard let open = transcript else { return }
        let id = open.sessionID
        sessionAction(id, .rewind(messageID: messageID, draft: open.composer.string)) { [weak self] result in
            guard let self, self.transcript?.sessionID == id else { return }
            self.transcript?.composer.clear()
            self.takeIntoComposer(result.draft, in: id)
        }
    }

    // A new session from before a prompt, opened with the prompt in its composer.
    private func fork(_ id: String, from messageID: String) {
        sessionAction(id, .fork(messageID: messageID)) { [weak self] result in
            guard let self, let fork = result.openSession else { return }
            var composer = ComposerView()
            composer.replace(with: result.draft ?? "")
            self.drafts[fork] = composer
            self.work { [weak self] in
                guard let self else { return }
                if let directory = try? await self.commands.listDirectory() { self.sidebar.show(directory) }
                self.sidebar.reveal(fork)
                await self.open(fork)
                self.paint()
            }
        }
    }

    // Text the station handed back for the composer, added after what is written there.
    private func takeIntoComposer(_ text: String?, in id: String) {
        guard let text, !text.isEmpty, transcript?.sessionID == id else { return }
        let written = transcript?.composer.string ?? ""
        transcript?.composer.replace(with: written.isBlank ? text : written + " " + text)
        transcript?.composing = true
    }

    // `s`: the suggestion goes as the next prompt, or joins the end of what is written.
    private func useSuggestion() {
        guard let open = transcript, open.transcript.header.upkeep?.suggestion != nil else {
            transcript?.notice = "There is no suggestion to send."
            return
        }
        let id = open.sessionID
        if open.composer.string.isBlank {
            sessionAction(id, .sendSuggestion) { [weak self] _ in self?.transcript?.scrollToBottom() }
        } else {
            sessionAction(id, .takeSuggestion) { [weak self] result in self?.takeIntoComposer(result.draft, in: id) }
        }
    }

    // Add, at the foot of the sidebar, as the GUI's Add button offers it.
    private func addMenu() -> ActionMenu {
        ActionMenu(title: "Add", actions: [
            MenuAction("Add project…", .run { [weak self] in self?.addProject() }),
            MenuAction("Create workspace…", .run { [weak self] in self?.openWorkspaceForm() }),
            MenuAction("New task…", .run { [weak self] in self?.newTask() }),
        ])
    }

    // Tools, at the foot of the sidebar, as the GUI's gear opens them. The tools that live
    // only in the GUI say so.
    private func toolsMenu() -> ActionMenu {
        let gui = MenuAction.Effect.unavailable("open in the GUI")
        return ActionMenu(title: "Tools", actions: [
            MenuAction("MCP servers", gui),
            MenuAction("Skills", gui),
            MenuAction("Docker", gui),
            MenuAction("Dispatch", gui),
            MenuAction("Shortcuts", detail: "this Mac", .run { [weak self] in self?.openShortcuts(in: nil) }),
            MenuAction("Troubleshoot", .run { [weak self] in self?.newDiagnosis() }),
            MenuAction("Settings", detail: ",", .run { [weak self] in self?.openSettings() }),
        ])
    }

    private func handleInMenu(_ key: Key) -> Bool {
        guard var open = menu else { return false }
        let outcome = open.handle(key)
        menu = open
        switch outcome {
        case .ignored: return false
        case .handled: break
        case .close: menu = nil
        case .choose(let action):
            menu = nil
            switch action.effect {
            case .run(let run): run()
            case .confirm(let view, let then): confirmation = (view, then)
            case .unavailable: break
            }
        }
        return true
    }

    private func handleInConfirmation(_ key: Key) -> Bool {
        guard var open = confirmation else { return false }
        let outcome = open.view.handle(key)
        confirmation = open
        switch outcome {
        case .ignored: return false
        case .handled: break
        case .cancel: confirmation = nil
        case .confirm:
            confirmation = nil
            open.then()
        }
        return true
    }

    // MARK: - Projects and tasks

    // What a project's or task's menu does, as the GUI's project row menu does it. Wake now
    // is listed only while the cleanup is snoozed; the deletions ask with what the station
    // says they take.
    private func projectActions(_ container: RemoteContainer)
        -> (pin: MenuAction, rename: MenuAction, cleanup: [MenuAction], shell: MenuAction,
            clear: MenuAction.Effect, remove: MenuAction.Effect) {
        let id = container.id
        let pin = MenuAction(container.isPinned ? "Unpin" : "Pin", .run { [weak self] in
            self?.changeProject(id, .pin(!container.isPinned))
        })
        let rename = MenuAction("Rename…", .run { [weak self] in
            self?.rename(container.name) { [weak self] name in
                await self?.refusal { commands throws(StationRefusal) in try await commands.changeProject(id, .rename(name: name)) }
            }
        })
        let snoozed = container.snoozedUntil != nil
        var cleanup = [MenuAction(snoozed ? "Snooze cleanup 1 more day" : "Snooze cleanup 1 day", .run { [weak self] in
            self?.changeProject(id, .snoozeCleanup)
        })]
        if snoozed {
            cleanup.append(MenuAction("Wake now", .run { [weak self] in self?.changeProject(id, .wakeCleanup) }))
        }
        let shell = MenuAction("Open a shell here", .run { [weak self] in self?.openShell(in: container) })
        return (pin, rename, cleanup, shell,
                .run { [weak self] in self?.askToRemove(.idleSessions, of: id) },
                .run { [weak self] in self?.askToRemove(.project, of: id) })
    }

    private func changeProject(_ id: String, _ change: ProjectChange) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.changeProject(id, change)
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    private func handleInRename(_ key: Key) {
        guard var open = renaming else { return }
        let outcome = open.view.handle(key)
        renaming = open
        switch outcome {
        case .cancel: renaming = nil
        case .edited, .ignored: break
        case .save:
            let name = open.view.field.string
            work { [weak self] in
                if let refused = await open.save(name) {
                    self?.renaming?.view.notice = refused.message
                } else {
                    self?.renaming = nil
                }
                self?.paint()
            }
        }
    }

    // Asks for a new name in place of `name`, and saves it with `save`.
    private func rename(_ name: String, save: @escaping @MainActor (String) async -> StationRefusal?) {
        renaming = (NamePromptView(title: "Rename \(name)", name: name), save)
    }

    // Runs a command against the station and answers with its refusal, if any.
    private func refusal(_ command: @MainActor (any StationInterface) async throws(StationRefusal) -> Void) async
        -> StationRefusal? {
        do throws(StationRefusal) {
            try await command(commands)
            return nil
        } catch {
            return error
        }
    }

    // Reads what the removal would take from the station, and asks with it. What cannot
    // be removed says why in the sidebar.
    private func askToRemove(_ removal: ProjectRemovalKind, of id: String) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let impact = try await commands.readRemoval(removal, of: id)
                self?.confirmation = (ImpactConfirmation(impact), then: { [weak self] in self?.remove(removal, of: id) })
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    private func remove(_ removal: ProjectRemovalKind, of id: String) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.remove(removal, of: id)
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    // `$SHELL` in the folder, on this terminal, until it exits; the TUI comes back then.
    private func openShell(in container: RemoteContainer) {
        openShell(in: container.isMissing ? nil : container.folder, missing: "\(container.name)'s folder is missing.")
    }

    private func openShell(in folder: String?, missing: String) {
        guard let handoff else { return }
        guard let folder, FileManager.default.fileExists(atPath: folder) else {
            sidebar.notice = missing
            return
        }
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        work { [weak self] in
            let status = await handoff.run(Handoff(arguments: [shell], directory: folder))
            guard let self else { return }
            if status < 0 { self.sidebar.notice = "\(shell) could not be started." }
            self.screen.invalidate()
            self.paint()
        }
    }

    // Add's "Add project…": a typed path, with completion, until the station takes it or
    // the person gives up. A refusal asks again with the path and the reason. The project
    // added is pointed at in the sidebar, which takes the keys.
    private func addProject(typed: String = "", refusal: String? = nil) {
        let start = FileManager.default.currentDirectoryPath
        answerPath(nil)
        pathPrompt = PathPromptView(prompt: "Add project", message: "The folder Claude Code should work in.",
                                    startingAt: start, text: typed, notice: refusal)
        pathChosen = { [weak self, commands] answer in
            let path = answer.trimmingCharacters(in: .whitespaces)
            let full = path.hasPrefix("/") || path.hasPrefix("~") || path.isEmpty
                ? path : (start as NSString).appendingPathComponent(path)
            self?.work { [weak self] in
                do throws(StationRefusal) {
                    let id = try await commands.addProject(path: full)
                    guard let self else { return }
                    if let directory = try? await commands.listDirectory() { self.sidebar.show(directory) }
                    self.sidebar.clearFilter()
                    self.sidebar.reveal(id)
                    self.focus = .sidebar
                } catch {
                    self?.addProject(typed: answer, refusal: error.message)
                }
                self?.paint()
            }
        }
    }

    // MARK: - Workspaces

    // What a workspace's menu does, as the GUI's workspace row menu does it: pin, rename,
    // a new session across its projects, fold, and a deletion that asks with what the
    // station says it takes.
    private func workspaceActions(_ container: RemoteContainer, fold: [MenuAction]) -> [MenuAction] {
        let id = container.id
        return [
            MenuAction(container.isPinned ? "Unpin" : "Pin", .run { [weak self] in
                self?.changeWorkspace(id, .pin(!container.isPinned))
            }),
            MenuAction("Rename…", .run { [weak self] in
                self?.rename(container.name) { [weak self] name in
                    await self?.refusal { commands throws(StationRefusal) in try await commands.changeWorkspace(id, .rename(name: name)) }
                }
            }),
            MenuAction("New session", detail: "n", .run { [weak self] in self?.openWorkspaceSession(id) }),
        ] + fold + [
            MenuAction("Delete workspace", destructive: true, .run { [weak self] in self?.askToRemoveWorkspace(id) }),
        ]
    }

    // The workspace a new session goes in: the one the open screen shows, or the one the
    // sidebar points at, or holds the session it points at.
    private var selectedWorkspaceID: String? {
        if focus == .main, let screen = containerScreen {
            return screen.container.kind == .workspace ? screen.id : nil
        }
        switch sidebar.target {
        case .row(.container(let container, _))? where container.kind == .workspace: return container.id
        case .row(.session(_, let container))? where container.kind == .workspace: return container.id
        default: return nil
        }
    }

    private func changeWorkspace(_ id: String, _ change: WorkspaceChange, thenRead: Bool = false) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.changeWorkspace(id, change)
                if thenRead { self?.readStatus() }
            } catch {
                self?.sidebar.notice = error.message
                if let self, self.containerScreen?.id == id { self.containerScreen?.notice = error.message }
            }
            self?.paint()
        }
    }

    private func askToRemoveWorkspace(_ id: String) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let impact = try await commands.readWorkspaceRemoval(id)
                self?.confirmation = (ImpactConfirmation(impact), then: { [weak self] in self?.removeWorkspace(id) })
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    private func removeWorkspace(_ id: String) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.removeWorkspace(id)
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    // Add's "Create workspace…": a name and the projects, from the projects the
    // directory lists (tasks are not projects to work across).
    private func openWorkspaceForm() {
        let choices = (sidebar.directory?.containers ?? []).filter { $0.kind == .project }
            .map { WorkspaceForm.Choice(id: $0.id, name: $0.name, path: $0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        workspaceForm = WorkspaceForm(choices: choices)
    }

    // Once the workspace is made, its screen opens with its new-session form over it, as
    // the GUI moves from one sheet to the next.
    private func handleInWorkspaceForm(_ key: Key) {
        guard var form = workspaceForm else { return }
        let outcome = form.handle(key)
        workspaceForm = form
        switch outcome {
        case .handled, .ignored: break
        case .cancel: workspaceForm = nil
        case .create:
            workspaceForm?.creating = true
            let name = form.name.string, picked = form.picked, lead = form.lead ?? ""
            work { [weak self, commands] in
                do throws(StationRefusal) {
                    let id = try await commands.createWorkspace(name: name, projectIDs: picked, leadProjectID: lead)
                    guard let self else { return }
                    self.workspaceForm = nil
                    if let directory = try? await commands.listDirectory() { self.sidebar.show(directory) }
                    self.sidebar.clearFilter()
                    self.openContainer(id)
                    self.openWorkspaceSession(id)
                } catch {
                    self?.workspaceForm?.creating = false
                    self?.workspaceForm?.notice = error.message
                }
                self?.paint()
            }
        }
    }

    // The new-session form for a workspace, on its members as its screen reads them.
    private func openWorkspaceSession(_ id: String) {
        guard let container = sidebar.directory?.containers?.first(where: { $0.id == id }) else { return }
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let status = try await commands.readContainerStatus(id)
                let options = try await commands.sessionOptions()
                guard let self, self.workspaceSession == nil, self.newSession == nil else { return }
                self.workspaceSession = WorkspaceSessionForm(workspaceID: id, name: container.name,
                                                             members: status.members ?? [], options: options)
                self.discoverWorkspaceModels()
            } catch {
                self?.sidebar.notice = error.message
            }
            self?.paint()
        }
    }

    private func discoverWorkspaceModels() {
        guard let agent = workspaceSession?.agent else { return }
        work { [weak self, commands] in
            guard let options = try? await commands.discoverModels(for: agent),
                  let self, self.workspaceSession != nil else { return }
            self.workspaceSession?.update(options)
            self.paint()
        }
    }

    private func handleInWorkspaceSession(_ key: Key) -> Bool {
        guard var form = workspaceSession else { return false }
        form.notice = nil
        if form.creating { return true }
        switch key {
        case .escape, .char("q", []):
            workspaceSession = nil
            return true
        case .up, .char("k", []), .char("p", .ctrl), .tab(.shift): form.moveField(by: -1)
        case .down, .char("j", []), .char("n", .ctrl), .tab([]): form.moveField(by: 1)
        case .left, .char("h", []): form.change(by: -1)
        case .right, .char("l", []), .char(" ", []): form.change(by: 1)
        case .char("x", []): form.toggleAttached()
        case .enter([]):
            workspaceSession = form
            startWorkspaceSession()
            return true
        default: return false
        }
        let agentBefore = workspaceSession?.agent
        workspaceSession = form
        if form.agent != agentBefore { discoverWorkspaceModels() }
        return true
    }

    // The station makes the session, worktrees and all; it then opens with the composer
    // ready for its first prompt.
    private func startWorkspaceSession() {
        guard let request = workspaceSession?.request else {
            workspaceSession?.notice = "There is nothing to start: install an agent first."
            return
        }
        workspaceSession?.creating = true
        newSessionWork = work { [weak self, commands] in
            do throws(StationRefusal) {
                let id = try await commands.createWorkspaceSession(request)
                guard let self else { return }
                self.workspaceSession = nil
                if let directory = try? await commands.listDirectory() { self.sidebar.show(directory) }
                self.sidebar.reveal(id)
                await self.open(id)
                if self.transcript?.sessionID == id { self.transcript?.composing = true }
            } catch {
                self?.workspaceSession?.creating = false
                self?.workspaceSession?.notice = error.message
            }
            self?.paint()
        }
    }

    // The workspace's changes across its members, over its screen.
    private func openWorkspaceChanges(_ container: RemoteContainer) {
        closeWorkspaceChanges()
        workspaceChanges = WorkspaceChanges(
            workspaceID: container.id, name: container.name, commands: commands, theme: theme,
            work: { [weak self] body in self?.work(body) ?? Task {} },
            repaint: { [weak self] in self?.paint() })
    }

    private func closeWorkspaceChanges() {
        workspaceChanges?.close()
        workspaceChanges = nil
    }

    // MARK: - The command palette

    private func handleInPalette(_ key: Key) -> Bool {
        guard var open = palette else { return false }
        let outcome = open.handle(key, rows: terminal.size.rows)
        palette = open
        switch outcome {
        case .ignored: return false
        case .edited: break
        case .close: palette = nil
        case .go(let item):
            palette = nil
            go(to: item)
        }
        return true
    }

    // Where a result goes. A project, task or workspace opens its screen.
    private func go(to item: CommandPalette.Item) {
        switch item.destination {
        case .session(let id): openSession(id, conversation: item.conversation)
        case .container(let id): openContainer(id)
        case .action(.newSession): openNewSession()
        case .action(.home): goHome()
        case .action(.back): walkHistory(.back)
        case .action(.forward): walkHistory(.forward)
        case .action(.keys): help = HelpView(from: place)
        case .action(.settings): openSettings()
        }
    }

    // MARK: - Back and forward

    enum HistoryStep { case back, forward }

    // `[` and `]`, or Alt-← and Alt-→, wherever letters are keys rather than text.
    private func historyStep(for key: Key) -> HistoryStep? {
        guard [.sidebar, .home, .transcript, .permission, .changes, .diff, .tab, .container, .explorer].contains(place) else {
            return nil
        }
        switch key {
        case .char("[", []), .left(.alt): return .back
        case .char("]", []), .right(.alt): return .forward
        default: return nil
        }
    }

    // Steps along the trail, past places that have gone since, and shows where it lands.
    // A session still on its way to the screen is let arrive first, so the trail never
    // moves without the main pane following it.
    private func walkHistory(_ step: HistoryStep) {
        guard !opening else { return }
        let directory = sidebar.directory
        let reachable = { (place: NavigationPlace) -> Bool in
            switch place {
            case .home: return true
            case .session(let id):
                return directory?.containers?.contains { $0.sessions.contains { UUID(uuidString: $0.id) == id } }
                    ?? false
            case .project(let id), .workspace(let id):
                return directory?.containers?.contains { UUID(uuidString: $0.id) == id } ?? false
            }
        }
        let place = switch step {
        case .back: history.goBack(reachable: reachable)
        case .forward: history.goForward(reachable: reachable)
        }
        switch place {
        case .home: showHome()
        case .session(let uuid):
            guard let id = directory?.containers?.lazy.flatMap(\.sessions)
                .first(where: { UUID(uuidString: $0.id) == uuid })?.id else { return }
            openSession(id, conversation: sidebar.conversation(of: id), visiting: false)
        case .project(let uuid), .workspace(let uuid):
            guard let id = directory?.containers?.first(where: { UUID(uuidString: $0.id) == uuid })?.id else { return }
            openContainer(id, visiting: false)
        case nil: break
        }
    }

    // Home in the main pane, the session that was there put away with its draft.
    private func goHome() {
        showHome()
        history.visit(.home)
    }

    private func showHome() {
        closeSession()
        closeContainer()
    }

    // MARK: - Project, task and workspace screens

    // A container's screen in the main pane, in place of whatever session was there, as
    // selecting one does in the GUI. The sidebar points at it, and its strip is read.
    func openContainer(_ id: String, visiting: Bool = true, focusing: Bool = true) {
        guard let container = sidebar.directory?.containers?.first(where: { $0.id == id }) else { return }
        closeSession()
        sidebar.reveal(id)
        if focusing { focus = .main }
        if containerScreen?.id != id {
            closeWorkspaceChanges()
            containerScreen = ContainerScreen(container, theme: theme)
            // Sync applies to projects only.
            containerSync = container.kind == .project
                ? SyncActions(commands: commands, theme: theme,
                              work: { [weak self] body in self?.work(body) ?? Task {} },
                              repaint: { [weak self] in self?.paint() },
                              changed: { [weak self] in self?.readStatus() })
                : nil
        }
        if visiting, let place = containerScreen?.place { history.visit(place) }
        readStatus()
    }

    private func closeContainer() {
        statusRead?.cancel()
        closeWorkspaceChanges()
        containerScreen = nil
        containerSync = nil
    }

    private func readStatus() {
        guard let id = containerScreen?.id else { return }
        statusRead?.cancel()
        statusRead = work { [weak self, commands] in
            do throws(StationRefusal) {
                let status = try await commands.readContainerStatus(id)
                // The strip counts a project's or task's shortcuts, as the GUI's chip does.
                let shortcuts = status.kind == .workspace ? nil : try? await commands.listShortcuts(in: id)
                guard let self, !Task.isCancelled, self.containerScreen?.id == id else { return }
                self.containerScreen?.show(status)
                self.containerScreen?.shortcuts = shortcuts
                if status.kind == .task { await self.readTask(id) }
            } catch {
                guard let self, self.containerScreen?.id == id else { return }
                self.containerScreen?.notice = error.message
            }
            self?.paint()
        }
    }

    private func handleInContainer(_ key: Key) -> Bool {
        if let sync = containerSync, sync.isOpen { return sync.handle(key) }
        if containerScreen?.container.kind == .task, handleInTaskScreen(key) { return true }
        if containerSync?.start(key, at: syncTarget) == true { return true }
        switch key {
        case .escape, .left, .char("q", []), .char("h", []): focus = .sidebar
        case .enter([]):
            if let id = containerScreen?.selectedSessionID { openSession(id, conversation: sidebar.conversation(of: id)) }
        case .char("n", []): openNewSession()
        case .char("r", []): readStatus()
        case .char("l", []), .char("L", []), .char("L", .shift):
            guard let id = containerScreen?.id, let member = containerScreen?.selectedMember else { return false }
            changeWorkspace(id, .lead(projectID: member.projectID), thenRead: true)
        case .char("w", []):
            guard let id = containerScreen?.id, let member = containerScreen?.selectedMember else { return false }
            changeWorkspace(id, .worktree(projectID: member.projectID, uses: !(member.usesWorktree ?? false)),
                            thenRead: true)
        case .char("d", []):
            guard let screen = containerScreen, screen.container.kind == .workspace else { return false }
            openWorkspaceChanges(screen.container)
        case .char("!", []), .char("!", .shift):
            // A workspace screen has none of its own, as in the GUI.
            guard let screen = containerScreen, screen.container.kind != .workspace else { return true }
            openShortcuts(in: screen.id)
        case .up, .char("k", []), .char("p", .ctrl): containerScreen?.move(by: -1)
        case .down, .char("j", []), .char("n", .ctrl): containerScreen?.move(by: 1)
        case .home, .char("g", []): containerScreen?.moveToFirst()
        case .end, .char("G", []): containerScreen?.moveToLast()
        default: return false
        }
        return true
    }

    // A project screen's folder, for push, pull, fetch and branches. A task's folder is
    // not a checkout of its own, and a workspace has one per project.
    private var syncTarget: SyncActions.Target? {
        guard let screen = containerScreen, screen.container.kind == .project,
              let folder = screen.container.folder, screen.status?.checkout?.state ?? "ready" == "ready" else {
            return nil
        }
        return SyncActions.Target(scope: screen.id, checkout: folder, name: screen.container.name)
    }

    // MARK: - Command shortcuts

    // The shortcuts screen over everything, for a project's or session's id, or nil for
    // the Mac's own list.
    private func openShortcuts(in scope: String?) {
        shortcuts = ShortcutsOverlay(
            scope: scope, commands: commands, theme: theme,
            work: { [weak self] body in self?.work(body) ?? Task {} },
            repaint: { [weak self] in self?.paint() },
            confirm: { [weak self] view, then in self?.confirmation = (view, then) })
    }

    private func handleInShortcuts(_ key: Key) -> Bool {
        guard let open = shortcuts else { return false }
        if !open.takesTyping, key == .char("?", []) || key == .char("?", .shift) {
            help = HelpView(from: open.place)
            return true
        }
        switch open.handle(key) {
        case .handled: return true
        case .ignored: return false
        case .close:
            shortcuts = nil
            // The project strip's count follows what was run, added or removed.
            if containerScreen != nil { readStatus() }
            return true
        }
    }

    // MARK: - Home

    private func handleInHome(_ key: Key) -> Bool {
        switch key {
        case .escape, .left, .char("q", []), .char("h", []): focus = .sidebar
        case .enter([]):
            if let selected = home.selected { openSession(selected.id, conversation: selected.conversation) }
        case .char("n", []): openNewSession()
        case .up, .char("k", []), .char("p", .ctrl): home.move(by: -1)
        case .down, .char("j", []), .char("n", .ctrl): home.move(by: 1)
        case .home, .char("g", []): home.moveToFirst()
        case .end, .char("G", []): home.moveToLast()
        default: return false
        }
        return true
    }

    private func handleInTranscript(_ key: Key) -> Bool {
        if transcript?.isFindEditing == true { return handleInFind(key) }
        if transcript?.composing == true { return handleInComposer(key) }
        if let handled = handleInPrompt(key) { return handled }
        switch key {
        // Find takes Esc first, then n and N step through what it found.
        case .escape where transcript?.find != nil: transcript?.closeFind()
        case .char("/", []), .char("f", .ctrl): transcript?.startFind()
        case .char("n", []) where transcript?.find != nil: transcript?.stepFind(by: 1)
        case .char("N", []) where transcript?.find != nil, .char("N", .shift) where transcript?.find != nil:
            transcript?.stepFind(by: -1)
        // Escape stops a running turn, as it does in the GUI, and goes back otherwise:
        // the sidebar takes the keys and the session stays in the main pane.
        case .escape where transcript?.isBusy == true && transcript?.stopRequested == false:
            stopTurn()
        case .escape, .left, .char("q", []), .char("h", []): focus = .sidebar
        case .enter([]), .char("i", []): transcript?.composing = true
        case .char("d", []): select(.changes)
        case .char("D", []), .char("D", .shift): factsOpen = true
        case .char("L", []), .char("L", .shift): openLog()
        case .up, .char("k", []), .char("p", .ctrl): transcript?.scroll(by: -1)
        case .down, .char("j", []), .char("n", .ctrl): transcript?.scroll(by: 1)
        case .pageUp, .char("b", []), .char("u", .ctrl): transcript?.scrollPage(by: -1)
        case .pageDown, .char(" ", []), .char("f", []): transcript?.scrollPage(by: 1)
        case .home, .char("g", []): transcript?.scrollToTop()
        case .end, .char("G", []): transcript?.scrollToBottom()
        case .tab([]): transcript?.selectTool(by: 1)
        case .tab(.shift): transcript?.selectTool(by: -1)
        case .char("o", []): transcript?.toggleSelectedTool()
        case .char("O", []): transcript?.toggleAllTools()
        case .char("y", []): copy(transcript?.copyMessage())
        case .char("c", []): copy(transcript?.copyCode())
        case .char("m", []): openSessionMenu()
        case .char("s", []): useSuggestion()
        case .char("r", []): openRunSettings()
        case .char("+", []), .char("+", .shift): attachFile()
        case .char("I", []), .char("I", .shift): editInstructions()
        case .char("R", []) where canRebuild, .char("R", .shift) where canRebuild:
            if let id = transcript?.sessionID { askToRebuild(id) }
        default: return handleSessionKey(key)
        }
        return true
    }

    // Keys go to the prompt being written, except those that move the transcript under
    // it or leave the composer.
    private func handleInComposer(_ key: Key) -> Bool {
        // While a command is being typed its menu borrows the arrows, Tab, Enter and Esc.
        if transcript?.slashMatches.isEmpty == false {
            switch key {
            case .up([]): transcript?.moveSlashSelection(by: -1)
            case .down([]): transcript?.moveSlashSelection(by: 1)
            case .tab([]), .enter([]): transcript?.takeSlashSelection()
            case .escape: transcript?.dismissSlashMenu()
            default: return editComposer(key)
            }
            return true
        }
        switch key {
        case .char("t", .ctrl): attachFile()
        case .backspace([]) where transcript?.composer.text.isEmpty == true
            && transcript?.composer.attachments.isEmpty == false:
            transcript?.composer.attachments.removeLast()
        case .escape where transcript?.isBusy == true && transcript?.stopRequested == false:
            stopTurn()
        case .escape, .tab([]): transcript?.composing = false
        case .pageUp: transcript?.scrollPage(by: -1)
        case .pageDown: transcript?.scrollPage(by: 1)
        // An empty composer walks the session's earlier prompts; text being written keeps
        // the arrows for moving between its lines.
        case .up([]): recallPrompt(.earlier, key: key)
        case .down([]): recallPrompt(.later, key: key)
        default:
            return editComposer(key)
        }
        return true
    }

    // The key edits the prompt, or sends it. A prompt that has become a slash command
    // has the session's commands listed for it, read afresh as the menu opens, since
    // command files can change between prompts.
    private func editComposer(_ key: Key) -> Bool {
        let wasTyping = transcript?.slashQuery != nil
        switch transcript?.composer.handle(key) {
        case .send: sendPrompt()
        case .edited:
            transcript?.noteSlashEdit()
            if !wasTyping, transcript?.slashQuery != nil { loadCommands() }
        case .ignored, nil: return false
        }
        return true
    }

    private func loadCommands() {
        guard let id = transcript?.sessionID else { return }
        work { [weak self, commands] in
            guard let listed = try? await commands.listCommands(id), let self,
                  self.transcript?.sessionID == id else { return }
            self.transcript?.commands = listed
            self.paint()
        }
    }

    // MARK: - The composer's run settings, files and instructions

    // `r`: the open session's run settings for its next turn, read from the station.
    private func openRunSettings() {
        guard let open = transcript else { return }
        let id = open.sessionID
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let settings = try await commands.readRunSettings(id)
                guard let self, self.transcript?.sessionID == id else { return }
                var screen = SettingsScreen(settings)
                screen.title = "Run settings · \(open.transcript.header.title)"
                screen.checksAgents = false
                self.runSettings = (screen, id)
            } catch {
                self?.say(error.message, about: id)
            }
            self?.paint()
        }
    }

    private func handleInRunSettings(_ key: Key) -> Bool {
        guard var open = runSettings else { return false }
        let outcome = open.screen.handle(key, rows: terminal.size.rows)
        runSettings = open
        switch outcome {
        case .ignored: return false
        case .handled, .recheck: break
        case .close: runSettings = nil
        case .change(let id, let value):
            let sessionID = open.sessionID
            work { [weak self, commands] in
                do throws(StationRefusal) {
                    let settings = try await commands.changeRunSetting(sessionID, id, to: value)
                    self?.runSettings?.screen.show(settings)
                } catch {
                    self?.runSettings?.screen.notice = error.message
                }
                self?.paint()
            }
        }
        return true
    }

    // `+`, or Ctrl-T while writing: a file to go with the next prompt, by its path, with
    // completion. A relative path starts in the session's folder. A path to nothing asks
    // again with the reason.
    private func attachFile(typed: String = "", refusal: String? = nil) {
        guard let open = transcript else { return }
        let id = open.sessionID
        let row = openedRowID ?? id
        let folder = sidebar.directory?.containers?.lazy.flatMap(\.sessions).first { $0.id == row }?.folder
        let start = folder ?? FileManager.default.currentDirectoryPath
        answerPath(nil)
        var prompt = PathPromptView(prompt: "Attach a file", message: "A file or image to go with the next prompt.",
                                    startingAt: start, text: typed, notice: refusal)
        prompt.files = true
        prompt.chooseLabel = "attach"
        pathPrompt = prompt
        pathChosen = { [weak self] answer in
            let typed = answer.trimmingCharacters(in: .whitespaces)
            guard !typed.isEmpty else { return }
            let expanded = (typed as NSString).expandingTildeInPath
            let full = expanded.hasPrefix("/") ? expanded : (start as NSString).appendingPathComponent(expanded)
            let path = (full as NSString).standardizingPath
            guard let self, self.transcript?.sessionID == id else { return }
            guard FileManager.default.fileExists(atPath: path) else {
                self.attachFile(typed: answer, refusal: "There is no file at \(typed).")
                return
            }
            if self.transcript?.composer.attachments.contains(path) == false {
                self.transcript?.composer.attachments.append(path)
            }
            self.transcript?.composing = true
        }
    }

    // `I`: instructions for the next prompt alone, as the GUI's composer carries them.
    // Saving an empty line takes them off.
    private func editInstructions() {
        guard let open = transcript else { return }
        let id = open.sessionID
        var view = NamePromptView(title: "Custom instructions for the next prompt", name: open.composer.instructions)
        view.help = " enter keep (empty takes them off) · esc cancel"
        renaming = (view, { [weak self] text in
            guard let self, self.transcript?.sessionID == id else { return nil }
            self.transcript?.composer.instructions = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        })
    }

    // What the agent is waiting on takes its keys first. Nil leaves the key to the
    // transcript. While it waits, Esc goes back rather than stopping the turn: the turn
    // is parked on the person, and the answer is what moves it.
    private func handleInPrompt(_ key: Key) -> Bool? {
        guard let open = transcript, var prompt = open.prompt else { return nil }
        if key == .escape {
            focus = .sidebar
            return true
        }
        switch prompt.handle(key) {
        case .ignored: return nil
        case .edited: transcript?.prompt = prompt
        case .answer(let answer, let answers):
            transcript?.prompt = prompt
            work { [weak self, commands] in
                do throws(StationRefusal) {
                    try await commands.answerPermission(open.sessionID, requestID: prompt.permission.id,
                                                        answer: answer, answers: answers)
                    guard let self, self.transcript?.prompt?.permission.id == prompt.permission.id else { return }
                    self.transcript?.prompt = nil
                    self.transcript?.scrollToBottom()
                } catch {
                    guard let self, self.transcript?.sessionID == open.sessionID else { return }
                    self.transcript?.notice = error.message
                }
                self?.paint()
            }
        }
        return true
    }

    // MARK: - The open session

    private func sendPrompt() {
        guard let open = transcript, open.composer.hasSomethingToSend else { return }
        let text = open.composer.string
        let attachments = open.composer.attachments
        let instructions = open.composer.instructions
        work { [weak self, commands] in
            do throws(StationRefusal) {
                if attachments.isEmpty && instructions.isEmpty {
                    try await commands.sendPrompt(open.sessionID, prompt: text)
                } else {
                    try await commands.sendPrompt(open.sessionID, RemotePrompt(
                        text: text, attachments: attachments, customInstructions: instructions))
                }
                // What was typed after Enter stays.
                guard let self, self.transcript?.sessionID == open.sessionID else { return }
                if self.transcript?.composer.string == text { self.transcript?.composer.clear() }
                self.transcript?.composer.attachments.removeAll { attachments.contains($0) }
                if self.transcript?.composer.instructions == instructions { self.transcript?.composer.instructions = "" }
                self.transcript?.scrollToBottom()
            } catch {
                guard let self, self.transcript?.sessionID == open.sessionID else { return }
                self.transcript?.notice = error.message
            }
            self?.paint()
        }
    }

    // The composer takes the recalled prompt, or is emptied after the newest one. When
    // there is nothing to recall the key goes to the editor after all, to move between
    // the lines of what is being written. Steps run one after another, each from what the
    // one before left, so a held arrow walks back one prompt per key.
    private func recallPrompt(_ direction: PromptRecall, key: Key) {
        let previous = recallWork
        recallWork = work { [weak self, commands] in
            await previous?.value
            guard let self, let open = self.transcript else { return }
            let draft = open.composer.string
            let recalled = try? await commands.recallPrompt(open.sessionID, direction, draft: draft)
            guard self.transcript?.sessionID == open.sessionID,
                  self.transcript?.composer.string == draft else { return }
            if let recalled {
                self.transcript?.composer.replace(with: recalled)
            } else {
                _ = self.transcript?.composer.handle(key)
            }
            self.paint()
        }
    }

    private func stopTurn() {
        guard let open = transcript else { return }
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await commands.stopTurn(open.sessionID)
                guard let self, self.transcript?.sessionID == open.sessionID else { return }
                self.transcript?.noteStopRequested()
            } catch {
                guard let self, self.transcript?.sessionID == open.sessionID else { return }
                self.transcript?.notice = error.message
            }
            self?.paint()
        }
    }

    // The selected session opens in the main pane on the conversation its card speaks
    // for, so a Design companion that is waiting is the one shown, ready to answer. The
    // main pane takes the keys. A container opens its own screen (see `openContainer`).
    private func openSelected() {
        guard let id = sidebar.openableID else { return }
        openSession(id, conversation: sidebar.conversation(of: id))
    }

    // A session by its sidebar id, from wherever it was picked: the sidebar, Home or the
    // palette. The sidebar points at it too.
    private func openSession(_ id: String, conversation: RemoteCommand.Conversation, visiting: Bool = true) {
        guard !opening else { return }
        sidebar.reveal(id)
        if transcript != nil, openedRowID == id {
            focus = .main
            return
        }
        opening = true
        work { [weak self] in
            await self?.open(id, conversation: conversation, visiting: visiting)
            self?.opening = false
            self?.paint()
        }
    }

    // The session goes on screen, and the station is told so: a turn that ends in it
    // while it is shown counts as read.
    // A session opened by a step back or forward is already where the trail points, so
    // it is not visited again.
    func open(_ sessionID: String, conversation: RemoteCommand.Conversation = .main,
                      visiting: Bool = true) async {
        guard let opened = try? await commands.openSession(sessionID, conversation: conversation),
              !quitting, newSession == nil else { return }
        // The id of the conversation opened, which every later command is addressed to.
        let id = opened.snapshot.sessionID
        // One session at a time in the main pane: the one there makes way.
        if transcript != nil && transcript?.sessionID != id { closeSession() }
        select(.chat)
        closeContainer()
        factsOpen = false
        transcript = TranscriptView(opened, theme: theme)
        openedRowID = sessionID
        sidebar.opened(sessionID)
        focus = .main
        if visiting, let uuid = UUID(uuidString: sessionID) { history.visit(.session(uuid)) }
        // A prompt left half written in this session is still there.
        if let draft = drafts.removeValue(forKey: id) { transcript?.composer = draft }
        sessionEvents?.cancel()
        sessionEvents = Task { [weak self] in
            for await event in opened.events {
                guard let self, self.transcript?.sessionID == id else { return }
                // A change that does not fit the copy means the two drifted apart, and
                // only a fresh snapshot can say what the truth is.
                if self.transcript?.apply(event) == false { await self.commands.resync(id) }
                self.paint()
            }
        }
        if transcript?.sessionID == id { await commands.show(id) }
    }

    private func closeSession() {
        guard let open = transcript else { return }
        sessionEvents?.cancel()
        sessionEvents = nil
        select(.chat)
        transcript = nil
        factsOpen = false
        openedRowID = nil
        sidebar.closed()
        if open.composer.hasSomethingToSend { drafts[open.sessionID] = open.composer }
        // Closing the session takes it off this client's screen too.
        work { [commands] in await commands.closeSession(open.sessionID) }
    }

    // MARK: - The open session's log

    // The session's own lines from the session log, handed to `$PAGER` (less when it is
    // not set) in a file that goes once the pager exits.
    private func openLog() {
        guard let open = transcript, let handoff else { return }
        let pager = (environment["PAGER"] ?? "").split(separator: " ").map(String.init)
        work { [weak self, commands] in
            do throws(StationRefusal) {
                let log = try await commands.readLog(open.sessionID)
                guard let self, self.transcript?.sessionID == open.sessionID else { return }
                guard !log.text.isEmpty else {
                    self.transcript?.notice = "Nothing is logged for this session yet."
                    self.paint()
                    return
                }
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("code-station-\(open.sessionID.prefix(8))-\(UUID().uuidString.prefix(8)).log")
                guard (try? (log.text + "\n").write(to: file, atomically: true, encoding: .utf8)) != nil else {
                    self.transcript?.notice = "The log could not be written to a temporary file."
                    self.paint()
                    return
                }
                let status = await handoff.run(Handoff(arguments: (pager.isEmpty ? ["less"] : pager) + [file.path]))
                try? FileManager.default.removeItem(at: file)
                if status < 0 { self.transcript?.notice = "\(pager.first ?? "less") could not be started." }
                self.screen.invalidate()
            } catch {
                guard let self, self.transcript?.sessionID == open.sessionID else { return }
                self.transcript?.notice = error.message
            }
            self?.paint()
        }
    }

    // MARK: - Starting a session

    private func openNewSession() {
        if let workspaceID = selectedWorkspaceID {
            openWorkspaceSession(workspaceID)
            return
        }
        let projectID = sidebar.selectedProjectID
        work { [weak self, commands] in
            guard let options = try? await commands.sessionOptions(),
                  let projects = try? await commands.listDirectory().projects,
                  let self, self.newSession == nil else { return }
            self.newSession = NewSessionForm(projects: projects, options: options, projectID: projectID)
            // Whether the agents can run, for the form to say what to fix.
            if let settings = try? await commands.readSettings() { self.newSession?.readiness = settings.agents }
            self.discoverModels()
            self.paint()
        }
    }

    // Codex and Copilot list their own models. Asked once per agent, as the GUI asks
    // when its picker first shows one, and the form takes the answer when it comes.
    private func discoverModels() {
        guard let agent = newSession?.agent else { return }
        work { [weak self, commands] in
            guard let options = try? await commands.discoverModels(for: agent),
                  let self, self.newSession != nil else { return }
            self.newSession?.update(options)
            self.paint()
        }
    }

    private func handleInNewSession(_ key: Key) -> Bool {
        guard var form = newSession else { return false }
        form.notice = nil
        if form.creating { return true }
        switch key {
        case .escape, .char("q", []):
            newSession = nil
            return true
        case .up, .char("k", []), .char("p", .ctrl), .tab(.shift): form.moveField(by: -1)
        case .down, .char("j", []), .char("n", .ctrl), .tab([]): form.moveField(by: 1)
        case .left, .char("h", []): form.change(by: -1)
        case .right, .char("l", []), .char(" ", []): form.change(by: 1)
        case .enter([]):
            newSession = form
            startNewSession()
            return true
        default: return false
        }
        let agentBefore = newSession?.agent
        newSession = form
        if form.agent != agentBefore { discoverModels() }
        return true
    }

    // The façade makes the session and saves it; it then opens with the composer ready
    // for its first prompt.
    private func startNewSession() {
        guard let request = newSession?.request else {
            newSession?.notice = "There is nothing to start: add a project and install an agent first."
            return
        }
        newSession?.creating = true
        newSessionWork = work { [weak self, commands] in
            do throws(StationRefusal) {
                let id = try await commands.createSession(request)
                guard let self else { return }
                self.newSession = nil
                if let directory = try? await commands.listDirectory() { self.sidebar.show(directory) }
                // The new session is opened by its id, not by whatever the sidebar selects,
                // and a filter that would hide its card is let go.
                self.sidebar.reveal(id)
                await self.open(id)
                if self.transcript?.sessionID == id { self.transcript?.composing = true }
            } catch {
                guard let self else { return }
                self.newSession?.creating = false
                self.newSession?.notice = error.message
            }
            self?.paint()
        }
    }

    // A message or code block to the clipboard, through the host's OSC 52.
    private func copy(_ copied: (text: String?, notice: String)?) {
        guard let copied else { return }
        if let text = copied.text { host?.copy(.text(text)) }
        transcript?.notice = copied.notice
    }

    // MARK: - A typed folder

    // What the host's `askForPath` waits on: the path prompt is shown until Enter or Esc.
    // `text` starts the field, and `notice` says why the path typed last was refused.
    func askForPath(prompt: String, message: String, startingAt: URL?, text: String = "",
                    notice: String? = nil) async -> String? {
        // One question at a time; an earlier one still open is cancelled.
        pathAnswer?.resume(returning: nil)
        pathChosen = nil
        return await withCheckedContinuation { continuation in
            pathAnswer = continuation
            pathPrompt = PathPromptView(prompt: prompt, message: message, startingAt: startingAt?.path,
                                        text: text, notice: notice)
            paint()
        }
    }

    private func handleInPathPrompt(_ key: Key) {
        switch pathPrompt?.handle(key) {
        case .choose: answerPath(pathPrompt?.field.string)
        case .cancel: answerPath(nil)
        case .edited, .ignored, nil: break
        }
    }

    private func answerPath(_ path: String?) {
        pathPrompt = nil
        let chosen = pathChosen
        pathChosen = nil
        if let path { chosen?(path) }
        pathAnswer?.resume(returning: path)
        pathAnswer = nil
    }

    // MARK: - The open session's facts

    private func handleInFacts(_ key: Key) -> Bool {
        switch key {
        case .escape, .left, .char("q", []), .char("h", []), .char("D", []), .char("D", .shift):
            factsOpen = false
        case .char("d", []):
            factsOpen = false
            select(.changes)
        default: return false
        }
        return true
    }

    // Whether the top bar shows a time that counts each second: a turn running or waiting.
    private var topBarTicks: Bool {
        guard let header = transcript?.transcript.header, header.failure == nil else { return false }
        return header.state == "RUNNING" || header.state == "WAITING"
    }

    // The top bar's height: its rows over a session, one empty row otherwise.
    var topBarRows: Int {
        topBar?.rows ?? (containerScreen != nil ? ContainerScreen.topBarRows : Layout.topBarRows)
    }

    // The top bar over the open session, with the tab on screen picked out.
    private var topBar: TopBarView? {
        guard var bar = transcript?.topBar else { return nil }
        bar.selectedTab = tab
        return bar
    }

    // MARK: - The open session's tabs

    // Puts a tab on screen over the open session: the chat is the transcript, and every
    // other tab draws a screen of its own (see `SessionTabs`). The tab that was there is
    // let go.
    private func select(_ kind: RemoteSessionTab.Kind) {
        guard kind != tab || (kind != .chat && tabScreen == nil) else { return }
        tabScreen?.close()
        tabScreen = nil
        tab = kind
        guard kind != .chat, let open = transcript else {
            tab = .chat
            return
        }
        factsOpen = false
        let context = SessionTabContext(
            sessionID: open.sessionID, title: open.transcript.header.title, commands: commands, theme: theme,
            work: { [weak self] body in self?.work(body) ?? Task {} },
            repaint: { [weak self] in self?.paint() },
            environment: environment,
            handoff: { [weak self] handoff in
                guard let runner = self?.handoff else { return nil }
                let status = await runner.run(handoff)
                self?.screen.invalidate()
                return status
            },
            openLink: { [weak self] url in self?.host?.openLink(url) })
        tabScreen = SessionTabs.screen(for: kind, context: context)
    }

    // The number keys pick a tab by its place in the row, wherever letters are keys.
    private func selectTab(for key: Key) -> Bool {
        guard let header = transcript?.transcript.header,
              let kind = SessionTabs.tab(forNumber: key, in: header) else { return false }
        select(kind)
        return true
    }

    private func handleInTab(_ key: Key) -> Bool {
        guard let screen = tabScreen else { return false }
        if !screen.takesTyping, handleSessionKey(key) { return true }
        switch screen.handle(key, rows: terminal.size.rows) {
        case .handled: return true
        case .ignored: return false
        case .back:
            select(.chat)
            return true
        }
    }

    // MARK: - Keys for the whole session

    // What works over an open session whichever tab shows: the number keys pick a tab,
    // and the context actions of the top bar.
    private func handleSessionKey(_ key: Key) -> Bool {
        if selectTab(for: key) { return true }
        switch key {
        case .char("C", []), .char("C", .shift): askToCompact()
        case .char("X", []), .char("X", .shift): clearContext()
        case .char("a", []): jumpToAgent()
        case .char("!", []), .char("!", .shift): openShortcuts(in: openedRowID ?? transcript?.sessionID)
        default: return false
        }
        return true
    }

    // The agents indicator's jump: the chat comes back, at the agent's call.
    private func jumpToAgent() {
        select(.chat)
        guard let id = transcript?.transcript.header.agentToolID else {
            transcript?.notice = "No agent is running or failed since the last prompt."
            return
        }
        transcript?.reveal(tool: id)
    }

    // MARK: - Find in the transcript

    // While find is being typed, keys edit what is looked for; the arrows step through
    // the matches and Enter hands the keys back to the transcript.
    private func handleInFind(_ key: Key) -> Bool {
        switch key {
        case .escape: transcript?.closeFind()
        case .enter([]): transcript?.stopEditingFind()
        case .up([]), .char("p", .ctrl): transcript?.stepFind(by: -1)
        case .down([]), .char("n", .ctrl): transcript?.stepFind(by: 1)
        case .pageUp: transcript?.scrollPage(by: -1)
        case .pageDown: transcript?.scrollPage(by: 1)
        default: return transcript?.editFind(with: key) ?? false
        }
        return true
    }

    // MARK: - Compact and Clear

    private static let compactQuestion
        = "Compact this session's context? It costs a turn. enter compact · esc cancel"

    // Compacting spends a turn and takes the best part of a minute, so it is asked first,
    // as the GUI asks.
    private func askToCompact() {
        select(.chat)
        transcript?.asking = Self.compactQuestion
    }

    // Enter or y goes ahead with what was asked; any other key lets it go.
    private func answerAsking(_ key: Key) {
        transcript?.asking = nil
        guard key == .enter([]) || key == .char("y", []) else { return }
        guard let open = transcript else { return }
        sessionCommand(open.sessionID) { commands, id throws(StationRefusal) in try await commands.compactContext(id) }
    }

    private func clearContext() {
        select(.chat)
        guard let open = transcript else { return }
        sessionCommand(open.sessionID) { commands, id throws(StationRefusal) in try await commands.clearContext(id) }
    }

    // A command on the open session whose answer is the session moving on, or a refusal
    // said where the key help goes.
    private func sessionCommand(_ sessionID: String,
                                _ command: @escaping @MainActor (any StationInterface, String) async throws(StationRefusal) -> Void) {
        work { [weak self, commands] in
            do throws(StationRefusal) {
                try await command(commands, sessionID)
            } catch {
                guard let self, self.transcript?.sessionID == sessionID else { return }
                self.transcript?.notice = error.message
            }
            self?.paint()
        }
    }

    // MARK: - Station work

    // Runs a command against the station off the key that asked for it, since the station
    // may be on the far side of a socket, and counts it until it is seen through.
    @discardableResult
    func work(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        pendingWork += 1
        return Task { [weak self] in
            await body()
            self?.pendingWork -= 1
        }
    }

    // Whether the frame shows everything asked of the station so far: the first list has
    // come in and no command started from a key is still on its way. What the station
    // does by itself, such as a turn streaming in, is not waited for.
    // Whether the open session's warning offers to rebuild its lost worktree.
    private var canRebuild: Bool { transcript?.transcript.header.warnings?.first?.canRebuild == true }

    var terminalRows: Int { terminal.size.rows }

    var isSettled: Bool { pendingWork == 0 && sidebar.directory != nil }

    // MARK: - Painting

    func paint() {
        guard !quitting, terminal.isRunning else { return }
        let size = terminal.size
        if let pathPrompt {
            let frame = pathPrompt.frame(size: size)
            terminal.write(screen.render(frame.lines, size: size, cursor: frame.cursor))
        } else if let renaming {
            let frame = renaming.view.frame(size: size, theme: theme)
            terminal.write(screen.render(frame.lines, size: size, cursor: frame.cursor))
        } else if let workspaceForm {
            let frame = workspaceForm.frame(size: size, theme: theme)
            terminal.write(screen.render(frame.lines, size: size, cursor: frame.cursor))
        } else if let taskForm {
            let frame = taskForm.view.frame(size: size, theme: theme)
            terminal.write(screen.render(frame.lines, size: size, cursor: frame.cursor))
        } else if help != nil {
            terminal.write(screen.render(help!.frame(size: size), size: size))
        } else if let confirmation {
            terminal.write(screen.render(confirmation.view.frame(size: size, theme: theme), size: size))
        } else if let shortcuts {
            let frame = shortcuts.frame(size: size, now: now())
            terminal.write(screen.render(frame.lines, size: size, cursor: frame.cursor))
        } else if let scheduledRunQuestion {
            terminal.write(screen.render(scheduledRunQuestion.view.frame(size: size, theme: theme), size: size))
        } else if let menu {
            terminal.write(screen.render(menu.frame(size: size, theme: theme), size: size))
        } else if runSettings != nil {
            terminal.write(screen.render(runSettings!.screen.frame(size: size), size: size))
        } else if oldSessions != nil {
            terminal.write(screen.render(oldSessions!.frame(size: size, cleanup: sidebar.directory?.cleanup,
                                                            now: now(), theme: theme), size: size))
        } else if settingsScreen != nil {
            terminal.write(screen.render(settingsScreen!.frame(size: size), size: size))
        } else if palette != nil {
            let frame = palette!.frame(size: size, theme: theme)
            terminal.write(screen.render(frame.lines, size: size, cursor: frame.cursor))
        } else if let newSession {
            terminal.write(screen.render(newSession.frame(size: size), size: size))
        } else if let workspaceSession {
            terminal.write(screen.render(workspaceSession.frame(size: size), size: size))
        } else {
            let frame = regions(size: size)
            terminal.write(screen.render(frame.lines, size: size, cursor: frame.cursor))
        }
    }

    // The sidebar, the top bar and the main pane, each drawn at its region's size and
    // joined into one frame. The cursor shows where the focused region types: the filter
    // in the sidebar, the composer in the main pane. The sidebar is docked unless it was
    // put away or the terminal is too narrow; then it opens over the main pane while it
    // has the keys, and the main pane has the whole width otherwise.
    private func regions(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        let sidebarFocused = focus == .sidebar || !mainHasKeys
        let layout = Layout(size: size, showsSidebar: !sidebarHidden, overlaysSidebar: sidebarFocused,
                            topBarRows: topBarRows)
        let top = topBar?.lines(width: layout.topBar.cols, now: now())
            ?? containerScreen?.topBar(width: layout.topBar.cols, now: now()) ?? []
        guard let sidebarRegion = layout.sidebar else {
            let main = mainPane(size: layout.main.size)
            return (layout.compose(sidebar: [], topBar: top, main: main.lines), layout.cursor(inMain: main.cursor))
        }
        let column = sidebarColumn(size: sidebarRegion.size, focused: sidebarFocused)
        let main = sidebarRegion.cols < size.cols ? mainPane(size: layout.main.size) : (lines: [], cursor: nil)
        let lines = layout.compose(sidebar: column, topBar: top, main: main.lines)
        let cursor = sidebarFocused ? sidebar.filterCursor(size: sidebarRegion.size) : layout.cursor(inMain: main.cursor)
        return (lines, cursor)
    }

    // The sidebar's column. An update waiting gets a row of its own above the key help, so
    // the sidebar draws one row shorter and keeps its Add and Tools row.
    private func sidebarColumn(size: TerminalSize, focused: Bool) -> [String] {
        guard let update, size.rows >= 4 else {
            return sidebar.frame(size: size, focused: focused, theme: theme)
        }
        var column = sidebar.frame(size: TerminalSize(cols: size.cols, rows: size.rows - 1),
                                   focused: focused, theme: theme)
        let text = TerminalColumns.fit(" ↑ Update \(update.version) available", to: size.cols)
        let note = Style.cyan + TerminalColumns.pad(text, to: size.cols) + Style.reset
        column.insert(note, at: column.count - 1)
        return column
    }

    // What the main pane shows: the open session's tab, its facts, the transcript, or
    // Home when nothing is open.
    private func mainPane(size: TerminalSize) -> (lines: [String], cursor: Screen.Cursor?) {
        if let tabScreen { return tabScreen.frame(size: size) }
        if let workspaceChanges { return (workspaceChanges.frame(size: size), nil) }
        if containerScreen != nil {
            if let sync = containerSync, sync.isOpen { return sync.frame(size: size) }
            let lines = containerScreen!.frame(size: size, focused: focus == .main, now: now())
            return (containerSync?.overlay(lines, width: size.cols) ?? lines, nil)
        }
        if factsOpen, let header = transcript?.transcript.header { return (FactsView.frame(header, size: size), nil) }
        if transcript != nil { return transcript!.frame(size: size) }
        return (home.frame(size: size, focused: focus == .main, theme: theme), nil)
    }

    func quit() {
        guard !quitting else { return }
        stopFollowing()
        shutdown()
        exit()
    }

    // Stops listening to the station and puts the terminal back, leaving the station and
    // its sessions alone. A headless test ends here rather than in the quit
    // sweep, which would reach every process the test process started.
    func stopFollowing() {
        quitting = true
        answerPath(nil)
        updates?.cancel()
        hostEvents?.cancel()
        linkWatch?.cancel()
        ticker?.cancel()
        tabScreen?.close()
        statusRead?.cancel()
        shortcuts = nil
        newSessionWork?.cancel()
        workspaceChanges?.close()
        sessionEvents?.cancel()
        terminal.stop()
    }
}
