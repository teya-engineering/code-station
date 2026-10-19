import Foundation

// What the status strip under a container's screen reads, as the GUI's detail screens
// read it (`ProjectDetailView`, `WorkspaceDetailView`, `TaskDetailView`). Asked of the
// station when the screen opens, since it costs a look at git.

public struct RemoteContainerStatus: Codable, Equatable, Sendable {
    public let containerID: String
    public let kind: RemoteContainer.Kind
    // A project's checkout.
    public var checkout: RemoteCheckoutReading?
    // A workspace's projects, the lead first.
    public var members: [RemoteWorkspaceMember]?
    // A task's runs, inputs and timer.
    public var task: RemoteTaskReading?

    public init(containerID: String, kind: RemoteContainer.Kind, checkout: RemoteCheckoutReading? = nil,
                members: [RemoteWorkspaceMember]? = nil, task: RemoteTaskReading? = nil) {
        self.containerID = containerID
        self.kind = kind
        self.checkout = checkout
        self.members = members
        self.task = task
    }
}

// How one folder's checkout stands: the branch, how far it has drifted from its
// upstream, how many files are uncommitted, and the newest commit.
public struct RemoteCheckoutReading: Codable, Equatable, Sendable {
    // "ready" when git answered; otherwise "notARepo", "missingFolder", "gitMissing" or
    // "failed", as `RemoteCheckout` spells them.
    public let state: String
    public let branch: String
    public let ahead: Int
    public let behind: Int
    public let uncommitted: Int
    public let lastCommitSubject: String?
    public let lastCommitDate: Date?

    public init(state: String, branch: String, ahead: Int, behind: Int, uncommitted: Int,
                lastCommitSubject: String?, lastCommitDate: Date?) {
        self.state = state
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.uncommitted = uncommitted
        self.lastCommitSubject = lastCommitSubject
        self.lastCommitDate = lastCommitDate
    }

    init(_ snapshot: GitSnapshot) {
        self.init(state: StationChangesReader.word(for: snapshot.state), branch: snapshot.branch,
                  ahead: snapshot.ahead, behind: snapshot.behind, uncommitted: snapshot.files.count,
                  lastCommitSubject: snapshot.lastCommitSubject, lastCommitDate: snapshot.lastCommitDate)
    }
}

public struct RemoteWorkspaceMember: Codable, Equatable, Sendable {
    public let projectID: String
    public let name: String
    // The lead project is the folder every session in the workspace starts in.
    public let isLead: Bool
    public let checkout: RemoteCheckoutReading?
    // Whether a new session in the workspace starts this project on a worktree of its
    // own, as the workspace screen's checkout control says. Nil from a host that
    // predates it.
    public var usesWorktree: Bool?
    // Whether it is a git repository, which a worktree needs.
    public var isGit: Bool?

    public init(projectID: String, name: String, isLead: Bool, checkout: RemoteCheckoutReading?,
                usesWorktree: Bool? = nil, isGit: Bool? = nil) {
        self.projectID = projectID
        self.name = name
        self.isLead = isLead
        self.checkout = checkout
        self.usesWorktree = usesWorktree
        self.isGit = isGit
    }
}

public struct RemoteTaskReading: Codable, Equatable, Sendable {
    public struct Run: Codable, Equatable, Sendable {
        public let sessionID: String
        // The run's state word, as its sidebar card says it.
        public let state: String
        public let at: Date

        public init(sessionID: String, state: String, at: Date) {
            self.sessionID = sessionID
            self.state = state
            self.at = at
        }
    }

    public let runs: Int
    // How many inputs the prompt asks for.
    public let inputs: Int
    // The newest run, nil when the task has never run.
    public let lastRun: Run?
    // When the timer next runs it, while it is on.
    public let nextRunAt: Date?

    public init(runs: Int, inputs: Int, lastRun: Run?, nextRunAt: Date?) {
        self.runs = runs
        self.inputs = inputs
        self.lastRun = lastRun
        self.nextRunAt = nextRunAt
    }
}

extension StationCommands {
    // The strip's readings for a project, task or workspace, by its sidebar id.
    public func readContainerStatus(_ containerID: String) async throws(StationRefusal) -> RemoteContainerStatus {
        guard let id = UUID(uuidString: containerID) else { throw .noContainer }
        if let workspace = store.workspace(id) {
            let ordered = [workspace.leadProjectID] + workspace.projectIDs.filter { $0 != workspace.leadProjectID }
            var members: [RemoteWorkspaceMember] = []
            for project in ordered.compactMap(store.project) {
                let snapshot = await GitInspector.snapshot(at: project.path, lane: .interactive)
                members.append(RemoteWorkspaceMember(projectID: project.id.uuidString, name: project.name,
                                                     isLead: project.id == workspace.leadProjectID,
                                                     checkout: RemoteCheckoutReading(snapshot),
                                                     usesWorktree: project.isGitRepository
                                                         && workspace.worktreeProjectIDs.contains(project.id),
                                                     isGit: project.isGitRepository))
            }
            return RemoteContainerStatus(containerID: containerID, kind: .workspace, members: members)
        }
        guard let project = store.project(id) else { throw .noContainer }
        if project.kind == .adHoc {
            let runs = store.standaloneSessions(for: id)
            let latest = runs.max { $0.lastActivity < $1.lastActivity }
            let spec = project.task ?? TaskSpec(prompt: "")
            let schedule = spec.schedule.map(RemoteSchedule.init)
            return RemoteContainerStatus(
                containerID: containerID, kind: .task,
                task: RemoteTaskReading(
                    runs: runs.count, inputs: TaskTemplate.inputs(in: spec).count,
                    lastRun: latest.map {
                        .init(sessionID: $0.id.uuidString,
                              state: SessionTone($0.id, store: store, runner: runner).word, at: $0.lastActivity)
                    },
                    nextRunAt: schedule?.nextRunAt))
        }
        let snapshot = await GitInspector.snapshot(at: project.path, lane: .interactive)
        return RemoteContainerStatus(containerID: containerID, kind: .project,
                                     checkout: RemoteCheckoutReading(snapshot))
    }
}

extension StationRefusal {
    static let noContainer = StationRefusal("That project, task or workspace is no longer available.")
}
