import Foundation

// Command shortcuts through the station: saved shell commands the host runs for any front
// end, in the folder the screen asking stands for, as the GUI runs them (`ShortcutStore`).
//
// A scope names where a list is asked from:
// - a project (or task): its own shortcuts and the shared ones, run in its folder, as the
//   shortcuts control on a project's status strip;
// - a session: those of each project it works in, run in its checkout, as the Run button
//   by a session's composer;
// - none: the Mac's own list, run from the home folder, as the Tools entry "Shortcuts".
// A workspace screen has no shortcuts of its own, as in the GUI.
//
// What a run printed is read by asking again (`readShortcutOutput`): a client shows it
// while its output is on screen and asks once a second.

public struct RemoteShortcutRun: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case never, running, passed, failed, stopped
    }

    public let outcome: Outcome
    // When a running command started, or when a finished one ended.
    public let at: Date?
    // How long the last finished run took.
    public let duration: TimeInterval?
    public let exitStatus: Int32?
    // Why a failed run failed, as a sentence.
    public let message: String?

    public init(outcome: Outcome, at: Date? = nil, duration: TimeInterval? = nil,
                exitStatus: Int32? = nil, message: String? = nil) {
        self.outcome = outcome
        self.at = at
        self.duration = duration
        self.exitStatus = exitStatus
        self.message = message
    }

    init(_ state: ShortcutStore.State, started: Bool, duration: TimeInterval?) {
        switch state {
        case .running(let since): self.init(outcome: .running, at: since)
        case .finished(let at): self.init(outcome: .passed, at: at, duration: duration, exitStatus: 0)
        case .failed(let message, let status, let at):
            self.init(outcome: .failed, at: at, duration: duration, exitStatus: status, message: message)
        case .stopped: self.init(outcome: started ? .stopped : .never)
        }
    }
}

public struct RemoteShortcut: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let command: String
    // An SF Symbol name, which a terminal has no way to draw.
    public let icon: String?
    // The project it is filed under, nil for the Mac's own.
    public let projectID: String?
    public let availableInAllProjects: Bool
    public let favorite: Bool
    // The folder this scope runs it in, on the host.
    public let directory: String
    // The project whose checkout that is, when it is one.
    public let projectName: String?
    public let run: RemoteShortcutRun

    public init(id: String, name: String, command: String, icon: String?, projectID: String?,
                availableInAllProjects: Bool, favorite: Bool, directory: String, projectName: String?,
                run: RemoteShortcutRun) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.projectID = projectID
        self.availableInAllProjects = availableInAllProjects
        self.favorite = favorite
        self.directory = directory
        self.projectName = projectName
        self.run = run
    }
}

public struct RemoteShortcuts: Codable, Equatable, Sendable {
    // The project or session asked about, nil for the Mac's own list.
    public let scope: String?
    // What the list is for: the project's name, the session's title, or "This Mac".
    public let title: String
    public let shortcuts: [RemoteShortcut]
    // The one this scope ran last, which Run offers again.
    public let lastStartedID: String?
    // The project a shortcut made here is filed under, and its name.
    public let projectID: String?
    public let projectName: String?
    // Why the saved shortcuts could not be read or written, when they could not.
    public let problem: String?

    public init(scope: String?, title: String, shortcuts: [RemoteShortcut], lastStartedID: String?,
                projectID: String?, projectName: String?, problem: String?) {
        self.scope = scope
        self.title = title
        self.shortcuts = shortcuts
        self.lastStartedID = lastStartedID
        self.projectID = projectID
        self.projectName = projectName
        self.problem = problem
    }

    public var running: Int { shortcuts.count { $0.run.outcome == .running } }
    public var failed: Int { shortcuts.count { $0.run.outcome == .failed } }
}

public struct RemoteShortcutOutput: Codable, Equatable, Sendable {
    public let shortcutID: String
    public let name: String
    public let command: String
    public let directory: String
    public let run: RemoteShortcutRun
    // The tail of what it printed, its error output mixed in as it came.
    public let text: String

