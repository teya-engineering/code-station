import Foundation

// What a front end does to a workspace, as the GUI's Add button, workspace row and
// workspace screen do it: create one from several projects with a lead, change the lead
// and whether each member starts on a worktree of its own, rename and pin it, start a
// session across its projects, delete it after reading what would go and what would stay
// (`RemoteImpact`), and read what its members' folders have changed.
extension StationCommands {

    // MARK: - Create

    // Makes a workspace of the projects named, the lead first, as `NewWorkspaceView`
    // does. Answers with its id. A git repository starts on a worktree of its own.
    public func createWorkspace(name: String, projectIDs: [String],
                                leadProjectID: String) throws(StationRefusal) -> String {
        guard !name.trimmed.isEmpty else { throw StationRefusal("Give the workspace a name.") }
        var members: [UUID] = []
        for projectID in projectIDs {
            guard let id = UUID(uuidString: projectID), let project = store.project(id),
                  project.kind == .project else { throw .noProject }
            if !members.contains(id) { members.append(id) }
        }
        guard members.count >= 2 else { throw StationRefusal("A workspace needs at least two projects.") }
        guard let lead = UUID(uuidString: leadProjectID), members.contains(lead) else {
            throw StationRefusal("The lead must be one of the workspace's projects.")
        }
        guard let workspace = store.addWorkspace(name: name, projectIDs: members, leadProjectID: lead) else {
            throw StationRefusal("The workspace could not be created.")
        }
        return workspace.id.uuidString
    }

    // MARK: - Change

    // One change to a workspace, as its row menu and its screen make it.
    public func changeWorkspace(_ workspaceID: String, _ change: WorkspaceChange) throws(StationRefusal) {
        let workspace = try workspace(workspaceID)
        switch change {
        case .rename(let name):
            guard !name.trimmed.isEmpty else { throw StationRefusal("Give \(workspace.name) a name.") }
            store.renameWorkspace(workspace.id, to: name)
        case .pin(let pinned):
            store.setPinned(pinned, forWorkspace: workspace.id)
        case .lead(let projectID):
            let member = try member(projectID, of: workspace)
            store.setLeadProject(member.id, inWorkspace: workspace.id)
        case .worktree(let projectID, let uses):
            let member = try member(projectID, of: workspace)
            guard !uses || member.isGitRepository else {
                throw StationRefusal("\(member.name) is not a git repository, so it cannot have a worktree.")
            }
            store.setUsesWorktree(uses, for: member.id, inWorkspace: workspace.id)
        }
    }

    // MARK: - Delete

    // What deleting the workspace would take and leave, for the front end to ask with.
    public func readWorkspaceRemoval(_ workspaceID: String) throws(StationRefusal) -> RemoteImpact {
        WorkspaceRemoval.impact(of: try workspace(workspaceID), in: store)
    }

    // Deletes it once the person has confirmed: its sessions and their worktrees go, its
    // projects stay.
    public func removeWorkspace(_ workspaceID: String) async throws(StationRefusal) {
        let workspace = try workspace(workspaceID)
        if case .failure(let failure) = await WorkspaceRemoval.run(workspace, in: store, runner: runner,
                                                                   worktrees: worktrees) {
            throw StationRefusal(failure.message)
        }
    }

    // MARK: - Start a session

