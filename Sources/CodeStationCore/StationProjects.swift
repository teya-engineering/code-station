import Foundation

// What a front end does to a project from the sidebar, as the GUI's project row and Add
// button do it: add one by its folder, rename, pin and unpin it, snooze its cleanup and
// wake it, and clear its idle sessions or take it out, each of those two after reading
// what would go and what would stay (`RemoteImpact`).
extension StationCommands {

    // MARK: - Add a project

    // Adds the folder at `path`, a path on the host's machine, `~` being the host's home.
    // Answers with the project's id, the one it already is when the folder was added
    // before. The GUI's own selection is left where it was: a project added from another
    // front end is that front end's to go to.
    public func addProject(path: String) throws(StationRefusal) -> String {
        let typed = path.trimmed
        guard !typed.isEmpty else { throw StationRefusal("Type the folder's path.") }
        let expanded = (typed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw StationRefusal("Type the folder's full path.") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw StationRefusal("\(url.path) is not a folder.")
        }
        if let existing = store.projects.first(where: { $0.path == url.path }) {
            return existing.id.uuidString
        }
        let selected = store.selectedProjectID
        guard let project = store.addProject(at: url) else { throw StationRefusal("\(url.path) could not be added.") }
        store.selectedProjectID = selected
        return project.id.uuidString
    }

    // MARK: - Rename, pin, snooze and wake

    // One change to a project or task, as its sidebar menu makes it.
    public func changeProject(_ projectID: String, _ change: ProjectChange) throws(StationRefusal) {
        let project = try project(projectID)
        switch change {
        case .rename(let name):
            guard !name.trimmed.isEmpty else { throw StationRefusal("Give \(project.name) a name.") }
            store.renameProject(project.id, to: name)
        case .pin(let pinned):
            store.setPinned(pinned, forProject: project.id)
        case .snoozeCleanup:
            store.snoozeCleanup(forProject: project.id)
        case .wakeCleanup:
            store.wakeCleanup(forProject: project.id)
        }
    }

    // MARK: - Clear idle sessions and remove

    // What the removal would take and leave, for the front end to ask with. Clearing a
    // project with nothing idle is refused, saying so.
    public func readRemoval(_ removal: ProjectRemovalKind, of projectID: String) throws(StationRefusal) -> RemoteImpact {
        let project = try project(projectID)
        switch removal {
        case .idleSessions:
            guard let impact = ProjectRemoval.clearingImpact(of: project, in: store, runner: runner,
                                                             isDirty: workingTrees.isDirty) else {
                throw StationRefusal(project.kind == .adHoc ? "\(project.name) has no idle runs."
                                     : "\(project.name) has no idle sessions.")
            }
            return impact
        case .project:
            return ProjectRemoval.impact(of: project, in: store,
                                         savedShortcuts: shortcuts.shortcuts.count { $0.projectID == project.id })
        }
    }

    // Does the removal once the person has confirmed it. Clearing takes the sessions that
    // are idle now, so one that started running since it was read stays.
    public func remove(_ removal: ProjectRemovalKind, of projectID: String) async throws(StationRefusal) {
        let project = try project(projectID)
        let result = switch removal {
        case .idleSessions:
            await SessionRemoval.run(ProjectRemoval.idleSessions(in: project, store: store, runner: runner),
                                     in: store, runner: runner, worktrees: worktrees,
                                     groupNoun: project.kind == .adHoc ? "runs" : "sessions")
        case .project:
            await ProjectRemoval.run(project, in: store, runner: runner, worktrees: worktrees,
                                     removeOwned: { [shortcuts] in shortcuts.removeAll(ownedBy: $0) })
        }
        if case .failure(let failure) = result { throw StationRefusal(failure.message) }
    }

    private func project(_ projectID: String) throws(StationRefusal) -> Project {
        guard let id = UUID(uuidString: projectID), let project = store.project(id) else { throw .noProject }
        return project
    }
}

// One change a front end makes to a project or task.
public enum ProjectChange: Codable, Equatable, Sendable {
    case rename(name: String)
    case pin(Bool)
    // Another day before its old sessions are offered for deletion or swept.
    case snoozeCleanup
    case wakeCleanup
}

// What a removal takes: the project's idle sessions (a task's idle runs), or the project
// or task itself.
public enum ProjectRemovalKind: String, Codable, Sendable {
    case idleSessions, project
}
