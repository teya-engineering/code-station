import Foundation

// What the new workspace session sheet asks the lifecycle to start.
public struct WorkspaceSessionChoice: Equatable {
    public var sessionID: UUID
    public var projects: [WorkspaceProjectChoice]
    public var agent: AgentKind
    public var model: String? = nil
    public var agentAvatarName: String? = nil
    public var mode: SessionMode = .chat

    public init(sessionID: UUID, projects: [WorkspaceProjectChoice], agent: AgentKind, model: String? = nil, agentAvatarName: String? = nil, mode: SessionMode = .chat) {
        self.sessionID = sessionID
        self.projects = projects
        self.agent = agent
        self.model = model
        self.agentAvatarName = agentAvatarName
        self.mode = mode
    }
}

public struct WorkspaceProjectChoice: Equatable {
    public var projectID: UUID
    public var useWorktree: Bool
    // The ref this project's worktree forks from; without one it forks from whatever
    // the project folder has checked out.
    public var base: String? = nil

    public init(projectID: UUID, useWorktree: Bool, base: String? = nil) {
        self.projectID = projectID
        self.useWorktree = useWorktree
        self.base = base
    }
}