    public init(shortcutID: String, name: String, command: String, directory: String,
                run: RemoteShortcutRun, text: String) {
        self.shortcutID = shortcutID
        self.name = name
        self.command = command
        self.directory = directory
        self.run = run
        self.text = text
    }
}

// A shortcut to add (no id) or to save over one already there.
public struct RemoteShortcutDraft: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var command: String
    public var icon: String?
    // The project it is filed under; ignored when it is shared with every project.
    public var projectID: String?
    public var availableInAllProjects: Bool

    public init(id: String? = nil, name: String, command: String, icon: String? = nil,
                projectID: String? = nil, availableInAllProjects: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.projectID = projectID
        self.availableInAllProjects = availableInAllProjects
    }
}

extension StationCommands {
    // One shortcut as a scope offers it: where it runs, and the project that is.
    private struct Offered {
        let shortcut: Shortcut
        let run: ShortcutRun
        let projectName: String?
    }

    // What a scope stands for: its key for the store's per-screen memory, its title, the
    // project new shortcuts go to, and what it offers.
    private struct Resolved {
        let key: ShortcutScope?
        let title: String
        let project: Project?
        let offered: [Offered]
    }

    private func resolve(_ scope: String?) throws(StationRefusal) -> Resolved {
        guard let scope else {
            let offered = shortcuts.libraryShortcuts().map {
                Offered(shortcut: $0, run: ShortcutRun($0.id, in: $0.directory(projectPath: nil)), projectName: nil)
            }
            return Resolved(key: nil, title: "This Mac", project: nil, offered: offered)
        }
        guard let id = UUID(uuidString: scope) else { throw .noShortcutScope }
        if let session = store.session(id) {
            let checkouts = store.checkoutProjects(for: session)
            let offered = shortcuts.shortcuts(for: checkouts.map(\.projectID)).compactMap { placement -> Offered? in
                guard let checkout = checkouts.first(where: { $0.projectID == placement.projectID }) else { return nil }
                let project = store.project(checkout.projectID)
                let directory = placement.shortcut.directory(projectPath: project?.path,
                                                             workspacePath: checkout.worktreePath)
                return Offered(shortcut: placement.shortcut, run: ShortcutRun(placement.shortcut.id, in: directory),
                               projectName: project?.name)
            }
            return Resolved(key: .session(id), title: session.title, project: store.project(session.projectID),
                            offered: offered)
        }
        if store.workspace(id) != nil {
            throw StationRefusal("A workspace has no shortcuts of its own. Open one of its sessions.")
        }
        guard let project = store.project(id) else { throw .noShortcutScope }
        let offered = shortcuts.shortcuts(for: project.id).map {
            Offered(shortcut: $0, run: ShortcutRun($0.id, in: $0.directory(projectPath: project.path)),
                    projectName: project.name)
        }
        return Resolved(key: .project(id), title: project.name, project: project, offered: offered)
    }

    private func remoteRun(_ run: ShortcutRun) -> RemoteShortcutRun {
        RemoteShortcutRun(shortcuts.state(run), started: shortcuts.hasStarted(run),
                          duration: shortcuts.duration(run))
    }

    private func offered(_ shortcutID: String, in scope: String?) throws(StationRefusal) -> (Resolved, Offered) {
        let resolved = try resolve(scope)
        guard let offered = resolved.offered.first(where: { $0.shortcut.id.uuidString == shortcutID }) else {
            throw .noShortcut
        }
        return (resolved, offered)
    }

    private func output(of offered: Offered) -> RemoteShortcutOutput {
        RemoteShortcutOutput(shortcutID: offered.shortcut.id.uuidString, name: offered.shortcut.name,
                             command: offered.shortcut.text, directory: offered.run.directory,
                             run: remoteRun(offered.run), text: shortcuts.log(offered.run))
    }