    // Starts a session across the projects asked for, the workspace's lead first, each
    // on a worktree of its own or in its folder, through the core's lifecycle as the
    // GUI's `NewWorkspaceSessionView` does. Answers with the new session's id.
    public func createWorkspaceSession(_ request: RemoteNewWorkspaceSession) async throws(StationRefusal) -> String {
        followSharedDefaults()
        try admitTurn()
        let workspace = try workspace(request.workspaceID)
        var choices: [WorkspaceProjectChoice] = []
        for checkout in request.projects {
            guard let id = UUID(uuidString: checkout.projectID), let project = store.project(id),
                  project.kind == .project else { throw .noProject }
            guard !store.isMissing(project) else { throw StationRefusal("\(project.name) is missing from disk.") }
            guard !checkout.worktree || project.isGitRepository else {
                throw StationRefusal("\(project.name) is not a git repository, so it cannot have a worktree.")
            }
            if !choices.contains(where: { $0.projectID == id }) {
                choices.append(WorkspaceProjectChoice(projectID: id, useWorktree: checkout.worktree))
            }
        }
        guard let lead = choices.firstIndex(where: { $0.projectID == workspace.leadProjectID }) else {
            throw StationRefusal("A session in \(workspace.name) works in its lead project, so it cannot be left out.")
        }
        choices.insert(choices.remove(at: lead), at: 0)
        guard choices.count >= 2 else {
            throw StationRefusal("Attach at least two projects to create a workspace session.")
        }
        guard runner.isAvailable(request.agent) else { throw StationRefusal("\(request.agent.title) is not installed.") }
        guard request.model == nil || runner.validModel(request.model, for: request.agent) != nil else {
            throw StationRefusal("\(request.agent.title) does not offer that model.")
        }
        let choice = WorkspaceSessionChoice(sessionID: UUID(), projects: choices, agent: request.agent,
                                            model: request.model,
                                            agentAvatarName: Preferences.defaultAgentAvatarName())
        switch await SessionLifecycle.createWorkspaceSession(choice, in: workspace, store: store,
                                                             worktrees: worktrees) {
        case .success(let session): return session.id.uuidString
        case .failure(let failure): throw StationRefusal("\(failure.title). \(failure.message)")
        }
    }

    // MARK: - Changes across members

    // What each member's own folder has changed, the lead first: its branch, how it
    // stands, and each changed file with its diff, as a session's changes read.
    public func readWorkspaceChanges(_ workspaceID: String) async throws(StationRefusal) -> [RemoteCheckout] {
        let workspace = try workspace(workspaceID)
        let ordered = [workspace.leadProjectID] + workspace.projectIDs.filter { $0 != workspace.leadProjectID }
        var checkouts: [RemoteCheckout] = []
        for project in ordered.compactMap(store.project) {
            let (checkout, _) = await StationChangesReader.read(
                .init(project: project.name, path: project.path, isWorktree: false))
            checkouts.append(checkout)
        }
        return checkouts
    }

    private func workspace(_ workspaceID: String) throws(StationRefusal) -> ProjectWorkspace {
        guard let id = UUID(uuidString: workspaceID), let workspace = store.workspace(id) else { throw .noWorkspace }
        return workspace
    }

    private func member(_ projectID: String, of workspace: ProjectWorkspace) throws(StationRefusal) -> Project {
        guard let id = UUID(uuidString: projectID), workspace.projectIDs.contains(id),
              let project = store.project(id) else {
            throw StationRefusal("That project is not in \(workspace.name).")
        }
        return project
    }
}

// One change a front end makes to a workspace.
public enum WorkspaceChange: Codable, Equatable, Sendable {
    case rename(name: String)
    case pin(Bool)
    // The project every session starts in.
    case lead(projectID: String)
    // Whether a new session starts this member on a worktree of its own.
    case worktree(projectID: String, uses: Bool)
}

// What a front end asks for: a session in this workspace, on this agent and model, with
// each project on a worktree of its own or in its folder. The lead must be among them.
public struct RemoteNewWorkspaceSession: Codable, Equatable, Sendable {
    public struct Checkout: Codable, Equatable, Sendable {
        public let projectID: String
        public let worktree: Bool

        public init(projectID: String, worktree: Bool) {
            self.projectID = projectID
            self.worktree = worktree
        }
    }

    public let workspaceID: String
    public let agent: AgentKind
    public let model: String?
    public let projects: [Checkout]

    public init(workspaceID: String, agent: AgentKind, model: String?, projects: [Checkout]) {
        self.workspaceID = workspaceID
        self.agent = agent
        self.model = model
        self.projects = projects
    }
}

extension StationRefusal {
    static let noWorkspace = StationRefusal("That workspace is no longer available.")
}
