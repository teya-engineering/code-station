import Foundation
import Observation

// A terminal belongs to a project overview, a workspace or one chat session. The kind is
// part of the key, so the store never has to guess which screen an id belongs to.
enum TerminalScope: Hashable {
    case project(UUID)
    case workspace(UUID)
    case session(UUID)

    init(_ owner: RemovedOwner) {
        switch owner {
        case .project(let id): self = .project(id)
        case .workspace(let id): self = .workspace(id)
        case .session(let id): self = .session(id)
        }
    }
}

// The terminals belonging to each screen, plus how the drawer is sitting. Keeping them
// here, rather than in the view, is what lets a shell keep running while the drawer is
// collapsed or another screen is open.
@MainActor
@Observable
final class TerminalStore {
    static let minimumHeight: CGFloat = 120
    static let defaultHeight: CGFloat = 300

    private var terminals: [TerminalScope: [TerminalSession]] = [:]
    private var selected: [TerminalScope: UUID] = [:]
    private var open: Set<TerminalScope> = []
    @ObservationIgnored private var visibleDrawers: Set<TerminalScope> = []
    private var heights: [TerminalScope: CGFloat] = [:]
    @ObservationIgnored private let registry: ShellRegistry

    init(registry: ShellRegistry = .shared) {
        self.registry = registry
    }

    func sessions(for scope: TerminalScope) -> [TerminalSession] { terminals[scope] ?? [] }

    func selection(for scope: TerminalScope) -> TerminalSession? {
        let all = sessions(for: scope)
        if let id = selected[scope], let match = all.first(where: { $0.id == id }) { return match }
        return all.first
    }

    func select(_ terminal: TerminalSession, in scope: TerminalScope) {
        selected[scope] = terminal.id
    }

    // MARK: - Drawer

    // Shut by default, so a project or session opens on its main content and the terminal
    // appears only when it is asked for.
    func isOpen(_ scope: TerminalScope) -> Bool { open.contains(scope) }

    func setOpen(_ isOpen: Bool, for scope: TerminalScope, directory: String) {
        if isOpen {
            ensureOne(for: scope, directory: directory)
            open.insert(scope)
        } else {
            open.remove(scope)
            setDrawerVisible(false, for: scope)
        }
    }

    // The header's button: it shuts an open drawer and opens a shut one, and says which
    // it did, since the cursor goes into the shell only when it opened.
    func toggle(_ scope: TerminalScope, directory: String) -> Bool {
        let opening = !isOpen(scope)
        setOpen(opening, for: scope, directory: directory)
        return opening
    }

    // The terminal key pressed anywhere but the shell. The shell takes the key for itself
    // when it has the cursor, so a press that arrives here always means "take me there":
    // the drawer opens if it is shut, and the cursor goes into the shell either way. An
    // open drawer's shell is asked for focus directly, since the screen's own flag may
    // already say it has it.
    func reveal(_ scope: TerminalScope, directory: String) {
        if isOpen(scope) {
            selection(for: scope)?.surface.takeFocus()
        } else {
            setOpen(true, for: scope, directory: directory)
        }
    }

    func setDrawerVisible(_ visible: Bool, for scope: TerminalScope) {
        if visible {
            visibleDrawers.insert(scope)
        } else {
            visibleDrawers.remove(scope)
        }
        for terminal in sessions(for: scope) {
            terminal.setBusyMonitoring(visible)
        }
    }

    func height(for scope: TerminalScope) -> CGFloat { heights[scope] ?? Self.defaultHeight }

    func setHeight(_ height: CGFloat, for scope: TerminalScope) {
        heights[scope] = max(Self.minimumHeight, height)
    }

    // MARK: - Tabs

    // The first terminal for a screen is made on demand, so no shell is started for a
    // project or session whose drawer is never opened.
    @discardableResult
    func add(to scope: TerminalScope, directory: String) -> TerminalSession {
        let terminal = TerminalSession(directory: directory, name: nextName(in: scope),
                                       registry: registry) { [weak self] terminal in
            self?.removeExited(terminal, from: scope)
        }
        terminal.start()
        terminal.setBusyMonitoring(visibleDrawers.contains(scope))
        terminals[scope, default: []].append(terminal)
        selected[scope] = terminal.id
        return terminal
    }

    // "Terminal", then "Terminal 2"; renamed tabs are skipped over rather than counted,
    // so closing one does not produce a duplicate name.
    private func nextName(in scope: TerminalScope) -> String {
        let taken = Set(sessions(for: scope).map(\.name))
        if !taken.contains("Terminal") { return "Terminal" }
        var number = 2
        while taken.contains("Terminal \(number)") { number += 1 }
        return "Terminal \(number)"
    }

    func openShell(for scope: TerminalScope, directory: String) {
        add(to: scope, directory: directory)
        open.insert(scope)
    }

    func ensureOne(for scope: TerminalScope, directory: String) {
        guard sessions(for: scope).isEmpty else { return }
        add(to: scope, directory: directory)
    }

    func close(_ terminal: TerminalSession, in scope: TerminalScope) {
        terminal.stop()
        remove(terminal, from: scope)
    }

    private func removeExited(_ terminal: TerminalSession, from scope: TerminalScope) {
        guard terminals[scope]?.contains(where: { $0.id == terminal.id }) == true else { return }
        remove(terminal, from: scope)
        // The last shell going puts the drawer away, since there is nothing left to show.
        if terminals[scope]?.isEmpty == true {
            open.remove(scope)
            visibleDrawers.remove(scope)
        }
    }

    // Takes a tab out of the strip and moves the selection along if it was the one showing.
    private func remove(_ terminal: TerminalSession, from scope: TerminalScope) {
        terminals[scope]?.removeAll { $0.id == terminal.id }
        if selected[scope] == terminal.id {
            selected[scope] = terminals[scope]?.first?.id
        }
    }

    // Everything belonging to a project, workspace or session that has been deleted. Its
    // shells are still running and nothing on screen can reach them any more, so without
    // this they would sit there until the app quit.
    func discard(_ scope: TerminalScope) {
        forget(scope)
    }

    func stopEverything() {
        for scope in Set(terminals.keys).union(open).union(heights.keys) { forget(scope) }
    }

    // The one place a scope is torn down, so nothing stays keyed to a screen that is gone.
    private func forget(_ scope: TerminalScope) {
        for terminal in sessions(for: scope) { terminal.stop() }
        terminals[scope] = nil
        selected[scope] = nil
        heights[scope] = nil
        open.remove(scope)
        visibleDrawers.remove(scope)
    }
}