    // The shortcuts a project, a session or the Mac offers, each with how its run here
    // stands.
    public func listShortcuts(in scope: String?) throws(StationRefusal) -> RemoteShortcuts {
        let resolved = try resolve(scope)
        let rows = resolved.offered.map { offered in
            RemoteShortcut(id: offered.shortcut.id.uuidString, name: offered.shortcut.name,
                           command: offered.shortcut.text, icon: offered.shortcut.icon,
                           projectID: offered.shortcut.projectID?.uuidString,
                           availableInAllProjects: offered.shortcut.availableInAllProjects,
                           favorite: offered.shortcut.favorite, directory: offered.run.directory,
                           projectName: offered.projectName, run: remoteRun(offered.run))
        }
        return RemoteShortcuts(scope: scope, title: resolved.title, shortcuts: rows,
                               lastStartedID: resolved.key.flatMap(shortcuts.lastStarted(for:))?.uuidString,
                               projectID: resolved.project?.id.uuidString, projectName: resolved.project?.name,
                               problem: shortcuts.loadError ?? shortcuts.saveError)
    }

    // Starts the shortcut where the scope runs it, unless it is running there already,
    // and answers with its output so far.
    public func runShortcut(_ shortcutID: String, in scope: String?) throws(StationRefusal) -> RemoteShortcutOutput {
        let (resolved, offered) = try offered(shortcutID, in: scope)
        shortcuts.start(offered.run, for: resolved.key)
        return output(of: offered)
    }

    public func stopShortcut(_ shortcutID: String, in scope: String?) throws(StationRefusal) -> RemoteShortcutOutput {
        let (_, offered) = try offered(shortcutID, in: scope)
        shortcuts.stop(offered.run)
        return output(of: offered)
    }

    public func readShortcutOutput(_ shortcutID: String, in scope: String?) throws(StationRefusal) -> RemoteShortcutOutput {
        let (_, offered) = try offered(shortcutID, in: scope)
        return output(of: offered)
    }

    // Adds the draft, or saves it over the shortcut it names, and answers with its id.
    public func saveShortcut(_ draft: RemoteShortcutDraft) throws(StationRefusal) -> String {
        guard !draft.name.isBlank, !draft.command.isBlank else {
            throw StationRefusal("A shortcut needs a name and a command.")
        }
        var projectID: UUID?
        if !draft.availableInAllProjects, let project = draft.projectID {
            guard let id = UUID(uuidString: project), store.project(id) != nil else { throw .noShortcutScope }
            projectID = id
        }
        var shortcut: Shortcut
        if let id = draft.id {
            guard let uuid = UUID(uuidString: id), let existing = shortcuts.shortcut(uuid) else { throw .noShortcut }
            guard !shortcuts.isRunningAnywhere(uuid) else {
                throw StationRefusal("\(existing.name) is running. Stop it before editing it.")
            }
            shortcut = existing
            shortcut.name = draft.name
            shortcut.text = draft.command
            shortcut.icon = ShortcutSymbols.resolve(draft.icon)
            shortcut.availableInAllProjects = draft.availableInAllProjects
            shortcut.projectID = projectID
        } else {
            shortcut = Shortcut(name: draft.name, text: draft.command, icon: draft.icon, projectID: projectID,
                                availableInAllProjects: draft.availableInAllProjects)
        }
        guard shortcuts.saveShortcut(shortcut) else {
            throw StationRefusal(shortcuts.saveError ?? "The shortcut could not be saved.")
        }
        return shortcut.id.uuidString
    }

    // Removes the shortcut, stopping every run of it first.
    public func removeShortcut(_ shortcutID: String) throws(StationRefusal) {
        guard let id = UUID(uuidString: shortcutID), shortcuts.shortcut(id) != nil else { throw .noShortcut }
        shortcuts.remove(id)
        if let error = shortcuts.saveError { throw StationRefusal(error) }
    }
}

extension StationRefusal {
    static let noShortcut = StationRefusal("That shortcut is not offered here any more.")
    static let noShortcutScope = StationRefusal("That project or session is no longer available.")
}
